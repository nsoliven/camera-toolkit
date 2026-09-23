import CameraToolkitCore
@testable import CameraToolkitApp
import XCTest

final class CatalogResultRowTests: XCTestCase {
    func testRowsKeepQueryOrderAndPositionIdentity() {
        let result = CatalogQueryResult(columns: ["id", "name"], rows: [["1", "Beach"], ["2", "Birthday"]])
        let rows = CatalogResultRow.rows(from: result)
        XCTAssertEqual(rows.map(\.id), [0, 1])
        XCTAssertEqual(rows[1].value(at: 1), "Birthday")
    }

    func testShortRowsReadAsEmptyCells() {
        let row = CatalogResultRow(id: 0, values: ["only"])
        XCTAssertEqual(row.value(at: 0), "only")
        XCTAssertEqual(row.value(at: 3), "")
    }
}
