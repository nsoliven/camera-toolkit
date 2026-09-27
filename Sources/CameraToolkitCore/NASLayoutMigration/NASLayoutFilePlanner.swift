import Foundation

/// Per-file mode of the NAS layout migration: a reviewed CSV names every
/// file's destination (`NASLayoutMapping.files`), and the planner only
/// proves it can be done — nothing is guessed, flattened or renamed with a
/// `(N)` suffix.
///
/// Read-only like the event mode: one listing per source folder (the CSV
/// says which), one `lstat` per destination folder and its missing parents,
/// one listing per destination folder that already exists, and the catalog
/// through a read-only connection.
///
/// What it proves or refuses:
/// - every CSV file is on the NAS with the size the inventory saw (else a
///   blocker: the CSV is stale); a folder that cannot be listed, or a file
///   this user cannot read, is skipped and reported;
/// - no two files take one destination and no destination (or its
///   AppleDouble twin) exists, compared case-insensitively as SMB does —
///   a collision is refused, never renamed;
/// - every rename stays on one volume and inside one dataset or share
///   (`boundaries`): a server-side rename cannot cross either;
/// - an AppleDouble `._NAME` beside a moving `NAME` moves with it when the
///   CSV does not list it; a listed twin must go where its file goes;
/// - catalog event renames (`eventRenames`) resolve to one event each and
///   give the app's `<year>/<yyyy-MM-dd> <name>` folder; a drive folder
///   still under the old name is a blocker;
/// - for every catalog event whose (renamed) NAS folder the CSV fills, its
///   assignments move their file to the app's path
///   `<event>/Originals/<Camera>/<relative path>` (same-name sidecars
///   follow), so presence finds the files where the app looks.
extension NASLayoutMigrationPlanner {
    /// One CSV row that is on the NAS.
    private struct FileCandidate {
        var row: Int
        var source: String
        var destination: String?
        var csvDestination: String?
        var entry: DirectoryListingEntry
        var folder: String
    }

