import CameraToolkitCore
import Foundation

/// Who a review gallery holds — the People window shows either, with the
/// same rows, grids, and review actions, and only the words differ.
enum FaceGallerySubject: String, CaseIterable, Identifiable, Sendable {
    case people
    case pets

    var id: String { rawValue }

    var title: String {
        switch self {
        case .people: "People"
        case .pets: "Pets"
        }
    }

    var searchPrompt: String {
        switch self {
        case .people: "Search people"
        case .pets: "Search pets"
        }
    }

    var emptyTitle: String {
        switch self {
        case .people: "No People Yet"
        case .pets: "No Pets Yet"
        }
    }

    var emptyDescription: String {
        switch self {
        case .people:
            "Run a face scan on an Unsorted folder — the clusters and lookalikes it finds land in the Inbox."
        case .pets:
            "With Look for dogs on in Settings › Organizing, Scan for Faces also finds dogs — their groups land in the Inbox here."
        }
    }

    var emptySymbol: String {
        switch self {
        case .people: "person.crop.rectangle.stack"
        case .pets: "pawprint"
        }
    }

    /// The placeholder a row shows before its cover crop loads.
    var placeholderSymbol: String {
        switch self {
        case .people: "person.crop.square"
        case .pets: "pawprint"
        }
    }

    var setupCommand: String {
        switch self {
        case .people: FaceSidecarInstallation.setupCommand
        case .pets: PetSidecarInstallation.setupCommand
        }
    }

    var engineName: String {
        switch self {
        case .people: "Face engine"
        case .pets: "Pet engine"
        }
    }

    /// The footer's scope note — scans only read photos.
    var readOnlyNote: String {
        switch self {
        case .people: "faces only read photos; nothing is written to media"
        case .pets: "pet scans only read photos; nothing is written to media"
        }
    }

    var clearTitle: String {
        switch self {
        case .people: "Clear Face Scan"
        case .pets: "Clear Pet Scan"
        }
    }

    /// Where the Clear sheet says the index lives.
    var indexLocation: String {
        switch self {
        case .people: "the local catalog"
        case .pets: "the pet index (\(PetIndexDatabase.fileName), beside the catalog)"
        }
    }

    var nounSingular: String {
        switch self {
        case .people: "person"
        case .pets: "pet"
        }
    }

    var nounPlural: String {
        switch self {
        case .people: "people"
        case .pets: "pets"
        }
    }

    var detectionNoun: String {
        switch self {
        case .people: "face"
        case .pets: "dog"
        }
    }

    var namePrompt: String {
        switch self {
        case .people: "Who is this?"
        case .pets: "Which pet is this?"
        }
    }
}

/// Everything the People window reads and does. `EventsWorkspace` serves
/// people from the catalog; `PetGallery` serves pets from the pet index.
/// The window never knows which store it is talking to.
@MainActor
protocol FaceReviewGallery: AnyObject {
    var gallerySubject: FaceGallerySubject { get }
    /// Bumped on every change the window must re-read.
    var facesRevision: Int { get }
    var faceEngineInstalled: Bool { get }

    func faceSnapshot() -> (approved: [FacePerson], inbox: [FacePerson])
    func faceIndexCounts() -> FaceIndexCounts
    func storedFaceScanGrades() -> [FaceScanGrade]
    func clearFaceIndex()
    func faces(for personID: UUID) -> [FaceRecord]
    func inboxFaces(for personID: UUID) -> [FaceRecord]
    func person(_ id: UUID) -> FacePerson?
    func coverFace(personID: UUID) -> FaceRecord?

    func renamePerson(_ personID: UUID, name: String)
    func mergePerson(_ sourceID: UUID, into targetID: UUID)
    func demotePerson(_ personID: UUID)
    func nameGroup(_ personID: UUID, name: String)
    func junkGroup(_ personID: UUID)
    func junkFace(_ faceID: UUID)
    func confirmFace(_ faceID: UUID)
    func rejectFace(_ faceID: UUID)
    func pinTemplate(_ faceID: UUID, for personID: UUID)
    func setCoverFace(_ faceID: UUID, for personID: UUID)
    func rematchFaces()
}

extension EventsWorkspace: FaceReviewGallery {
    var gallerySubject: FaceGallerySubject { .people }

    func coverFace(personID: UUID) -> FaceRecord? {
        (try? faceStore.coverFace(personID: personID)) ?? nil
    }
}

/// Inbox review order, shared by both galleries: the stored match score,
/// strongest first; a face with no score is a cluster seed and sorts with
/// the strongest.
enum FaceReviewOrder {
    static func inbox(_ faces: [FaceRecord]) -> [FaceRecord] {
        faces.sorted { lhs, rhs in
            let left = lhs.matchScore ?? .infinity
            let right = rhs.matchScore ?? .infinity
            if left != right { return left > right }
            if lhs.detScore != rhs.detScore { return lhs.detScore > rhs.detScore }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// "Looks like" rows first — the closest to an approval — then plain
    /// clusters, largest first.
    static func inboxRows(_ groups: [FacePerson]) -> [FacePerson] {
        groups.sorted { lhs, rhs in
            if (lhs.suggestedPersonID != nil) != (rhs.suggestedPersonID != nil) {
                return lhs.suggestedPersonID != nil
            }
            if lhs.faceCount != rhs.faceCount { return lhs.faceCount > rhs.faceCount }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

/// What one Scan for Faces job did: the face pass, and the dog pass when
/// Settings asked for it.
struct FaceAndPetScanReport: Sendable {
    var faces: FaceScanReport
    var pets: FaceScanReport?
    /// Why the dog pass stopped, when it failed after the face pass was
    /// already stored.
    var petError: String?

    init(faces: FaceScanReport, pets: FaceScanReport? = nil, petError: String? = nil) {
        self.faces = faces
        self.pets = pets
        self.petError = petError
    }

    /// The sentence the job summary appends; empty when dogs were not
    /// scanned.
    var petSummary: String {
        if let petError {
            return " Dog scan did not finish: \(petError) Faces above are stored."
        }
        guard let pets else { return "" }
        let dogs = "\(pets.facesDetected) dog\(pets.facesDetected == 1 ? "" : "s")"
        return " Dogs: \(dogs) on \(pets.photosProcessed) photo(s), \(pets.photosSkipped) already scanned; \(pets.facesProposed) filed as lookalikes, \(pets.facesGrouped) grouped."
    }
}
