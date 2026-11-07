import Foundation

/// A frame's identity for burst grouping that does not depend on which copy
/// backs it: file name, byte count and modification second — the same key
/// `FaceIndexStore.fileKey` gives a catalog assignment. A card file, its
/// Buffer copy and its NAS copy all share it, so a burst a card scan found is
/// the same burst on the event board drawn from any of those copies.
public enum BurstFrameIdentity {
    public static func key(for file: OrganizeFile) -> String {
        FaceIndexStore.fileKey(fileName: file.name, byteCount: file.size, modifiedAt: file.modifiedAt)
    }

    public static func key(fileName: String, byteCount: Int64, modifiedAt: Date) -> String {
        FaceIndexStore.fileKey(fileName: fileName, byteCount: byteCount, modifiedAt: modifiedAt)
    }
}

/// The Vision verdicts on recovery-band burst pairs (`BurstVisualLinker`),
/// remembered by frame identity rather than path. A pair the card scan
/// compared answers the same for the Buffer or NAS copies of its frames, so
/// an event board groups exactly the bursts the unsorted board did without
/// fingerprinting again. Memory only — rebuilt by scans and by event boards
/// that may read their files. Thread-safe.
public final class BurstLinkMemory: @unchecked Sendable {
    private struct PairKey: Hashable {
        var previous: String
        var next: String
    }

    private struct Verdict {
        var linked: Bool
        /// The `maximumVisionDistance` the verdict was reached at; a verdict
        /// at another threshold is not an answer.
        var threshold: Float
    }

    private let lock = NSLock()
    private var verdicts: [PairKey: Verdict] = [:]

    public init() {}

    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return verdicts.count
    }

    /// Learns every recovery-band pair a scan compared: linked when the scan
    /// linked it, apart otherwise (a frame whose preview could not be read
    /// stayed apart on that board too, so it stays apart everywhere).
    public func record(_ result: OrganizeScanResult) {
        record(items: result.items, links: result.visualLinks, configuration: result.burstGrouping)
    }

    public func record(items: [OrganizeItem], links: Set<BurstVisualLink>, configuration: BurstGroupingConfiguration) {
        let pairs = BurstVisualLinker.recoveryPairs(for: items, configuration: configuration)
        guard !pairs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for pair in pairs {
            verdicts[Self.key(pair.previous, pair.next)] = Verdict(
                linked: links.contains(BurstVisualLink(previous: pair.previous, next: pair.next)),
                threshold: configuration.maximumVisionDistance
            )
        }
    }

    /// The visual links for `items`, in their own paths. Pairs with a known
    /// verdict are answered from memory; the rest are fingerprinted only when
    /// `computeMissing` (the caller may read these files). A pair whose files
    /// are there but whose preview will not decode is remembered as apart; a
    /// pair whose file did not answer is asked again next time. Without
    /// `computeMissing` an unknown pair stays apart.
    public func links(
        for items: [OrganizeItem],
        configuration: BurstGroupingConfiguration,
        computeMissing: Bool = false,
        concurrency: Int = 4,
        pauseGate: DriveActivityGate? = nil
    ) -> Set<BurstVisualLink> {
        let pairs = BurstVisualLinker.recoveryPairs(for: items, configuration: configuration)
        guard !pairs.isEmpty else { return [] }
        var links = Set<BurstVisualLink>()
        var missing: [(previous: OrganizeItem, next: OrganizeItem)] = []
        lock.lock()
        for pair in pairs {
            if let verdict = verdicts[Self.key(pair.previous, pair.next)],
               verdict.threshold == configuration.maximumVisionDistance {
                if verdict.linked { links.insert(BurstVisualLink(previous: pair.previous, next: pair.next)) }
            } else {
                missing.append(pair)
            }
        }
        lock.unlock()
        guard computeMissing, !missing.isEmpty else { return links }

        let answers = BurstVisualLinker.verdicts(
            forPairs: missing,
            configuration: configuration,
            concurrency: concurrency,
            pauseGate: pauseGate
        )
        // A preview that would not decode from a file that is there stays
        // apart, as on the card board, and is not read again this session;
        // a file that did not answer at all is asked again next time.
        let settled: [Bool?] = zip(missing, answers).map { pair, answer in
            if let answer { return answer }
            let present = FileManager.default.fileExists(atPath: pair.previous.primary.path)
                && FileManager.default.fileExists(atPath: pair.next.primary.path)
            return present ? false : nil
        }
        lock.lock()
        for (pair, answer) in zip(missing, settled) {
            guard let answer else { continue }
            verdicts[Self.key(pair.previous, pair.next)] = Verdict(linked: answer, threshold: configuration.maximumVisionDistance)
            if answer { links.insert(BurstVisualLink(previous: pair.previous, next: pair.next)) }
        }
        lock.unlock()
        return links
    }

    /// Whether any recovery-band pair among `items` has no verdict at this
    /// threshold yet — what `links(…, computeMissing: true)` would read.
    public func hasUnansweredPairs(in items: [OrganizeItem], configuration: BurstGroupingConfiguration) -> Bool {
        let pairs = BurstVisualLinker.recoveryPairs(for: items, configuration: configuration)
        guard !pairs.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        return pairs.contains { pair in
            verdicts[Self.key(pair.previous, pair.next)]?.threshold != configuration.maximumVisionDistance
        }
    }

    private static func key(_ previous: OrganizeItem, _ next: OrganizeItem) -> PairKey {
        PairKey(previous: BurstFrameIdentity.key(for: previous.primary), next: BurstFrameIdentity.key(for: next.primary))
    }
}