    func planFiles(_ inputs: Inputs) throws -> NASLayoutMigrationPlan {
        let mapping = inputs.mapping
        let rows = mapping.files ?? []
        let locations = EventStorageLocations(configuration: inputs.configuration)
        let libraryRoot = URL(fileURLWithPath: NSString(string: mapping.legacyRoot ?? locations.libraryRoot.path).expandingTildeInPath)
            .standardizedFileURL.path
        let mirrorRoot = URL(fileURLWithPath: NSString(string: mapping.mirrorRoot ?? locations.nasRoot.path).expandingTildeInPath)
            .standardizedFileURL.path
        var blockers = mapping.problems()
        var notes: [String] = []
        var leftInPlace: [NASLayoutMigrationPlan.LeftInPlace] = []
        var unreadable: [NASLayoutMigrationPlan.Issue] = []
        var refused: [NASLayoutMigrationPlan.Issue] = []
        var listed = 0
        let libraryEntry = LayoutMigrationDisk.lstatEntry(libraryRoot)
        let mirrorEntry = LayoutMigrationDisk.lstatEntry(mirrorRoot)
        if libraryEntry?.kind != .directory { blockers.append("The library root \(libraryRoot) is not reachable.") }
        if mirrorEntry?.kind != .directory { blockers.append("The mirror root \(mirrorRoot) is not reachable.") }
        if let libraryEntry, let mirrorEntry, libraryEntry.device != mirrorEntry.device {
            blockers.append("The library root and the mirror root are on different volumes; the migration only renames on one share.")
        }
        let mirrorDevice = mirrorEntry?.device
        let boundaries = (mapping.boundaries ?? []).map { (libraryRoot + "/" + $0).lowercased() }
        func boundary(of path: String) -> String? {
            boundaries.filter { path.lowercased().hasPrefix($0 + "/") }.max { $0.count < $1.count }
        }

        var snapshot: NASLayoutMigrationCatalog.Snapshot?
        if let catalogURL = inputs.catalogURL, FileManager.default.fileExists(atPath: catalogURL.path) {
            snapshot = try NASLayoutMigrationCatalog.snapshot(catalogURL: catalogURL)
        }

        // MARK: Catalog event renames
        let ownsState = snapshot?.base.ownsState ?? false
        let currentEvents = ownsState ? snapshot?.base.state.savedEvents ?? [] : inputs.configuration.savedEvents
        let assignments = ownsState ? snapshot?.base.state.photoEventAssignments ?? [] : inputs.configuration.photoEventAssignments
        var renamedEvents = currentEvents
        var renameChanges: [NASLayoutMigrationPlan.EventRenameChange] = []
        let renames = mapping.eventRenames ?? []
        if !renames.isEmpty, !ownsState {
            blockers.append("Catalog event renames need a catalog that holds the events (the events are still in config.json).")
        }
        var renamedIDs: [UUID: String] = [:]
        for rename in renames {
            let matches = UUID(uuidString: rename.event).map { id in currentEvents.filter { $0.id == id } }
                ?? currentEvents.filter { $0.name == rename.event }
            guard matches.count == 1, let event = matches.first else {
                blockers.append("The catalog event rename \"\(rename.event)\" → \"\(rename.name)\" matches \(matches.count) events; name exactly one by its id or current name.")
                continue
            }
            guard renamedIDs.updateValue(rename.name, forKey: event.id) == nil else {
                blockers.append("The catalog event \(event.name) is renamed twice.")
                continue
            }
            if let index = renamedEvents.firstIndex(where: { $0.id == event.id }) { renamedEvents[index].name = rename.name }
        }
        func locationsFor(_ events: [SavedCameraEvent]) -> EventStorageLocations {
            var configuration = inputs.configuration
            configuration.savedEvents = events
            return EventStorageLocations(configuration: configuration)
        }
        let before = locationsFor(currentEvents)
        let after = locationsFor(renamedEvents)
        let mounted = VolumeInfo.mountedVolumePaths()
        for event in currentEvents where renamedIDs[event.id] != nil {
            guard let renamed = renamedEvents.first(where: { $0.id == event.id }) else { continue }
            let oldMirror = before.layout(for: event, deviceID: nil).mirrorEventFolderPath
            let newMirror = after.layout(for: renamed, deviceID: nil).mirrorEventFolderPath
            let policy = before.resolvedPolicy(for: event)
            let oldDrive = before.eventFolder(for: event, policy: policy).path
            let newDrive = after.eventFolder(for: renamed, policy: policy).path
            let state: NASLayoutMigrationPlan.EventRenameChange.DriveFolderState
            if !VolumeInfo.isAvailable(URL(fileURLWithPath: oldDrive), mountedVolumes: mounted) {
                state = .offline
                notes.append("The drive for \"\(event.name)\" is not mounted; nothing proves there is no \(oldDrive) to rename with the event. Check it before executing.")
            } else if LayoutMigrationDisk.lstatEntry(oldDrive) != nil {
                state = .present
                blockers.append("\(oldDrive) holds the drive copy of \"\(event.name)\" under the old name; rename it to \((newDrive as NSString).lastPathComponent) with the event (the app then finds it), then plan again.")
            } else {
                state = .absent
            }
            if LayoutMigrationDisk.lstatEntry(newDrive) != nil, oldDrive.lowercased() != newDrive.lowercased() {
                blockers.append("\(newDrive) already exists; the renamed event \"\(renamed.name)\" would adopt it.")
            }
            let prefix = oldDrive.lowercased() + "/"
            let adopted = assignments.filter { $0.eventID == event.id && ($0.sourceRootPath.lowercased() + "/").hasPrefix(prefix) }.count
            if adopted > 0 {
                notes.append("\"\(event.name)\": \(adopted) assignment(s) name a source root inside \(oldDrive), which \(state == .absent ? "does not exist" : "is \(state.rawValue)"); their rows are left as they are (their id is their path).")
            }
            if currentEvents.contains(where: { $0.parentEventID == event.id }) {
                notes.append("\"\(event.name)\" has subevents; their NAS and drive folders move with its new name.")
            }
            if inputs.configuration.selectedEventID == event.id {
                notes.append("\"\(event.name)\" is the selected event; config.json keeps the old eventName until the app loads the catalog and re-selects it.")
            }
            renameChanges.append(.init(
                eventID: event.id, oldName: event.name, newName: renamed.name,
                oldMirrorFolder: oldMirror, newMirrorFolder: newMirror,
                oldDriveFolder: oldDrive, newDriveFolder: newDrive,
                driveFolderState: state,
                assignmentsUnderOldDriveFolder: adopted
            ))
        }
        var mirrorFolders: [String: UUID] = [:]
        for event in renamedEvents {
            let folder = after.layout(for: event, deviceID: nil).mirrorEventFolderPath.lowercased()
            if let other = mirrorFolders.updateValue(event.id, forKey: folder), renamedIDs[event.id] != nil || renamedIDs[other] != nil {
                blockers.append("After the renames two catalog events share the NAS folder \(folder).")
            }
        }

        // MARK: Listing — one per source folder
        var byFolder: [String: [Int]] = [:]
        for (index, row) in rows.enumerated() {
            byFolder[(row.source as NSString).deletingLastPathComponent, default: []].append(index)
        }
        var rowFolderAncestors = Set<String>()
        for folder in byFolder.keys {
            var current = folder
            while !current.isEmpty {
                rowFolderAncestors.insert(current.lowercased())
                current = (current as NSString).deletingLastPathComponent
            }
        }
        var candidates: [FileCandidate] = []
        var listings: [String: String] = [:]
        var entriesByFolder: [String: [String: DirectoryListingEntry]] = [:]
        var missing: [String] = []
        var resized: [String] = []
        var folderDevices: [String: UInt64] = [:]
        let rowSources = Set(rows.map { $0.source.lowercased() })
        for folder in byFolder.keys.sorted() {
            let absolute = folder.isEmpty ? libraryRoot : libraryRoot + "/" + folder
            listed += 1
            let entries: [DirectoryListingEntry]
            do {
                entries = try DirectoryListing.list(absolute)
            } catch {
                unreadable.append(.init(path: absolute, reason: "\(error.localizedDescription) — its \(byFolder[folder]?.count ?? 0) mapped file(s) are skipped"))
                continue
            }
            if let device = LayoutMigrationDisk.lstatEntry(absolute)?.device { folderDevices[absolute] = device }
            // `.DS_Store` never moves and Finder rewrites it at will; it is
            // left out of the fingerprint.
            listings[absolute] = LayoutMigrationHash.sha256(entries
                .filter { $0.name != ".DS_Store" }
                .map { "\($0.name)\t\($0.kind.rawValue)\t\($0.size)\t\($0.modifiedAt)" }
                .sorted()
                .joined(separator: "\n"))
            let byName = Dictionary(entries.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            entriesByFolder[absolute] = byName
            for index in byFolder[folder] ?? [] {
                let row = rows[index]
                let name = (row.source as NSString).lastPathComponent
                let path = libraryRoot + "/" + row.source
                guard let destination = row.destination else {
                    // Staying files are only reported: a Finder file that
                    // changed or went away does not stale the plan.
                    leftInPlace.append(.init(path: path, reason: byName[name] == nil ? "The file mapping leaves it in place; it is gone already" : "The file mapping leaves it in place"))
                    continue
                }
                guard let entry = byName[name] else {
                    missing.append(row.source)
                    continue
                }
                guard entry.kind == .file else {
                    refused.append(.init(path: path, reason: entry.kind == .symlink ? "Symlinks are never followed or moved." : "Not a regular file."))
                    continue
                }
                if entry.size != row.byteCount {
                    resized.append("\(row.source) (\(entry.size) bytes, the mapping says \(row.byteCount))")
                    continue
                }
                guard entry.isReadable else {
                    unreadable.append(.init(path: path, reason: "Not readable by this user; skipped (it stays where it is)"))
                    continue
                }
                candidates.append(FileCandidate(
                    row: index, source: path, destination: mirrorRoot + "/" + destination,
                    csvDestination: mirrorRoot + "/" + destination, entry: entry, folder: absolute
                ))
            }
            // What the CSV does not list: AppleDouble twins are decided
            // below; anything else stays and is reported.
            for entry in entries {
                let relative = folder.isEmpty ? entry.name : folder + "/" + entry.name
                if rowSources.contains(relative.lowercased()) { continue }
                if entry.kind == .directory {
                    if !rowFolderAncestors.contains(relative.lowercased()) {
                        leftInPlace.append(.init(path: absolute + "/" + entry.name, reason: "A folder the file mapping does not list; stays"))
                    }
                    continue
                }
                if entry.name.hasPrefix("._") { continue }
                leftInPlace.append(.init(path: absolute + "/" + entry.name, reason: "Not in the file mapping; stays"))
            }
        }
        if !missing.isEmpty {
            blockers.append("\(missing.count) file(s) in the file mapping are not on the NAS (the CSV is stale): \(missing.prefix(10).joined(separator: ", "))\(missing.count > 10 ? ", …" : "")")
        }
        if !resized.isEmpty {
            blockers.append("\(resized.count) file(s) changed size since the inventory: \(resized.prefix(10).joined(separator: ", "))\(resized.count > 10 ? ", …" : "")")
        }

        // MARK: Catalog events whose NAS folder the CSV fills
        var attached: [NASLayoutMigrationPlan.AttachedEvent] = []
        var alignedTotal = 0
        let moving = candidates.indices.filter { !candidates[$0].entry.name.hasPrefix("._") }
        for event in renamedEvents {
            let folder = after.layout(for: event, deviceID: nil).mirrorEventFolderPath
            let prefix = (mirrorRoot + "/" + folder).lowercased() + "/"
            // Only the event's own files: not a subevent's folder inside it.
            let childFolders = renamedEvents.filter { $0.parentEventID == event.id }
                .map { (mirrorRoot + "/" + after.layout(for: $0, deviceID: nil).mirrorEventFolderPath).lowercased() + "/" }
            let inEvent = moving.filter { index in
                let destination = candidates[index].destination?.lowercased() ?? ""
                return destination.hasPrefix(prefix) && !childFolders.contains { destination.hasPrefix($0) }
            }
            guard !inEvent.isEmpty else { continue }
            let eventAssignments = assignments.filter { $0.eventID == event.id }
            var byNameSize: [String: [Int]] = [:]
            for index in inEvent {
                byNameSize[candidates[index].entry.name.lowercased() + "\u{0}\(candidates[index].entry.size)", default: []].append(index)
            }
            var assignmentKeys: [String: Int] = [:]
            for assignment in eventAssignments {
                assignmentKeys[(assignment.relativePath as NSString).lastPathComponent.lowercased() + "\u{0}\(assignment.fileSize)", default: 0] += 1
            }
            var info = NASLayoutMigrationPlan.AttachedEvent(
                eventID: event.id, name: event.name, mirrorFolder: folder, assignments: eventAssignments.count,
                matched: 0, alreadyAligned: 0, aligned: 0, followers: 0, keptNonPortable: 0, unmatched: 0
            )
            // source folder + base name → the folder its assigned file took
            var takenFolder: [String: Set<String>] = [:]
            var decided = Set<Int>()
            for assignment in eventAssignments {
                let key = (assignment.relativePath as NSString).lastPathComponent.lowercased() + "\u{0}\(assignment.fileSize)"
                guard assignmentKeys[key] == 1, let hits = byNameSize[key], hits.count == 1, let index = hits.first,
                      let expectedRelative = try? after.layout(for: event, deviceID: assignment.deviceID).mirrorRelativePath(for: assignment.relativePath) else {
                    info.unmatched += 1
                    continue
                }
                info.matched += 1
                decided.insert(index)
                let expected = mirrorRoot + "/" + expectedRelative
                let base = KeepBothNaming.split(candidates[index].entry.name).base.lowercased()
                let groupKey = candidates[index].folder.lowercased() + "\u{0}" + base
                if candidates[index].destination == expected {
                    info.alreadyAligned += 1
                } else if !Self.isPortable(assignment.relativePath) {
                    info.keptNonPortable += 1
                    continue
                } else {
                    candidates[index].destination = expected
                    info.aligned += 1
                }
                takenFolder[groupKey, default: []].insert((expected as NSString).deletingLastPathComponent)
            }
            // Same-name files the catalog does not list (sidecars) follow
            // when their assigned file took one folder only, and they sat
            // flat beside it in the CSV.
            for index in inEvent where !decided.contains(index) {
                let base = KeepBothNaming.split(candidates[index].entry.name).base.lowercased()
                guard let folders = takenFolder[candidates[index].folder.lowercased() + "\u{0}" + base], folders.count == 1,
                      let target = folders.first, let current = candidates[index].destination else { continue }
                let currentFolder = (current as NSString).deletingLastPathComponent
                guard currentFolder != target, target.lowercased().hasPrefix(currentFolder.lowercased() + "/") else { continue }
                candidates[index].destination = target + "/" + candidates[index].entry.name
                info.followers += 1
            }
            alignedTotal += info.aligned + info.followers
            if info.keptNonPortable > 0 {
                notes.append("\"\(event.name)\": \(info.keptNonPortable) assigned file(s) keep the CSV path because the app's path has a character SMB cannot store portably (one of \(Self.nonPortableCharacters), or a trailing space or dot); presence will not find them there.")
            }
            attached.append(info)
        }

        // MARK: AppleDouble twins
        var fileIndexBySource: [String: Int] = [:]
        for index in moving { fileIndexBySource[candidates[index].source.lowercased()] = index }
        var unlistedTwins: [(source: String, entry: DirectoryListingEntry, file: Int)] = []
        var listedTwins: [Int: Int] = [:]
        for index in candidates.indices where candidates[index].entry.name.hasPrefix("._") {
            let twinOf = LayoutMigrationDisk.appleDoubleFile(of: candidates[index].source)
            if let file = fileIndexBySource[twinOf.lowercased()] {
                let expected = LayoutMigrationDisk.appleDoubleTwin(of: candidates[file].csvDestination ?? "")
                if candidates[index].csvDestination != expected {
                    blockers.append("\(candidates[index].source) goes to \(candidates[index].csvDestination ?? "-"), not beside its file at \(candidates[file].csvDestination ?? "-").")
                }
                listedTwins[index] = file
            } else {
                blockers.append("\(candidates[index].source) moves without its file \((twinOf as NSString).lastPathComponent).")
            }
        }
        for (index, row) in rows.enumerated() where row.destination == nil {
            let name = (row.source as NSString).lastPathComponent
            guard name.hasPrefix("._") else { continue }
            let owner = LayoutMigrationDisk.appleDoubleFile(of: libraryRoot + "/" + row.source).lowercased()
            if fileIndexBySource[owner] != nil {
                blockers.append("\(row.source) is left in place but its file moves; an AppleDouble twin goes with its file. (row \(index + 2))")
            }
        }
        for index in moving {
            let twin = LayoutMigrationDisk.appleDoubleTwin(of: candidates[index].source)
            let folder = candidates[index].folder
            let name = (twin as NSString).lastPathComponent
            guard let entry = entriesByFolder[folder]?[name] else { continue }
            let relative = String(twin.dropFirst(libraryRoot.count + 1))
            if rowSources.contains(relative.lowercased()) { continue }
            guard entry.kind == .file else { continue }
            unlistedTwins.append((twin, entry, index))
        }
        for entriesInFolder in entriesByFolder {
            for (name, entry) in entriesInFolder.value where name.hasPrefix("._") && entry.kind == .file {
                let path = entriesInFolder.key + "/" + name
                let relative = String(path.dropFirst(libraryRoot.count + 1))
                if rowSources.contains(relative.lowercased()) { continue }
                if fileIndexBySource[LayoutMigrationDisk.appleDoubleFile(of: path).lowercased()] == nil {
                    leftInPlace.append(.init(path: path, reason: "AppleDouble file whose file does not move; stays"))
                }
            }
        }

        // MARK: Moves
        var moves: [NASLayoutMigrationPlan.Move] = []
        var moveIndexOfCandidate: [Int: Int] = [:]
        for index in moving.sorted(by: { candidates[$0].source < candidates[$1].source }) {
            let candidate = candidates[index]
            moveIndexOfCandidate[index] = moves.count
            moves.append(.init(
                source: candidate.source,
                destination: candidate.destination ?? "",
                byteCount: candidate.entry.size,
                modifiedAt: candidate.entry.modifiedAt,
                kind: Self.kind(of: candidate.entry.name),
                renamed: (candidate.destination as NSString?)?.lastPathComponent != candidate.entry.name,
                companionOf: nil
            ))
        }
        for (twin, file) in listedTwins.sorted(by: { candidates[$0.key].source < candidates[$1.key].source }) {
            guard let fileMove = moveIndexOfCandidate[file] else { continue }
            moves.append(.init(
                source: candidates[twin].source,
                destination: LayoutMigrationDisk.appleDoubleTwin(of: moves[fileMove].destination),
                byteCount: candidates[twin].entry.size,
                modifiedAt: candidates[twin].entry.modifiedAt,
                kind: .appleDouble,
                renamed: moves[fileMove].renamed,
                companionOf: fileMove
            ))
        }
        for twin in unlistedTwins.sorted(by: { $0.source < $1.source }) {
            guard let fileMove = moveIndexOfCandidate[twin.file] else { continue }
            moves.append(.init(
                source: twin.source,
                destination: LayoutMigrationDisk.appleDoubleTwin(of: moves[fileMove].destination),
                byteCount: twin.entry.size,
                modifiedAt: twin.entry.modifiedAt,
                kind: .appleDouble,
                renamed: moves[fileMove].renamed,
                companionOf: fileMove
            ))
        }

        // MARK: Destinations: collisions, volume, boundaries
        var conflicts: [NASLayoutMigrationPlan.Conflict] = []
        var claimed: [String: String] = [:]
        var existence: [String: LayoutMigrationEntry?] = [:]
        func entry(_ path: String) -> LayoutMigrationEntry? {
            if let cached = existence[path] { return cached }
            let found = LayoutMigrationDisk.lstatEntry(path)
            existence[path] = found
            return found
        }
        var destinationListings: [String: Set<String>] = [:]
        var crossings: [String] = []
        var blockedAncestors = Set<String>()
        for move in moves {
            let lower = move.destination.lowercased()
            if let other = claimed.updateValue(move.source, forKey: lower) {
                conflicts.append(.init(source: move.source, plannedDestination: move.destination, resolvedDestination: move.destination, reason: .claimedByAnotherFile, existingByteCount: nil))
                blockers.append("\(move.source) and \(other) both go to \(move.destination).")
                continue
            }
            let folder = (move.destination as NSString).deletingLastPathComponent
            // Nearest existing ancestor.
            var ancestor = folder
            while entry(ancestor) == nil {
                let parent = (ancestor as NSString).deletingLastPathComponent
                if parent == ancestor { break }
                ancestor = parent
            }
            let found = entry(ancestor)
            if let found, found.kind != .directory {
                if blockedAncestors.insert(ancestor).inserted {
                    blockers.append("\(ancestor) is a file; \(move.destination) cannot be created below it.")
                }
                continue
            }
            if ancestor == folder {
                if destinationListings[folder] == nil {
                    listed += 1
                    destinationListings[folder] = Set(((try? DirectoryListing.list(folder)) ?? []).map { $0.name.lowercased() })
                }
                let names = destinationListings[folder] ?? []
                let name = (move.destination as NSString).lastPathComponent.lowercased()
                if names.contains(name) {
                    conflicts.append(.init(source: move.source, plannedDestination: move.destination, resolvedDestination: move.destination, reason: .destinationExists, existingByteCount: nil))
                    blockers.append("\(move.destination) already exists on the NAS; \(move.source) is not moved onto it.")
                } else if move.kind != .appleDouble, names.contains("._" + name), !claimed.keys.contains(LayoutMigrationDisk.appleDoubleTwin(of: lower)) {
                    conflicts.append(.init(source: move.source, plannedDestination: move.destination, resolvedDestination: move.destination, reason: .destinationExists, existingByteCount: nil))
                    blockers.append("An AppleDouble file already sits at \(LayoutMigrationDisk.appleDoubleTwin(of: move.destination)).")
                }
            }
            if let found, let mirrorDevice, found.device != mirrorDevice {
                crossings.append("\(move.destination) is on another volume than the mirror root")
            }
            let sourceFolder = (move.source as NSString).deletingLastPathComponent
            if let device = folderDevices[sourceFolder], let mirrorDevice, device != mirrorDevice {
                crossings.append("\(move.source) is on another volume than the mirror root")
            }
            if boundary(of: move.source) != boundary(of: move.destination) {
                crossings.append("\(move.source) → \(move.destination) crosses the dataset/share boundary \(boundary(of: move.source) ?? boundary(of: move.destination) ?? "")")
            }
        }
        if !crossings.isEmpty {
            blockers.append("\(crossings.count) rename(s) would cross a volume, dataset or share boundary, which a rename cannot do: \(crossings.prefix(10).joined(separator: "; "))\(crossings.count > 10 ? "; …" : "")")
        }

        // MARK: Events: one per destination event folder
        func eventFolder(of destination: String) -> String {
            let relative = String(destination.dropFirst(mirrorRoot.count + 1))
            let parts = relative.split(separator: "/").map(String.init)
            if let cut = parts.indices.dropFirst().first(where: { EventStorageLocations.reservedEventFolderNames.contains(parts[$0]) }) {
                return parts[..<cut].joined(separator: "/")
            }
            return parts.prefix(min(2, max(parts.count - 1, 1))).joined(separator: "/")
        }
        func legacyUnit(of source: String) -> String {
            let parts = String(source.dropFirst(libraryRoot.count + 1)).split(separator: "/").map(String.init).dropLast()
            let depth = parts.first == CameraLibraryFolder.originals.rawValue ? 3 : 2
            return parts.prefix(depth).joined(separator: "/")
        }
        var groups: [String: [Int]] = [:]
        for index in moves.indices where moves[index].companionOf == nil {
            groups[eventFolder(of: moves[index].destination), default: []].append(index)
        }
        for index in moves.indices {
            if let file = moves[index].companionOf { groups[eventFolder(of: moves[file].destination), default: []].append(index) }
        }
        var events: [NASLayoutMigrationPlan.Event] = []
        for (number, key) in groups.keys.sorted().enumerated() {
            let members = groups[key] ?? []
            var local: [NASLayoutMigrationPlan.Move] = []
            var remap: [Int: Int] = [:]
            for member in members where moves[member].companionOf == nil {
                remap[member] = local.count
                local.append(moves[member])
            }
            for member in members where moves[member].companionOf != nil {
                var move = moves[member]
                move.companionOf = move.companionOf.flatMap { remap[$0] }
                local.append(move)
            }
            let units = Array(Set(local.map { legacyUnit(of: $0.source) })).sorted()
            events.append(.init(
                id: String(format: "E%04d", number + 1),
                source: units.joined(separator: " + "),
                destination: key,
                sourcePath: libraryRoot,
                destinationPath: mirrorRoot + "/" + key,
                cameras: [],
                moves: local,
                sourceDirectories: [],
                keptSubfolders: [],
                knownSubfolderFiles: 0,
                ambiguousKnownNames: 0,
                byteCount: local.reduce(0) { $0 + $1.byteCount }
            ))
        }

        // Source folders the moves may empty: each moved file's folder and
        // its parents, never the library root or its top-level folders.
        var directories = Set<String>()
        for move in moves {
            var folder = (move.source as NSString).deletingLastPathComponent
            while folder.hasPrefix(libraryRoot + "/"), String(folder.dropFirst(libraryRoot.count + 1)).split(separator: "/").count >= 2 {
                directories.insert(folder)
                folder = (folder as NSString).deletingLastPathComponent
            }
        }
        let sourceDirectories = directories.sorted {
            let a = $0.split(separator: "/").count, b = $1.split(separator: "/").count
            return a == b ? $0 > $1 : a > b
        }

        // MARK: Catalog rows
        let allMoves = events.flatMap(\.moves)
        var catalog = Self.catalogChanges(snapshot: snapshot, moves: allMoves, blockers: &blockers)
        if let snapshot {
            var moveBySource: [String: NASLayoutMigrationPlan.Move] = [:]
            for move in allMoves where move.companionOf == nil { moveBySource[move.source.lowercased()] = move }
            var rewrites: [LayoutMigrationPlan.AssignmentRewrite] = []
            let existingIDs = Set(snapshot.base.state.photoEventAssignments.map(CatalogStore.eventAssetID))
            for assignment in snapshot.base.state.photoEventAssignments {
                let key = EventStorageLocations.pathKey((assignment.sourceRootPath as NSString).appendingPathComponent(assignment.relativePath))
                guard let move = moveBySource[key] else { continue }
                var updated = assignment
                if move.destination.hasSuffix("/" + assignment.relativePath) {
                    updated.sourceRootPath = String(move.destination.dropLast(assignment.relativePath.count + 1))
                } else {
                    updated.sourceRootPath = (move.destination as NSString).deletingLastPathComponent
                    updated.relativePath = (move.destination as NSString).lastPathComponent
                }
                let newID = CatalogStore.eventAssetID(updated)
                if existingIDs.contains(newID) {
                    blockers.append("An assignment already exists for \(move.destination); re-pointing \(key) onto it would merge two rows.")
                }
                rewrites.append(.init(
                    oldID: CatalogStore.eventAssetID(assignment), newID: newID, eventID: assignment.eventID,
                    oldSourceRootPath: assignment.sourceRootPath, newSourceRootPath: updated.sourceRootPath,
                    oldRelativePath: assignment.relativePath, newRelativePath: updated.relativePath,
                    destination: move.destination
                ))
            }
            catalog.assignmentRewrites = rewrites
        }
        catalog.eventRenames = renameChanges
        catalog.attachedEvents = attached

        let stays = rows.filter { $0.destination == nil }.count
        let summary = NASLayoutMigrationPlan.Summary(
            events: events.count,
            files: allMoves.count,
            byteCount: allMoves.reduce(0) { $0 + $1.byteCount },
            appleDoubleFiles: allMoves.count { $0.kind == .appleDouble },
            conflicts: conflicts.count,
            renamedFiles: allMoves.count { $0.renamed },
            unknownCameras: 0,
            keptSubfolders: 0,
            knownSubfolderFiles: alignedTotal,
            leftInPlace: leftInPlace.count,
            unreadable: unreadable.count,
            refused: refused.count,
            facePhotoRewrites: catalog.facePhotoRewrites.count,
            syncRecordRewrites: catalog.syncRecordRewrites.count,
            foldersListed: listed
        )
        return NASLayoutMigrationPlan(
            format: NASLayoutMigrationPlan.formatName,
            version: NASLayoutMigrationPlan.currentVersion,
            id: UUID(),
            createdAt: Date(timeIntervalSince1970: now().timeIntervalSince1970.rounded(.down)),
            supportFolderPath: inputs.supportFolder.standardizedFileURL.path,
            configurationPath: inputs.configurationURL.standardizedFileURL.path,
            catalogPath: inputs.catalogURL.map { $0.standardizedFileURL.path },
            legacyRoot: libraryRoot,
            mirrorRoot: mirrorRoot,
            mappingDigest: LayoutMigrationHash.sha256(try LayoutMigrationPlan.encoder().encode(mapping)),
            mapping: {
                var resolved = mapping
                resolved.legacyRoot = libraryRoot
                resolved.mirrorRoot = mirrorRoot
                return resolved
            }(),
            events: events,
            conflicts: conflicts,
            unknownCameras: [],
            leftInPlace: leftInPlace.sorted { $0.path < $1.path },
            unreadable: unreadable,
            refused: refused,
            blockers: blockers,
            notes: notes,
            catalog: catalog,
            fingerprint: .init(folderListings: listings, catalogDigest: snapshot?.digest),
            summary: summary,
            sourceDirectories: sourceDirectories,
            fileMapping: .init(
                digest: mapping.fileMappingDigest ?? "",
                rows: rows.count,
                moves: rows.count - stays,
                unlistedTwins: unlistedTwins.count,
                stays: stays,
                alignedToCatalog: alignedTotal
            )
        )
    }

    /// Characters SMB (and exFAT drives) cannot store as themselves.
    static let nonPortableCharacters = ":\\*?\"<>|"
    static let nonPortable = CharacterSet(charactersIn: nonPortableCharacters)

    static func isPortable(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").allSatisfy { component in
            component.rangeOfCharacter(from: nonPortable) == nil && !component.hasSuffix(" ") && !component.hasSuffix(".")
        }
    }

