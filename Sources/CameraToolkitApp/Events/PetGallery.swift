import CameraToolkitCore
import Foundation
import Observation

/// The pets side of the People window: the same review actions as people,
/// over the pet index (`pets.sqlite`, beside the catalog) instead of the
/// catalog. Every write lands in the pet index only — never in the
/// catalog, never on a photo.
///
/// Pet review actions are not in the Undo history yet; the destructive
/// ones (Remove a group, Clear Pet Scan) keep their confirmations, and
/// none of them can touch a file.
@MainActor
@Observable
final class PetGallery: FaceReviewGallery {
    /// The Settings switch: Scan for Faces also looks for dogs when the
    /// pet engine is installed.
    static let scanEnabledDefaultsKey = "pets.scanWithFaces"

    @ObservationIgnored let model: DashboardModel
    /// Test seam for the support folder the engine check reads.
    @ObservationIgnored var applicationSupport: URL = DashboardModel.defaultApplicationSupportURL

    var facesRevision = 0

    var gallerySubject: FaceGallerySubject { .pets }

    @ObservationIgnored private var storeInstance: (url: URL, store: FaceIndexStore)?
    @ObservationIgnored private var engineCheck: (at: ContinuousClock.Instant, installed: Bool)?

    init(model: DashboardModel) {
        self.model = model
    }

