import Foundation

/// One graded copy standing in for its log original in an event's album.
public struct ImmichGradedSwap: Equatable, Sendable {
    public var eventID: UUID
    public var album: ImmichAlbumTarget
    /// Nil when the original is not in Immich.
    public var originalAssetID: String?
    public var gradedAssetID: String

    public init(eventID: UUID, album: ImmichAlbumTarget, originalAssetID: String?, gradedAssetID: String) {
        self.eventID = eventID
        self.album = album
        self.originalAssetID = originalAssetID
        self.gradedAssetID = gradedAssetID
    }
}

/// What a check did with the events' graded copies.
public struct ImmichGradedSwapReport: Equatable, Sendable {
    /// Copies listed by Immich, each put in its original's place in the album.
    public var swaps: [ImmichGradedSwap] = []
    /// Copies on the NAS that Immich does not list yet (paths under the NAS
    /// root): the next check adds them.
    public var waitingForScan: [String] = []
    public var waitingByEvent: [UUID: Int] = [:]
    /// Copies still only on the drive: Sync to NAS carries them first.
    public var notOnNASByEvent: [UUID: Int] = [:]
    /// Originals taken out of their album (the app had put them there).
    public var removedOriginals = 0

    public init() {}

    public var swapsByEvent: [UUID: Int] {
        swaps.reduce(into: [:]) { $0[$1.eventID, default: 0] += 1 }
    }
}

/// One removal from an album, as logged: add the assets back to undo it.
public struct ImmichAlbumRemovalEntry: Codable, Equatable, Sendable {
    public var at: Date
    public var albumID: String
    public var albumName: String
    public var assetIDs: [String]
    /// The graded copies that took their place.
    public var replacedBy: [String]

    public init(at: Date = Date(), albumID: String, albumName: String, assetIDs: [String], replacedBy: [String]) {
        self.at = at
        self.albumID = albumID
        self.albumName = albumName
        self.assetIDs = assetIDs
        self.replacedBy = replacedBy
    }
}

/// Graded copies in albums: a log clip's Rec.709 copy (`Edited/Rec709`, made
/// by the app and written down in `GradedCopyStore`) goes into the event's
/// album in place of the flat original. The original leaves the album only
/// when the app itself put it there (its album-additions log says so), and
/// only once; an original someone added by hand stays. Album membership is
/// all that changes: no asset or file is ever deleted. Stacking (graded copy
/// on top) is the stack runner's edit rule.
public enum ImmichGradedAlbumSwap {
    public static let additionsLogName = "album-additions.jsonl"
    public static let removalsLogName = "album-removals.jsonl"

    /// Puts each listed graded copy in its original's place in the albums
    /// the check is about to fill, so the original is not added (or added
    /// back) and the copy is. Copies Immich does not list yet leave the
    /// original where it is and are reported as waiting.
    public static func prepare(
        _ report: inout ImmichReconcileReport,
        files: [ImmichCatalogFile],
        assets: [ImmichLibraryAsset],
        library: ImmichLibrary,
        records: [GradedCopyRecord]
    ) -> ImmichGradedSwapReport {
        var result = ImmichGradedSwapReport()
        guard !records.isEmpty else { return result }
        let paths = ImmichLibraryPaths(importPaths: library.importPaths)
        var assetByKey: [String: String] = [:]
        for asset in assets where !asset.isOffline && !asset.isTrashed {
            guard let relative = paths.relativePath(forOriginalPath: asset.originalPath) else { continue }
            assetByKey[NASSyncStore.pathKey(relative)] = asset.id
        }
        let fileByKey = Dictionary(files.map { (NASSyncStore.pathKey($0.relativePath), $0) }) { first, _ in first }
        // The newest copy of each original speaks for it.
        var newest: [String: GradedCopyRecord] = [:]
        for record in records {
            if let current = newest[record.originalKey], current.recordedAt >= record.recordedAt { continue }
            newest[record.originalKey] = record
        }
        for key in newest.keys.sorted() {
            guard let record = newest[key], let file = fileByKey[key], let eventID = file.eventID else { continue }
            guard let gradedID = assetByKey[record.gradedKey] else {
                if record.isOnNAS {
                    result.waitingForScan.append(record.gradedRelativePath)
                    result.waitingByEvent[eventID, default: 0] += 1
                } else {
                    result.notOnNASByEvent[eventID, default: 0] += 1
                }
                continue
            }
            guard let album = file.album else { continue }
            let originalID = assetByKey[key]
            var wanted = report.albumAssets[album] ?? []
            wanted.removeAll { $0 == originalID }
            if !wanted.contains(gradedID) { wanted.append(gradedID) }
            report.albumAssets[album] = wanted
            report.albumEvents[album, default: []].insert(eventID)
            var mine = report.eventAlbumAssets[eventID] ?? []
            mine.removeAll { $0 == originalID }
            if !mine.contains(gradedID) { mine.append(gradedID) }
            report.eventAlbumAssets[eventID] = mine
            result.swaps.append(ImmichGradedSwap(eventID: eventID, album: album, originalAssetID: originalID, gradedAssetID: gradedID))
        }
        return result
    }