    /// The catalog rows that name a moved NAS path: face photos (and their
    /// faces), rotations of renamed files, burst splits, Sync to NAS
    /// records. Shared by both modes.
    static func catalogChanges(
        snapshot: NASLayoutMigrationCatalog.Snapshot?,
        moves: [NASLayoutMigrationPlan.Move],
        blockers: inout [String]
    ) -> NASLayoutMigrationPlan.CatalogChanges {
        var catalog = NASLayoutMigrationPlan.CatalogChanges(
            facePhotoRewrites: [], orientationCopies: [], burstSplitRewrites: [], syncRecordRewrites: [],
            tableCounts: [:], confirmedFaces: 0, markerKey: NASLayoutMigrationExecutor.markerKey
        )
        guard let snapshot else { return catalog }
        var moveBySource: [String: NASLayoutMigrationPlan.Move] = [:]
        for move in moves where move.companionOf == nil { moveBySource[move.source.lowercased()] = move }
        catalog.tableCounts = snapshot.base.tableCounts
        catalog.confirmedFaces = snapshot.base.confirmedFaces
        let existingKeys = Set(snapshot.base.facePhotos.map(\.pathKey))
        var movingAway = Set<String>()
        for photo in snapshot.base.facePhotos {
            guard let move = moveBySource[photo.pathKey] else { continue }
            let newKey = EventStorageLocations.pathKey(move.destination)
            catalog.facePhotoRewrites.append(.init(
                oldPathKey: photo.pathKey,
                newPathKey: newKey,
                newPath: move.destination,
                newFileName: (move.destination as NSString).lastPathComponent,
                confirmedFaceCount: photo.confirmedFaceCount
            ))
            movingAway.insert(photo.pathKey)
        }
        for rewrite in catalog.facePhotoRewrites where existingKeys.contains(rewrite.newPathKey) && !movingAway.contains(rewrite.newPathKey) {
            blockers.append("A face photo row already exists for \(rewrite.newPath); re-keying \(rewrite.oldPathKey) onto it would merge two photos.")
        }
        for move in moves where move.renamed && move.companionOf == nil {
            let date = Date(timeIntervalSinceReferenceDate: move.modifiedAt)
            let oldKey = FaceIndexStore.fileKey(fileName: (move.source as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date)
            let newKey = FaceIndexStore.fileKey(fileName: (move.destination as NSString).lastPathComponent, byteCount: move.byteCount, modifiedAt: date)
            if let turns = snapshot.base.state.displayOrientations[oldKey], snapshot.base.state.displayOrientations[newKey] == nil {
                catalog.orientationCopies.append(.init(oldKey: oldKey, newKey: newKey, quarterTurns: turns))
            }
        }
        for split in snapshot.base.state.burstSplits {
            let mapped = split.memberPathKeys.map { key in moveBySource[key].map { EventStorageLocations.pathKey($0.destination) } ?? key }
            if mapped != split.memberPathKeys {
                catalog.burstSplitRewrites.append(.init(id: split.id, oldMemberPathKeys: split.memberPathKeys, newMemberPathKeys: mapped))
            }
        }
        for row in snapshot.syncRecords {
            guard let move = moveBySource[(row.nasRoot + "/" + row.relativePath).lowercased()] else { continue }
            guard move.destination.hasPrefix(row.nasRoot + "/") else {
                blockers.append("A Sync to NAS record for \(row.relativePath) would move outside its NAS root \(row.nasRoot).")
                continue
            }
            catalog.syncRecordRewrites.append(.init(
                nasRoot: row.nasRoot,
                oldPathKey: row.pathKey,
                newRelativePath: String(move.destination.dropFirst(row.nasRoot.count + 1))
            ))
        }
        return catalog
    }
}

extension LayoutMigrationDisk {
    /// `…/._NAME` → `…/NAME`.
    static func appleDoubleFile(of twin: String) -> String {
        let name = (twin as NSString).lastPathComponent
        return ((twin as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(name.hasPrefix("._") ? String(name.dropFirst(2)) : name)
    }
}
