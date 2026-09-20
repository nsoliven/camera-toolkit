import Foundation

public enum OrganizeMediaKind: String, Codable, Sendable {
    case raw
    case photo
    case video
    case other
}

/// Classifies camera files and pairs sidecars with the photo or clip they
/// describe, so a burst frame, its XMP, and a RAW+JPEG twin always travel
/// together.
public enum OrganizeFileClassifier {
    public static let rawExtensions: Set<String> = [
        "arw", "cr2", "cr3", "nef", "nrw", "orf", "raf", "rw2", "pef", "srw", "dng"
    ]
    public static let photoExtensions: Set<String> = [
        "jpg", "jpeg", "heic", "heif", "png", "tif", "tiff", "webp"
    ]
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mts", "m2ts", "mxf", "avi", "insv", "osv"
    ]
    public static let companionExtensions: Set<String> = [
        "xmp", "xml", "thm", "lrf", "lrv", "srt", "aae", "photo-edit"
    ]
    public static let ignoredFileNames: Set<String> = ["thumbs.db", "desktop.ini", ".ds_store"]

    public static func kind(forExtension ext: String) -> OrganizeMediaKind {
        let lowered = ext.lowercased()
        if rawExtensions.contains(lowered) { return .raw }
        if photoExtensions.contains(lowered) { return .photo }
        if videoExtensions.contains(lowered) { return .video }
        return .other
    }

    public struct Pairing: Sendable {
        public var primary: OrganizeFile
        public var companions: [OrganizeFile]
        public var kind: OrganizeMediaKind
    }

    /// Groups files by folder and stem. RAW wins over video, which wins over
    /// ordinary photos; a JPEG beside a RAW of the same stem becomes that
    /// RAW's companion. Sony clip sidecars such as `C0001M01.XML` pair with
    /// `C0001.MP4`. Sidecars without a partner become their own items so no
    /// file is silently left behind.
    public static func pair(_ files: [OrganizeFile]) -> [Pairing] {
        var byFolder: [String: [OrganizeFile]] = [:]
        for file in files {
            byFolder[file.folderPath, default: []].append(file)
        }

        var pairings: [Pairing] = []
        for (_, folderFiles) in byFolder {
            var primaries: [String: (file: OrganizeFile, kind: OrganizeMediaKind)] = [:]
            var secondaryPhotos: [OrganizeFile] = []
            var companions: [OrganizeFile] = []
            var others: [OrganizeFile] = []

            let rank: (OrganizeMediaKind) -> Int = { kind in
                switch kind {
                case .raw: 3
                case .video: 2
                case .photo: 1
                case .other: 0
                }
            }

            for file in folderFiles.sorted(by: { $0.path < $1.path }) {
                let ext = file.fileExtension
                if companionExtensions.contains(ext) {
                    companions.append(file)
                    continue
                }
                let kind = kind(forExtension: ext)
                guard kind != .other else {
                    others.append(file)
                    continue
                }
                let stem = file.stem
                if let existing = primaries[stem] {
                    if rank(kind) > rank(existing.kind) {
                        if existing.kind == .photo { secondaryPhotos.append(existing.file) } else { others.append(existing.file) }
                        primaries[stem] = (file, kind)
                    } else if kind == .photo {
                        secondaryPhotos.append(file)
                    } else {
                        others.append(file)
                    }
                } else {
                    primaries[stem] = (file, kind)
                }
            }

            var attached: [String: [OrganizeFile]] = [:]
            for photo in secondaryPhotos {
                if primaries[photo.stem] != nil {
                    attached[photo.stem, default: []].append(photo)
                } else {
                    others.append(photo)
                }
            }
            for companion in companions {
                let stem = companion.stem
                if primaries[stem] != nil {
                    attached[stem, default: []].append(companion)
                } else if let sonyClip = sonyClipStem(stem), primaries[sonyClip] != nil {
                    attached[sonyClip, default: []].append(companion)
                } else {
                    others.append(companion)
                }
            }

            for (stem, primary) in primaries {
                pairings.append(Pairing(
                    primary: primary.file,
                    companions: (attached[stem] ?? []).sorted { $0.path < $1.path },
                    kind: primary.kind
                ))
            }
            for file in others where !ignoredFileNames.contains(file.name.lowercased()) {
                pairings.append(Pairing(primary: file, companions: [], kind: .other))
            }
        }
        return pairings.sorted { $0.primary.path < $1.primary.path }
    }

    /// `c0001m01` → `c0001`
    static func sonyClipStem(_ stem: String) -> String? {
        guard stem.count > 3 else { return nil }
        let suffix = stem.suffix(3)
        guard suffix.first == "m", suffix.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return String(stem.dropLast(3))
    }

    /// `B0012_DSC01234` → `B0012_`
    public static func burstPrefix(in fileName: String) -> String? {
        let scalars = Array(fileName.unicodeScalars)
        guard scalars.count > 3, scalars[0] == "B" else { return nil }
        var index = 1
        while index < scalars.count, CharacterSet.decimalDigits.contains(scalars[index]) {
            index += 1
        }
        let digitCount = index - 1
        guard (2...6).contains(digitCount), index < scalars.count, scalars[index] == "_" else { return nil }
        return String(String.UnicodeScalarView(scalars[0...index]))
    }

    /// Trailing camera frame number, ignoring any burst prefix.
    public static func frameNumber(in fileName: String) -> Int? {
        var stem = (fileName as NSString).deletingPathExtension
        if let prefix = burstPrefix(in: stem) {
            stem.removeFirst(prefix.count)
        }
        let digits = stem.reversed().prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        return Int(String(digits.reversed()))
    }
}