/// How an event board cuts its frames into stacks: the same grouping options,
/// Vision links and manual splits the unsorted board used, translated onto
/// whichever copies (card, Buffer, NAS) the board draws. Built on the main
/// actor, used anywhere.
public struct BurstStackingContext: Sendable {
    public var configuration: BurstGroupingConfiguration
    public var splits: [BurstSplit]
    /// Frame identity of split members the board may not draw at that path —
    /// a split made on the card names card paths — keyed by member path key.
    public var memberIdentities: [String: String]
    public var linkMemory: BurstLinkMemory?

    public init(
        configuration: BurstGroupingConfiguration = BurstGroupingConfiguration(),
        splits: [BurstSplit] = [],
        memberIdentities: [String: String] = [:],
        linkMemory: BurstLinkMemory? = nil
    ) {
        self.configuration = configuration
        self.splits = splits
        self.memberIdentities = memberIdentities
        self.linkMemory = linkMemory
    }

    /// True when `stacks(for:computeMissingLinks: true)` would fingerprint
    /// something — a recovery-band pair nobody compared yet.
    public func needsVisualCheck(for items: [OrganizeItem]) -> Bool {
        linkMemory?.hasUnansweredPairs(in: items, configuration: configuration) ?? false
    }

    /// `computeMissingLinks` lets the Vision check read these files for pairs
    /// nobody compared yet — only from a pass that may read them.
    public func stacks(
        for items: [OrganizeItem],
        computeMissingLinks: Bool = false,
        pauseGate: DriveActivityGate? = nil
    ) -> [OrganizeStack] {
        let links = linkMemory?.links(
            for: items,
            configuration: configuration,
            computeMissing: computeMissingLinks,
            pauseGate: pauseGate
        ) ?? []
        return OrganizeStacker.stacks(
            for: items,
            configuration: configuration,
            visualLinks: links,
            splits: Self.splits(splits, onto: items, memberIdentities: memberIdentities)
        )
    }

    /// Each split, with the board's own path for every member it names by
    /// another copy's path. A member is matched by frame identity — through
    /// `memberIdentities` or the board's own files — so the split pins the
    /// same frames whichever copy is drawn. Members the board does not hold
    /// are kept and ignored, as `OrganizeStacker` always did.
    public static func splits(
        _ splits: [BurstSplit],
        onto items: [OrganizeItem],
        memberIdentities: [String: String]
    ) -> [BurstSplit] {
        guard !splits.isEmpty, !items.isEmpty else { return splits }
        var keysByIdentity: [String: [String]] = [:]
        var identityByKey: [String: String] = [:]
        for item in items {
            let identity = BurstFrameIdentity.key(for: item.primary)
            keysByIdentity[identity, default: []].append(item.primary.pathKey)
            identityByKey[item.primary.pathKey] = identity
        }
        return splits.map { split in
            var members = split.memberPathKeys
            var seen = Set(members)
            for member in split.memberPathKeys {
                guard let identity = identityByKey[member] ?? memberIdentities[member] else { continue }
                for key in keysByIdentity[identity] ?? [] where seen.insert(key).inserted {
                    members.append(key)
                }
            }
            guard members.count != split.memberPathKeys.count else { return split }
            var translated = split
            translated.memberPathKeys = members
            return translated
        }
    }
}
