import AVFoundation
import Foundation

/// Graded copies made before the exporter stamped capture times into the
/// movie, track and media headers (and wrote the camera's UTC offset with
/// the `creationdate` tag) say the render time there, and a UTC time with no
/// offset in the tag. Immich takes the tag's instant (right) but shows it in
/// UTC, so such a copy can sit on the next day in its timeline.
///
/// The repair rewrites only the app's own copies (a `_709` name in an
/// `Edited/Rec709` folder, carrying the app's source tag of a catalog
/// original). Each is copied sample for sample, with no re-encode, into a
/// partial in the folder's temporary folder with the corrected tags, stamped,
/// checked, given the copy's own modification time, and only then renamed
/// over the copy, after checking the copy is still the same file. Originals
/// are only read.
public enum GradedCopyDateRepair {
    public struct Found: Equatable, Sendable {
        public var copy: URL
        public var eventID: UUID
        public var original: URL
        /// Paths under the NAS root (the paths Immich lists them by).
        public var originalRelativePath: String
        public var gradedRelativePath: String
        public var sourceKey: String
        public var moment: GradedVideoExporter.CaptureMoment
        public var isOnNAS: Bool
        public var needsRepair: Bool
    }

    /// Every graded copy in these events' `Edited/Rec709` folders, on the
    /// NAS and on the drive, matched to its catalog original by the source
    /// tag it carries. Only reads.
    public static func survey(
        events: [SavedCameraEvent],
        allEvents: [SavedCameraEvent],
        assignments: [PhotoEventAssignment],
        locations: EventStorageLocations,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [Found] {
        let byID = Dictionary(allEvents.map { ($0.id, $0) }) { first, _ in first }
        var originals: [String: (PhotoEventAssignment, SavedCameraEvent)] = [:]
        for assignment in assignments {
            guard let event = byID[assignment.eventID] else { continue }
            let key = FaceIndexStore.fileKey(fileName: (assignment.relativePath as NSString).lastPathComponent, byteCount: assignment.fileSize, modifiedAt: assignment.modifiedAt)
            if originals[key] == nil { originals[key] = (assignment, event) }
        }
        var found: [Found] = []
        var seen = Set<String>()
        for event in events {
            let policy = locations.resolvedPolicy(for: event)
            let folders = [locations.nasEditedRoot(for: event), locations.editedRoot(for: event, policy: policy)]
                .map { GradedRenderNaming.outputFolder(editedRoot: $0) }
            for folder in folders {
                guard let entries = try? DirectoryListing.list(folder.path) else { continue }
                for entry in entries where entry.kind == .file {
                    let copy = folder.appendingPathComponent(entry.name)
                    guard GradedRenderNaming.isGradedCopy(copy), !GradedRenderNaming.isPartialName(entry.name),
                          seen.insert(copy.standardizedFileURL.path).inserted,
                          let source = GradedVideoExporter.readTags(copy)?.source,
                          let (assignment, owner) = originals[source] else { continue }
                    let nasOriginal = locations.archiveURL(for: assignment, event: owner)
                    let driveOriginal = locations.driveURL(for: assignment, event: owner, policy: locations.resolvedPolicy(for: owner))
                    guard let original = [nasOriginal, driveOriginal].compactMap({ $0 }).first(where: exists),
                          let originalRelative = locations.archiveRelativePath(for: assignment, event: owner) else { continue }
                    let path = copy.standardizedFileURL.path
                    let nasRelative = locations.nasRelativePath(path)
                    guard let gradedRelative = nasRelative ?? locations.mirrorRelativePath(forDrivePath: path) else { continue }
                    let moment = GradedVideoExporter.captureMoment(of: original, fallback: assignment.modifiedAt)
                    found.append(Found(
                        copy: copy, eventID: owner.id, original: original,
                        originalRelativePath: originalRelative, gradedRelativePath: gradedRelative,
                        sourceKey: source, moment: moment, isOnNAS: nasRelative != nil,
                        needsRepair: needsRepair(copy, moment: moment)
                    ))
                }
            }
        }
        return found
    }

    /// True when a header date is not the capture time, or the tag does not
    /// say the capture time the way the exporter writes it now.
    public static func needsRepair(_ copy: URL, moment: GradedVideoExporter.CaptureMoment) -> Bool {
        guard let headers = try? QuickTimeHeaderDates.read(copy), !headers.isEmpty else { return true }
        let capture = moment.date.timeIntervalSince1970.rounded(.down)
        if headers.contains(where: { abs($0.timeIntervalSince1970 - capture) > 1 }) { return true }
        return creationTag(copy) != GradedVideoExporter.creationDateString(moment)
    }

    static func creationTag(_ url: URL) -> String? {
        try? GradedVideoExporter.blocking {
            for item in try await AVURLAsset(url: url).loadMetadata(for: .quickTimeMetadata) where item.identifier == .quickTimeMetadataCreationDate {
                return try await item.load(.stringValue)
            }
            return nil
        }
    }

    /// Rewrites one copy as described above. Throws, leaving the copy as it
    /// was, when anything does not check out.
    public static func repair(_ found: Found) throws {
        let copy = found.copy
        guard let before = LayoutMigrationDisk.lstatEntry(copy.path), before.kind == .file else {
            throw ToolkitError.commandFailed("\(copy.lastPathComponent) is not there any more.")
        }
        let folder = copy.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(GradedRenderNaming.temporaryFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let partial = temporary.appendingPathComponent(GradedRenderNaming.partialName())
        defer {
            if DriveMoveService.exists(partial.path) { _ = unlink(partial.path) }
            if let entries = try? DirectoryListing.list(temporary.path) {
                for entry in entries where entry.kind == .file && entry.name.hasPrefix(partial.lastPathComponent + ".sb-") {
                    _ = unlink(temporary.appendingPathComponent(entry.name).path)
                }
            }
            _ = rmdir(temporary.path)
        }
        try remux(copy, to: partial, moment: found.moment)
        try QuickTimeHeaderDates.stamp(partial, date: found.moment.date)
        try GradedVideoExporter().verify(partial, against: copy)
        guard GradedVideoExporter.readTags(partial)?.source == found.sourceKey else {
            throw ToolkitError.commandFailed("The rewritten \(copy.lastPathComponent) lost its tags; the copy was left as it was.")
        }
        try FileManager.default.setAttributes([.modificationDate: before.modifiedDate, .creationDate: before.modifiedDate], ofItemAtPath: partial.path)
        // Still the same file, and still the app's copy of that original.
        guard let now = LayoutMigrationDisk.lstatEntry(copy.path), now.kind == .file, now.size == before.size,
              abs(now.modifiedAt - before.modifiedAt) < 1,
              GradedVideoExporter.readTags(copy)?.source == found.sourceKey else {
            throw ToolkitError.commandFailed("\(copy.lastPathComponent) changed while it was rewritten; it was left as it was.")
        }
        guard rename(partial.path, copy.path) == 0 else {
            throw ToolkitError.commandFailed("Could not put the rewritten \(copy.lastPathComponent) in place: \(String(cString: strerror(errno))).")
        }
    }

    /// Every track copied sample for sample (no re-encode), with the copy's
    /// own tags except the dates and location, which come from `moment`.
    static func remux(_ source: URL, to url: URL, moment: GradedVideoExporter.CaptureMoment) throws {
        let asset = AVURLAsset(url: source)
        struct Loaded: @unchecked Sendable {
            var tracks: [(AVAssetTrack, CMFormatDescription?)]
            var metadata: [AVMetadataItem]
        }
        let loaded = try GradedVideoExporter.blocking { () -> Loaded in
            var tracks: [(AVAssetTrack, CMFormatDescription?)] = []
            for track in try await asset.load(.tracks) {
                tracks.append((track, try await track.load(.formatDescriptions).first))
            }
            var metadata: [AVMetadataItem] = []
            let replaced: Set<AVMetadataIdentifier> = [
                .quickTimeMetadataCreationDate, .quickTimeUserDataCreationDate,
                .quickTimeMetadataLocationISO6709, .quickTimeUserDataLocationISO6709,
            ]
            for format in [AVMetadataFormat.quickTimeMetadata, .quickTimeUserData] {
                for item in (try? await asset.loadMetadata(for: format)) ?? [] where !(item.identifier.map(replaced.contains) ?? false) {
                    metadata.append(item)
                }
            }
            return Loaded(tracks: tracks, metadata: metadata)
        }
        func text(_ identifier: AVMetadataIdentifier, _ value: String) -> AVMetadataItem {
            let item = AVMutableMetadataItem()
            item.identifier = identifier
            item.value = value as NSString
            item.dataType = kCMMetadataBaseDataType_UTF8 as String
            return item
        }
        let created = GradedVideoExporter.creationDateString(moment)
        var metadata = loaded.metadata + [text(.quickTimeMetadataCreationDate, created), text(.quickTimeUserDataCreationDate, created)]
        if let location = moment.location {
            metadata += [text(.quickTimeMetadataLocationISO6709, location), text(.quickTimeUserDataLocationISO6709, location)]
        }

        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = true
        writer.metadata = metadata
        var pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for (track, hint) in loaded.tracks where track.mediaType == .video || track.mediaType == .audio {
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = track.preferredTransform }
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw ToolkitError.commandFailed("Could not copy a track of \(source.lastPathComponent).")
            }
            reader.add(output)
            writer.add(input)
            pairs.append((output, input))
        }
        guard reader.startReading(), writer.startWriting() else {
            reader.cancelReading()
            throw ToolkitError.commandFailed("Could not start copying \(source.lastPathComponent): \((reader.error ?? writer.error)?.localizedDescription ?? "unknown error").")
        }
        writer.startSession(atSourceTime: .zero)
        final class Parts: @unchecked Sendable {
            let pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)]
            init(_ pairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)]) { self.pairs = pairs }
        }
        let parts = Parts(pairs)
        let group = DispatchGroup()
        for index in parts.pairs.indices {
            group.enter()
            let (output, input) = parts.pairs[index]
            input.requestMediaDataWhenReady(on: DispatchQueue(label: "CameraToolkit.GradedCopyDateRepair.\(index)")) {
                while input.isReadyForMoreMediaData {
                    guard let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                        input.markAsFinished()
                        group.leave()
                        return
                    }
                }
            }
        }
        group.wait()
        if reader.status == .failed {
            writer.cancelWriting()
            throw ToolkitError.commandFailed("Reading \(source.lastPathComponent) failed: \(reader.error?.localizedDescription ?? "unknown error").")
        }
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else {
            throw ToolkitError.commandFailed("Writing the rewritten copy failed: \(writer.error?.localizedDescription ?? "unknown error").")
        }
    }
}