    /// Whether Settings asks face scans to look for dogs too.
    static func scanEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: scanEnabledDefaultsKey) as? Bool ?? true
    }

    /// `pets.sqlite` beside the configured catalog.
    var databaseURL: URL {
        PetIndexDatabase.url(besideCatalog: URL(
            fileURLWithPath: DashboardModel.expandedPath(model.configuration.catalogDatabasePath)
        ))
    }

    /// True once `scripts/setup-pet-sidecar.sh` finished on this Mac.
    /// Files on disk, so the answer is kept for a few seconds.
    var faceEngineInstalled: Bool {
        let now = ContinuousClock.now
        if let known = engineCheck, now - known.at < .seconds(5) { return known.installed }
        let installed = PetSidecarInstallation(applicationSupport: applicationSupport).isInstalled
        engineCheck = (now, installed)
        return installed
    }

    /// The pet index, opened (and migrated) on first use — or nil while no
    /// pet scan has created it, so browsing the Pets list never creates a
    /// file.
    func store() -> FaceIndexStore? {
        let url = databaseURL
        if let storeInstance, storeInstance.url == url { return storeInstance.store }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let store = try PetIndexDatabase.open(url: url)
            storeInstance = (url, store)
            return store
        } catch {
            model.statusMessage = "Could not open the pet index: \(error.localizedDescription)"
            return nil
        }
    }

    /// A pet scan just wrote the index: re-read everything.
    func noteScanFinished() {
        storeInstance = nil
        facesRevision &+= 1
    }

    // MARK: - Reads

    func faceSnapshot() -> (approved: [FacePerson], inbox: [FacePerson]) {
        guard let store = store() else { return ([], []) }
        let approved = (try? store.rosterPeople()) ?? []
        let groups = (try? store.otherGroups()) ?? []
        return (approved, FaceReviewOrder.inboxRows(groups))
    }

    func faceIndexCounts() -> FaceIndexCounts {
        (try? store()?.faceIndexCounts()) ?? FaceIndexCounts()
    }

    func storedFaceScanGrades() -> [FaceScanGrade] {
        (try? store()?.storedScanGrades()) ?? []
    }

    func faces(for personID: UUID) -> [FaceRecord] {
        (try? store()?.faces(personID: personID)) ?? []
    }

    func inboxFaces(for personID: UUID) -> [FaceRecord] {
        FaceReviewOrder.inbox(faces(for: personID))
    }

    func person(_ id: UUID) -> FacePerson? {
        (try? store()?.person(id)) ?? nil
    }

    func coverFace(personID: UUID) -> FaceRecord? {
        (try? store()?.coverFace(personID: personID)) ?? nil
    }

    // MARK: - Review actions (pet index only)

    /// Runs one review write and reports it; the window re-reads after.
    private func change(_ success: String?, failure: String, _ body: (FaceIndexStore) throws -> Void) {
        guard let store = store() else { return }
        do {
            try body(store)
            facesRevision &+= 1
            if let success { model.statusMessage = success }
        } catch {
            model.statusMessage = "\(failure): \(error.localizedDescription)"
        }
    }

    func renamePerson(_ personID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        change("Renamed to \(trimmed).", failure: "Could not rename") { store in
            try store.renamePerson(personID, name: trimmed)
        }
    }

    func mergePerson(_ sourceID: UUID, into targetID: UUID) {
        guard sourceID != targetID,
              let source = person(sourceID), let target = person(targetID) else { return }
        change("Merged \(source.name) into \(target.name).", failure: "Could not merge") { store in
            try store.mergePerson(sourceID, into: targetID)
            try store.refreshFaceCounts()
        }
    }

    func demotePerson(_ personID: UUID) {
        change("Moved to the Inbox — the confirmed detections stay grouped there.", failure: "Could not move to the Inbox") { store in
            try store.demoteFromRoster(personID)
        }
    }

    func nameGroup(_ personID: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        change("Approved \(trimmed) — only the dogs in this group were confirmed.", failure: "Could not approve") { store in
            try store.promoteGroup(personID, name: trimmed, templateCap: FaceScanOptions.pets().templateCap)
        }
    }

    func junkGroup(_ personID: UUID) {
        guard let person = person(personID) else { return }
        guard !person.isRoster else {
            model.statusMessage = "\(person.name) is an approved pet — only Inbox rows can be removed."
            return
        }
        change("Removed \(person.name) from the pet index. Nothing on disk was touched.", failure: "Could not remove the group") { store in
            try store.deletePersonAndFaces(personID)
        }
    }

    func junkFace(_ faceID: UUID) {
        change("Detection removed from the pet index. The photo was not touched.", failure: "Could not remove the detection") { store in
            try store.deleteFaces([faceID])
            try store.refreshFaceCounts()
        }
    }

    /// Same rule as people: a detection on a "looks like X" row is
    /// confirmed onto X itself; otherwise it is frozen where it is and
    /// pinned as a template.
    func confirmFace(_ faceID: UUID) {
        change(nil, failure: "Could not confirm") { store in
            guard let face = try store.face(id: faceID) else { return }
            if let personID = face.personID,
               let person = try store.person(personID),
               !person.isRoster,
               let target = person.suggestedPersonID {
                try store.assignFace(faceID, to: target, state: .confirmed, score: face.matchScore)
                try store.addTemplate(personID: target, faceID: faceID)
            } else {
                try store.confirmFace(faceID)
                if let personID = face.personID {
                    try store.addTemplate(personID: personID, faceID: faceID)
                }
            }
            try store.refreshFaceCounts()
        }
    }

    /// The preview's tag picker on a dog box: the detection is assigned to
    /// the pet and confirmed (frozen), and pinned as a match reference.
    func tagFace(_ faceID: UUID, as petID: UUID) {
        change("Tagged. The photo file was not modified.", failure: "Could not tag the dog") { store in
            try store.assignFace(faceID, to: petID, state: .confirmed, score: nil)
            try store.addTemplate(personID: petID, faceID: faceID)
            try store.refreshFaceCounts()
        }
    }

    /// "New Pet" in the preview's tag picker: an approved pet in the pet
    /// index. Nil while no pet scan has created the index — a dog box only
    /// exists once one has.
    func createPet(named name: String) -> FacePerson? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var created: FacePerson?
        change("Added \(trimmed) to the pets list.", failure: "Could not add the pet") { store in
            created = try store.createPerson(name: trimmed, isRoster: true)
        }
        return created
    }

    func rejectFace(_ faceID: UUID) {
        guard let face = try? store()?.face(id: faceID) else { return }
        guard face.state != .confirmed else {
            model.statusMessage = "Confirmed detections are frozen — this one stays where it is."
            return
        }
        change("Removed — it will not be matched back. The photo was not touched.", failure: "Could not remove the detection") { store in
            try FaceIndexService(store: store, options: .pets()).reject([faceID])
        }
    }

    func pinTemplate(_ faceID: UUID, for personID: UUID) {
        change("Pinned as a match reference for future pet scans.", failure: "Could not pin") { store in
            try store.addTemplate(personID: personID, faceID: faceID)
        }
    }

    func setCoverFace(_ faceID: UUID, for personID: UUID) {
        change("Cover updated.", failure: "Could not set the cover") { store in
            _ = try store.setCoverFace(personID: personID, faceID: faceID)
        }
    }

    /// Clear Pet Scan: every pet index row, nothing else — the catalog,
    /// the people, and every file stay as they are.
    func clearFaceIndex() {
        change(
            "Pet index cleared — pet rows only; the catalog and every file were not touched. The next pet scan will not skip those files.",
            failure: "Could not clear the pet index"
        ) { store in
            try store.clearFaceIndex()
        }
    }

    /// Re-match on stored pet vectors: no photo re-read, no ML, no file
    /// moved.
    func rematchFaces() {
        guard let store = store() else { return }
        let options = FaceScanOptions.pets()
        model.runAsyncJob(
            action: .faceScan,
            runningNote: "Re-matching and regrouping stored pets",
            logTitle: "Re-matched pets",
            logDetail: "Stored pet vectors were matched against the approved pets — matches filed into the Inbox as lookalikes — and the automatic dog groups were rebundled. No photos were re-read, no ML ran, and no files, events, or people changed.",
            operation: { _ in
                try FaceIndexService(store: store, options: options).rematchRoster()
            },
            completion: { [weak self] report in
                self?.facesRevision &+= 1
                return "Pet re-match done — \(report.facesProposed) filed as lookalikes, \(report.facesGrouped) grouped, \(report.facesMoved) moved."
            }
        )
    }
}
