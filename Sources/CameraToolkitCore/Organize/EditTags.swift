import Foundation

/// One file the owner made under an event's `Edited/` folder. Its first
/// folder level is its edit tag: `Edited/Photomator/DSC06778.jpg` is a
/// "Photomator" edit; a file directly in `Edited/` is tagged "Edited".
public struct EditedFile: Hashable, Sendable {
    public var path: String
    public var tag: String

    public init(path: String, tag: String) {
        self.path = path
        self.tag = tag
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// An original a board shows, as the linker sees it.
public struct EditTagCandidate: Sendable {
    /// The board item's id (`OrganizeItem.id`).
    public var itemID: String
    /// The primary file and its companions — any of their stems links.
    public var fileNames: [String]
    /// The camera's capture time; nil when the file carries none.
    public var captureDate: Date?
    public var cameraID: String?

    public init(itemID: String, fileNames: [String], captureDate: Date?, cameraID: String?) {
        self.itemID = itemID
        self.fileNames = fileNames
        self.captureDate = captureDate
        self.cameraID = cameraID
    }
}

/// Which originals have edits, and under which tags.
public struct EditTagIndex: Equatable, Sendable {
    public var tagsByItemID: [String: Set<String>]
    /// Edits no original could be linked to.
    public var unlinked: [EditedFile]
    public var editCount: Int

    public init(tagsByItemID: [String: Set<String>] = [:], unlinked: [EditedFile] = [], editCount: Int = 0) {
        self.tagsByItemID = tagsByItemID
        self.unlinked = unlinked
        self.editCount = editCount
    }

    public func tags(forItemID id: String) -> Set<String> {
        tagsByItemID[id] ?? []
    }

    /// Every tag some original carries, sorted for menus.
    public var allTags: [String] {
        Set(tagsByItemID.values.flatMap { $0 })
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

public enum EditTagLinker {
    /// `Edited/<Tag>/…` under each event folder, read with `readdir` (so
    /// `._` twins can be told apart and skipped). Finder metadata and
    /// AppleDouble files are not edits.
    public static func editedFiles(eventFolders: [URL], fileManager: FileManager = .default) -> [EditedFile] {
        var result: [EditedFile] = []
        var seen: Set<String> = []
        for folder in eventFolders {
            let edited = folder.appendingPathComponent(EventStorageLocations.editedFolderName, isDirectory: true).standardizedFileURL.path
            guard LayoutMigrationDisk.lstatEntry(edited)?.kind == .directory,
                  seen.insert(edited.lowercased()).inserted else { continue }
            for entry in LayoutMigrationDisk.walk(edited, fileManager: fileManager) where entry.kind == .file {
                guard !JunkPolicy.isJunkFile(entry.name) else { continue }
                let relative = String(entry.path.dropFirst(edited.count + 1))
                let components = relative.split(separator: "/")
                let tag = components.count > 1 ? String(components[0]) : EventStorageLocations.editedFolderName
                result.append(EditedFile(path: entry.path, tag: tag))
            }
        }
        return result
    }

    /// The name an edit and its original share: lowercased, without
    /// extensions, burst prefix (`B0012_`), a Keep Both `(N)`, or an edit
    /// suffix (`-edit`, `_Edited`, ` copy`, `-Edit-2`). `DSC06778.ARW`,
    /// `DSC06778.jpg` and `DSC06778-edit.jpg` all give `dsc06778`.
    public static func stem(of name: String) -> String {
        var stem = name.lowercased()
        if let dot = stem.dropFirst().firstIndex(of: ".") {
            stem = String(stem[..<dot])
        }
        let patterns = [
            #"\s*\(\d+\)$"#,
            #"[-_ ](edit|edited|copy|final)([-_ ]?\d+)?$"#,
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                if let range = stem.range(of: pattern, options: .regularExpression), range.lowerBound > stem.startIndex {
                    stem.removeSubrange(range)
                    changed = true
                }
            }
        }
        if let range = stem.range(of: #"^b\d{4}_"#, options: .regularExpression), range.upperBound < stem.endIndex {
            stem.removeSubrange(range)
        }
        return stem
    }

    /// Links each edit to its originals: by stem first; failing that, by
    /// capture time (to the second) and camera, from `metadata` — the
    /// same tags the board's metadata pass reads.
    public static func link(
        edits: [EditedFile],
        candidates: [EditTagCandidate],
        metadata: (EditedFile) -> (captureDate: Date?, cameraID: String?)
    ) -> EditTagIndex {
        var byStem: [String: [String]] = [:]
        var byMoment: [String: [String]] = [:]
        for candidate in candidates {
            for stem in Set(candidate.fileNames.map(stem(of:))) {
                byStem[stem, default: []].append(candidate.itemID)
            }
            if let key = momentKey(candidate.captureDate, candidate.cameraID) {
                byMoment[key, default: []].append(candidate.itemID)
            }
        }
        var index = EditTagIndex(editCount: edits.count)
        for edit in edits {
            var linked = byStem[stem(of: edit.name)] ?? []
            if linked.isEmpty {
                let facts = metadata(edit)
                if let key = momentKey(facts.captureDate, facts.cameraID) {
                    linked = byMoment[key] ?? []
                }
            }
            if linked.isEmpty {
                index.unlinked.append(edit)
            }
            for id in linked {
                index.tagsByItemID[id, default: []].insert(edit.tag)
            }
        }
        return index
    }

    static func momentKey(_ date: Date?, _ camera: String?) -> String? {
        guard let date, let camera, camera != OrganizeCamera.unknownID else { return nil }
        return "\(Int64(date.timeIntervalSince1970.rounded(.down)))|\(camera)"
    }
}
