import Foundation

/// The dogs on one photo, read from the pet index for the organizer's
/// full-size preview: the detections to box, the names their chips wear,
/// and the approved pets the tag picker lists.
public struct PetFrameBoxes: Equatable, Sendable {
    public var faces: [FaceRecord]
    /// Pet id → the name its chip shows. A "looks like" group wears its
    /// target's live name, the same rule the face boxes follow.
    public var names: [UUID: String]
    /// Approved pets, for the tag picker.
    public var approvedPets: [FacePerson]

    public init(faces: [FaceRecord] = [], names: [UUID: String] = [:], approvedPets: [FacePerson] = []) {
        self.faces = faces
        self.names = names
        self.approvedPets = approvedPets
    }

    public static let empty = PetFrameBoxes()
}

/// Reads a photo's pet detections from `pets.sqlite` by file identity
/// (name + size + modified second), the key the pet scan stores rows
/// under, so boxes survive the file moving into an event folder.
///
/// A read only: it never creates, migrates, or writes the pet index, and
/// never touches the catalog. A missing, empty, or unreadable file yields
/// `.empty`. Blocking SQLite I/O — call it off the main actor.
public enum PetFrameLookup {
    public static func boxes(petIndexURL: URL, file: OrganizeFile) -> PetFrameBoxes {
        // A missing or zero-byte file has no dogs — and opening one would
        // write a SQLite header into it, so it is never opened.
        guard let size = (try? FileManager.default.attributesOfItem(atPath: petIndexURL.path))?[.size] as? NSNumber,
              size.int64Value > 0 else { return .empty }
        let store = FaceIndexStore(url: petIndexURL, engine: PetFaceEngine.identifier)
        guard (try? store.faceSchemaExists()) == true else { return .empty }
        let faces = (try? store.faces(
            fileName: file.name,
            byteCount: file.size,
            modifiedAt: file.modifiedAt,
            preferredPathKey: file.pathKey
        )) ?? []
        var names: [UUID: String] = [:]
        for id in Set(faces.compactMap(\.personID)) {
            if let pet = (try? store.person(id)) ?? nil {
                names[id] = pet.suggestedPersonName ?? pet.name
            }
        }
        let approved = faces.isEmpty ? [] : ((try? store.rosterPeople()) ?? [])
        return PetFrameBoxes(faces: faces, names: names, approvedPets: approved)
    }
}