public struct OrganizeFile: Codable, Hashable, Sendable {
    /// Absolute, standardized path.
    public var path: String
    public var size: Int64
    public var modifiedAt: Date

    public init(path: String, size: Int64, modifiedAt: Date) {
        self.path = path
        self.size = size
        self.modifiedAt = modifiedAt
    }

    public var url: URL { URL(fileURLWithPath: path) }
    public var name: String { (path as NSString).lastPathComponent }
    public var folderPath: String { (path as NSString).deletingLastPathComponent }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    public var stem: String { (name as NSString).deletingPathExtension.lowercased() }
}

public struct OrganizeItem: Identifiable, Hashable, Sendable {
    public var id: String { primary.path }
    public var primary: OrganizeFile
    public var companions: [OrganizeFile]
    public var kind: OrganizeMediaKind
    /// Camera wall-clock time, or an offset-corrected modification time.
    public var captureDate: Date
    public var hasCameraDate: Bool
    public var burstPrefix: String?
    public var frameNumber: Int?

    public init(
        primary: OrganizeFile,
        companions: [OrganizeFile] = [],
        kind: OrganizeMediaKind,
        captureDate: Date,
        hasCameraDate: Bool
    ) {
        self.primary = primary
        self.companions = companions
        self.kind = kind
        self.captureDate = captureDate
        self.hasCameraDate = hasCameraDate
        self.burstPrefix = OrganizeFileClassifier.burstPrefix(in: primary.name)
        self.frameNumber = OrganizeFileClassifier.frameNumber(in: primary.name)
    }

    public var files: [OrganizeFile] { [primary] + companions }
    public var byteCount: Int64 { files.reduce(Int64(0)) { $0 + $1.size } }
}

public struct OrganizeStack: Identifiable, Hashable, Sendable {
    public var id: String
    public var items: [OrganizeItem]

    public init(items: [OrganizeItem]) {
        self.items = items
        self.id = items.first?.id ?? UUID().uuidString
    }

    public var captureDate: Date { items.first?.captureDate ?? .distantPast }
    public var endDate: Date { items.last?.captureDate ?? captureDate }
    public var isBurst: Bool { items.count > 1 }
    public var coverItem: OrganizeItem { items[items.count / 2] }
    public var burstLabel: String? {
        items.first?.burstPrefix.map { String($0.dropLast()) }
    }
    public var files: [OrganizeFile] { items.flatMap(\.files) }
    public var fileCount: Int { items.reduce(0) { $0 + 1 + $1.companions.count } }
    public var byteCount: Int64 { items.reduce(Int64(0)) { $0 + $1.byteCount } }
    public var kind: OrganizeMediaKind { items.first?.kind ?? .other }
}

public struct OrganizeDay: Identifiable, Hashable, Sendable {
    /// `yyyy-MM-dd` in the camera's wall clock.
    public var id: String
    public var date: Date
    public var stacks: [OrganizeStack]

    public init(id: String, date: Date, stacks: [OrganizeStack]) {
        self.id = id
        self.date = date
        self.stacks = stacks
    }

    public var frameCount: Int { stacks.reduce(0) { $0 + $1.items.count } }
    public var byteCount: Int64 { stacks.reduce(Int64(0)) { $0 + $1.byteCount } }
}

public enum OrganizeStacker {
    /// Groups items into bursts and singles.
    ///
    /// A folder whose files already carry `B0001_` prefixes is trusted as-is:
    /// every prefix is one burst and unprefixed files stay single. Other
    /// folders chain consecutive still frames with neighbouring frame
    /// numbers. Gaps up to `configuration.automaticGapSeconds` link directly;
    /// gaps through `maximumGapSeconds` link only when `visualLinks` (from
    /// `BurstVisualLinker`) cleared the pair; longer gaps never link. Chains
    /// smaller than `minimumGroupSize` split back into singles. Video never
    /// stacks.
    public static func stacks(
        for items: [OrganizeItem],
        configuration: BurstGroupingConfiguration = BurstGroupingConfiguration(),
        visualLinks: Set<BurstVisualLink> = []
    ) -> [OrganizeStack] {
        var groups: [[OrganizeItem]] = []
        for sorted in sortedItemsByFolder(items) {
            if sorted.contains(where: { $0.burstPrefix != nil }) {
                var prefixed: [String: [OrganizeItem]] = [:]
                for item in sorted {
                    if let prefix = item.burstPrefix {
                        prefixed[prefix, default: []].append(item)
                    } else {
                        groups.append([item])
                    }
                }
                groups.append(contentsOf: prefixed.values)
            } else {
                var current: [OrganizeItem] = []
                for item in sorted {
                    if let last = current.last, canChain(last, item, configuration: configuration, visualLinks: visualLinks) {
                        current.append(item)
                    } else {
                        append(current, to: &groups, minimumGroupSize: configuration.minimumGroupSize)
                        current = [item]
                    }
                }
                append(current, to: &groups, minimumGroupSize: configuration.minimumGroupSize)
            }
        }

        return groups
            .map { OrganizeStack(items: $0.sorted(by: capturedBefore)) }
            .sorted { lhs, rhs in
                if lhs.captureDate != rhs.captureDate { return lhs.captureDate < rhs.captureDate }
                return lhs.id < rhs.id
            }
    }

