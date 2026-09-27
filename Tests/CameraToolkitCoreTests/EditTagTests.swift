import CameraToolkitCore
import Foundation
import XCTest

final class EditTagTests: XCTestCase {
    func testStemsMatchOriginalsAcrossExtensionsSuffixesAndBurstPrefixes() {
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778.ARW"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778.jpg"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778-edit.jpg"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778_Edited.tif"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778-Edit-2.jpg"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778 copy.heic"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778 (2).ARW"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "B0012_DSC06778.ARW"), "dsc06778")
        XCTAssertEqual(EditTagLinker.stem(of: "DSC06778.ARW.xmp"), "dsc06778")
        // Not an edit suffix: kept.
        XCTAssertEqual(EditTagLinker.stem(of: "Beach-2.jpg"), "beach-2")
        XCTAssertEqual(EditTagLinker.stem(of: "edit.jpg"), "edit")
    }

    func testEditedFilesAreTaggedByTheirFirstFolderAndLinkByStemThenByMoment() throws {
        try withTemporaryDirectory { root in
            let event = root.appendingPathComponent("2026-08-23 Trip", isDirectory: true)
            try writeFile(event.appendingPathComponent("Edited/Photomator/DSC06778.jpg"), "a")
            try writeFile(event.appendingPathComponent("Edited/Photomator/._DSC06778.jpg"), "twin")
            try writeFile(event.appendingPathComponent("Edited/Masters/Web/DSC06778-edit.jpg"), "b")
            try writeFile(event.appendingPathComponent("Edited/Masters/renamed-by-hand.jpg"), "c")
            try writeFile(event.appendingPathComponent("Edited/loose.jpg"), "d")
            try writeFile(event.appendingPathComponent("Edited/.DS_Store"), "junk")
            try writeFile(event.appendingPathComponent("Edited/Social/nothing-matches.jpg"), "e")

            let edits = EditTagLinker.editedFiles(eventFolders: [event, event])
            XCTAssertEqual(Set(edits.map { "\($0.tag):\($0.name)" }), [
                "Photomator:DSC06778.jpg",
                "Masters:DSC06778-edit.jpg",
                "Masters:renamed-by-hand.jpg",
                "Edited:loose.jpg",
                "Social:nothing-matches.jpg",
            ])

            let moment = Date(timeIntervalSince1970: 1_788_000_000)
            let candidates = [
                EditTagCandidate(itemID: "raw", fileNames: ["DSC06778.ARW", "DSC06778.ARW.xmp"], captureDate: moment, cameraID: "sony-a7v"),
                EditTagCandidate(itemID: "other", fileNames: ["DSC06779.ARW"], captureDate: moment.addingTimeInterval(1), cameraID: "sony-a7v"),
                EditTagCandidate(itemID: "loose", fileNames: ["LOOSE.ARW"], captureDate: nil, cameraID: nil),
            ]
            let index = EditTagLinker.link(edits: edits, candidates: candidates) { edit in
                // The hand-renamed export still carries the camera's time.
                edit.name == "renamed-by-hand.jpg" ? (moment.addingTimeInterval(1.4), "sony-a7v") : (nil, nil)
            }
            XCTAssertEqual(index.tags(forItemID: "raw"), ["Photomator", "Masters"])
            XCTAssertEqual(index.tags(forItemID: "other"), ["Masters"])
            XCTAssertEqual(index.tags(forItemID: "loose"), ["Edited"])
            XCTAssertEqual(index.unlinked.map(\.name), ["nothing-matches.jpg"])
            XCTAssertEqual(index.allTags, ["Edited", "Masters", "Photomator"])
            XCTAssertEqual(index.editCount, 5)
        }
    }
}
