import Foundation
import XCTest
@testable import CameraToolkitApp

final class USBLinkProbeTests: XCTestCase {
    func testParsesRelevantUSBStorageLinksWithoutExposingSerialNumbers() throws {
        let fixture: [[String: Any]] = [
            [
                "USB Product Name": "Osmo360_SN:ABC123",
                "USB Vendor Name": "DJI",
                "USB Serial Number": "private-serial",
                "UsbLinkSpeed": 480_000_000
            ],
            [
                "children": [[
                    "USB Product Name": "USB Mass Storage",
                    "USB Vendor Name": "JMicron",
                    "UsbLinkSpeed": 10_000_000_000
                ]]
            ],
            [
                "USB Product Name": "USB Keyboard",
                "USB Vendor Name": "Example",
                "UsbLinkSpeed": 480_000_000
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: fixture,
            format: .xml,
            options: 0
        )

        let links = USBLinkProbe.parsePropertyList(data)

        XCTAssertEqual(links.map(\.name), ["USB Mass Storage (JMicron)", "DJI Osmo 360"])
        XCTAssertEqual(links.map(\.bitsPerSecond), [10_000_000_000, 480_000_000])
        XCTAssertFalse(links.map(\.name).joined().contains("private-serial"))
    }

    func testFormatsNegotiatedLinkNamesAndByteCeilings() {
        let usb2 = USBLinkSnapshot(name: "Camera", bitsPerSecond: 480_000_000)
        let usb10 = USBLinkSnapshot(name: "Enclosure", bitsPerSecond: 10_000_000_000)

        XCTAssertEqual(usb2.interfaceName, "USB 2.0")
        XCTAssertEqual(usb2.formattedLinkRate, "480 Mb/s")
        XCTAssertEqual(usb2.theoreticalMegabytesPerSecond, 60)
        XCTAssertEqual(usb10.interfaceName, "USB 3.2 Gen 2")
        XCTAssertEqual(usb10.formattedLinkRate, "10 Gb/s")
        XCTAssertEqual(usb10.theoreticalMegabytesPerSecond, 1_250)
    }
}