    public static func days(for stacks: [OrganizeStack], calendar: Calendar = .current) -> [OrganizeDay] {
        var order: [String] = []
        var byDay: [String: (date: Date, stacks: [OrganizeStack])] = [:]
        for stack in stacks {
            let components = calendar.dateComponents([.year, .month, .day], from: stack.captureDate)
            let key = String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
            if byDay[key] == nil {
                order.append(key)
                byDay[key] = (calendar.startOfDay(for: stack.captureDate), [])
            }
            byDay[key]?.stacks.append(stack)
        }
        return order.sorted().compactMap { key in
            byDay[key].map { OrganizeDay(id: key, date: $0.date, stacks: $0.stacks) }
        }
    }

    /// Items grouped by folder, each in capture order — the order burst
    /// links are decided in.
    static func sortedItemsByFolder(_ items: [OrganizeItem]) -> [[OrganizeItem]] {
        var byFolder: [String: [OrganizeItem]] = [:]
        for item in items {
            byFolder[item.primary.folderPath, default: []].append(item)
        }
        return byFolder.values.map { $0.sorted(by: capturedBefore) }
    }

    static func capturedBefore(_ lhs: OrganizeItem, _ rhs: OrganizeItem) -> Bool {
        if lhs.captureDate != rhs.captureDate { return lhs.captureDate < rhs.captureDate }
        return lhs.primary.path < rhs.primary.path
    }

    /// How two neighbours may link: stills in one folder with camera dates
    /// and neighbouring frame numbers fall into the automatic or
    /// visual-recovery band by gap; everything else stays separate. The
    /// frame-number gate applies to the recovery band too, matching the Sony
    /// Burst Grouper rule.
    public static func linkRequirement(
        from previous: OrganizeItem,
        to next: OrganizeItem,
        configuration: BurstGroupingConfiguration = BurstGroupingConfiguration()
    ) -> BurstLinkRequirement {
        let stills: Set<OrganizeMediaKind> = [.raw, .photo]
        guard stills.contains(previous.kind), stills.contains(next.kind),
              previous.hasCameraDate, next.hasCameraDate,
              previous.primary.folderPath == next.primary.folderPath else { return .separate }
        let gap = next.captureDate.timeIntervalSince(previous.captureDate)
        guard gap >= 0, framesAreConsecutive(previous, next) else { return .separate }
        if gap <= configuration.automaticGapSeconds { return .automatic }
        let recoveryLimit = max(configuration.maximumGapSeconds, configuration.automaticGapSeconds)
        guard configuration.useVisualRecovery, gap <= recoveryLimit else { return .separate }
        return .visualCheck
    }

    /// Frame numbers step forward by 1–3, or wrap from 9990+ back to a low
    /// number. Frames without a usable number can't be disproved, so they
    /// pass.
    static func framesAreConsecutive(_ previous: OrganizeItem, _ next: OrganizeItem) -> Bool {
        guard let a = previous.frameNumber, let b = next.frameNumber else { return true }
        let step = b - a
        let rolledOver = a >= 9_990 && b <= 10
        return (step >= 1 && step <= 3) || rolledOver
    }

    private static func canChain(
        _ previous: OrganizeItem,
        _ next: OrganizeItem,
        configuration: BurstGroupingConfiguration,
        visualLinks: Set<BurstVisualLink>
    ) -> Bool {
        switch linkRequirement(from: previous, to: next, configuration: configuration) {
        case .automatic: return true
        case .visualCheck: return visualLinks.contains(BurstVisualLink(previous: previous, next: next))
        case .separate: return false
        }
    }

    /// Groups below `minimumGroupSize` split back into single-item groups.
    private static func append(_ group: [OrganizeItem], to groups: inout [[OrganizeItem]], minimumGroupSize: Int) {
        guard !group.isEmpty else { return }
        if group.count >= max(1, minimumGroupSize) {
            groups.append(group)
        } else {
            groups.append(contentsOf: group.map { [$0] })
        }
    }
}
