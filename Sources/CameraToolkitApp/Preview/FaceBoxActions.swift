import CameraToolkitCore
import Foundation

/// Where a preview box's confirm and tag actions write: the catalog for
/// people (`EventsWorkspace`), the pet index for dogs (`PetGallery`).
@MainActor
protocol FaceBoxTagTarget: AnyObject {
    func confirmFace(_ faceID: UUID)
    func tagFace(_ faceID: UUID, as personID: UUID)
    /// "New Person" / "New Pet" in the tag picker.
    func createTaggable(named name: String) -> FacePerson?
}

extension EventsWorkspace: FaceBoxTagTarget {
    func createTaggable(named name: String) -> FacePerson? {
        createRosterPerson(named: name)
    }
}

extension PetGallery: FaceBoxTagTarget {
    func createTaggable(named name: String) -> FacePerson? {
        createPet(named: name)
    }
}

/// Routes a preview box's action by what the box holds: a face only ever
/// reaches the catalog, a dog only ever reaches the pet index. The two
/// indexes have their own ids, so a mixed-up route would write the wrong
/// file — this is the one place that decides.
@MainActor
struct FaceBoxActionRouter {
    let people: any FaceBoxTagTarget
    let pets: any FaceBoxTagTarget

    func target(for subject: FaceGallerySubject) -> any FaceBoxTagTarget {
        switch subject {
        case .people: people
        case .pets: pets
        }
    }

    func confirm(_ faceID: UUID, subject: FaceGallerySubject) {
        target(for: subject).confirmFace(faceID)
    }

    func tag(_ faceID: UUID, as personID: UUID, subject: FaceGallerySubject) {
        target(for: subject).tagFace(faceID, as: personID)
    }

    func create(named name: String, subject: FaceGallerySubject) -> FacePerson? {
        target(for: subject).createTaggable(named: name)
    }
}