    /// Per album, the originals to take out: in the album now, beside their
    /// graded copy (which must be in the album too), put there by the app,
    /// and never taken out by the app before.
    public static func originalsToRemove(
        swaps: [ImmichGradedSwap],
        albumIDs: [UUID: String],
        members: [String: Set<String>],
        appAdded: [String: Set<String>],
        alreadyRemoved: [String: Set<String>]
    ) -> [String: [(original: String, graded: String)]] {
        var result: [String: [(original: String, graded: String)]] = [:]
        for swap in swaps {
            guard let original = swap.originalAssetID, let albumID = albumIDs[swap.eventID],
                  let inAlbum = members[albumID], inAlbum.contains(original), inAlbum.contains(swap.gradedAssetID),
                  appAdded[albumID]?.contains(original) == true,
                  alreadyRemoved[albumID]?.contains(original) != true,
                  result[albumID]?.contains(where: { $0.original == original }) != true else { continue }
            result[albumID, default: []].append((original, swap.gradedAssetID))
        }
        return result
    }

    /// Album → assets, from an additions or removals log (JSON lines).
    public static func loggedAssets(in url: URL?) -> [String: Set<String>] {
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        struct Line: Decodable {
            var albumID: String
            var assetIDs: [String]
        }
        let decoder = JSONDecoder()
        var result: [String: Set<String>] = [:]
        for line in text.split(separator: "\n") {
            guard let entry = try? decoder.decode(Line.self, from: Data(line.utf8)) else { continue }
            result[entry.albumID, default: []].formUnion(entry.assetIDs)
        }
        return result
    }

    /// Takes the originals the app had added out of the albums their graded
    /// copies are now in, and logs each removal. Runs after the albums were
    /// filled; without a log folder nothing is taken out (whether the app
    /// added an original cannot be told).
    public static func removeReplacedOriginals(
        client: ImmichClient,
        into outcome: inout ImmichLibrarySyncOutcome,
        logFolder: URL?
    ) async {
        let swaps = outcome.graded.swaps.filter { $0.originalAssetID != nil }
        guard let logFolder, !swaps.isEmpty else { return }
        let appAdded = loggedAssets(in: logFolder.appendingPathComponent(additionsLogName))
        let removed = loggedAssets(in: logFolder.appendingPathComponent(removalsLogName))
        var albumIDs: [UUID: String] = [:]
        var names: [String: String] = [:]
        for swap in swaps {
            guard let album = outcome.resolvedAlbums[swap.eventID] else { continue }
            albumIDs[swap.eventID] = album.id
            names[album.id] = album.name
        }
        // Only albums where the app added one of these originals are read.
        let candidates = Set(swaps.compactMap { swap -> String? in
            guard let id = albumIDs[swap.eventID], let original = swap.originalAssetID,
                  appAdded[id]?.contains(original) == true, removed[id]?.contains(original) != true else { return nil }
            return id
        })
        var members: [String: Set<String>] = [:]
        for albumID in candidates.sorted() {
            do {
                members[albumID] = Set(try await client.albumAssets(albumID: albumID).map(\.id))
            } catch {
                outcome.problems.append("album \(names[albumID] ?? albumID): \(error.localizedDescription)")
            }
        }
        let plan = originalsToRemove(swaps: swaps, albumIDs: albumIDs, members: members, appAdded: appAdded, alreadyRemoved: removed)
        for albumID in plan.keys.sorted() {
            let pairs = plan[albumID] ?? []
            do {
                let left = try await client.removeAssets(pairs.map(\.original), fromAlbum: albumID)
                guard !left.isEmpty else { continue }
                outcome.graded.removedOriginals += left.count
                let replaced = pairs.filter { left.contains($0.original) }.map(\.graded)
                ImmichChangeLog.append(
                    ImmichAlbumRemovalEntry(albumID: albumID, albumName: names[albumID] ?? "", assetIDs: left, replacedBy: replaced),
                    to: logFolder.appendingPathComponent(removalsLogName)
                )
            } catch {
                outcome.problems.append("album \(names[albumID] ?? albumID): originals not taken out (\(error.localizedDescription))")
            }
        }
    }
}

extension ImmichLibrarySyncOutcome {
    /// True while a catalog file or a graded copy on the NAS is not listed
    /// by Immich yet: another look is worth it.
    public var waitsForScan: Bool {
        report.count(.pendingScan) > 0 || !graded.waitingForScan.isEmpty
    }
}
