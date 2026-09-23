import Foundation
import XCTest
@testable import CameraToolkitApp

final class StorageLinkInspectorTests: XCTestCase {
    func testMountHostParsingHandlesUserInfoAndPlainHosts() {
        XCTAssertEqual(
            StorageLinkInspector.parseMountHost("//nasuser@192.0.2.2/nas_share"),
            "192.0.2.2"
        )
        XCTAssertEqual(
            StorageLinkInspector.parseMountHost("//nas.local/photos"),
            "nas.local"
        )
        XCTAssertNil(StorageLinkInspector.parseMountHost("/dev/disk8s2"))
    }

    func testRouteInterfaceParsing() {
        let route = """
          route to: 192.0.2.2
        destination: 192.0.2.2
            interface: en7
              flags: <UP,HOST,DONE,LLSTATIC,CLONING>
        """
        XCTAssertEqual(StorageLinkInspector.parseRouteInterface(route), "en7")
        XCTAssertNil(StorageLinkInspector.parseRouteInterface("route to: nowhere\n"))
    }

    func testIfconfigMediaRateParsing() {
        let ethernet = """
        en7: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
        \tether 80:69:1a:a1:c3:d1
        \tinet 192.0.2.230 netmask 0xfffffe00 broadcast 192.0.2.255
        \tmedia: autoselect (1000baseT <full-duplex>)
        \tstatus: active
        """
        XCTAssertEqual(StorageLinkInspector.parseIfconfigMediaRate(ethernet), 1_000)

        let fast = "\tmedia: autoselect (2500base-T <full-duplex>)"
        XCTAssertEqual(StorageLinkInspector.parseIfconfigMediaRate(fast), 2_500)

        let tenGig = "\tmedia: autoselect (10Gbase-T <full-duplex>)"
        XCTAssertEqual(StorageLinkInspector.parseIfconfigMediaRate(tenGig), 10_000)

        let wifi = "\tmedia: autoselect\n\tstatus: active"
        XCTAssertNil(StorageLinkInspector.parseIfconfigMediaRate(wifi))
    }

    func testHardwarePortsParsing() {
        let output = """

        Hardware Port: USB 10/100/1000 LAN
        Device: en7
        Ethernet Address: 80:69:1a:a1:c3:d1

        Hardware Port: Wi-Fi
        Device: en0
        Ethernet Address: 84:2f:57:a3:6a:d1
        """
        let map = StorageLinkInspector.parseHardwarePorts(output)
        XCTAssertEqual(map["en7"], "USB 10/100/1000 LAN")
        XCTAssertEqual(map["en0"], "Wi-Fi")
    }

    func testUSBLocationSuffixMatchesRegistryLocation() {
        XCTAssertEqual(
            StorageLinkInspector.usbLocationSuffix(
                "IODeviceTree:/arm-io@10F00000/usb-drd1@8A280000/usb-drd1-port-ss@01200000"
            ),
            "01200000"
        )
        XCTAssertNil(StorageLinkInspector.usbLocationSuffix("IODeviceTree:/"))
    }

    func testUSBDeviceParsingReadsLocationAndSpeed() throws {
        let plist: [String: Any] = [
            "IORegistryEntryName": "IOService",
            "IOService": [
                "IORegistryEntryName": "Sabrent",
                "IORegistryEntryLocation": "01200000",
                "USB Product Name": "Sabrent",
                "USB Vendor Name": "Sabrent",
                "UsbLinkSpeed": NSNumber(value: 10_000_000_000)
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        let devices = StorageLinkInspector.parseUSBDevices(data)

        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.location, "01200000")
        XCTAssertEqual(devices.first?.productName, "Sabrent")
        XCTAssertEqual(devices.first?.bitsPerSecond, 10_000_000_000)
    }

    func testDiskUtilInfoParsing() throws {
        let plist: [String: Any] = [
            "BusProtocol": "USB",
            "SolidState": true,
            "Internal": false,
            "DeviceTreePath": "IODeviceTree:/arm-io@10F00000/usb-drd1@8A280000/usb-drd1-port-ss@01200000",
            "MediaType": "Generic",
            "WritableMedia": true
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        let info = try XCTUnwrap(StorageLinkInspector.parseDiskUtilInfo(data))

        XCTAssertEqual(info.busProtocol, "USB")
        XCTAssertEqual(info.solidState, true)
        XCTAssertEqual(info.isInternal, false)
        XCTAssertTrue(info.deviceTreePath?.hasSuffix("@01200000") == true)
    }

    func testDiskImageMountPointsParsing() throws {
        let plist: [String: Any] = [
            "images": [
                [
                    "image-path": "/Users/x/Downloads/app.dmg",
                    "system-entities": [
                        ["dev-entry": "/dev/disk11"],
                        ["dev-entry": "/dev/disk11s1", "mount-point": "/Volumes/App Installer"]
                    ]
                ]
            ]
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .binary,
            options: 0
        )

        let points = MountedVolumeProbe.parseDiskImagePlist(data)

        XCTAssertEqual(points, ["/Volumes/App Installer"])
    }

    func testUSBContextUsesTheNegotiatedLinkSpeed() {
        let volume = MountedVolumeInfo(
            url: URL(fileURLWithPath: "/Volumes/Buffer", isDirectory: true),
            name: "Buffer",
            fileSystemType: "exfat",
            mountSource: "/dev/disk8s2",
            isRemovable: true,
            isEjectable: true,
            isReadOnly: false,
            isDiskImage: false,
            totalCapacity: 1_000_000_000_000
        )
        let diskInfo = DiskVolumeInfo(
            busProtocol: "USB",
            solidState: true,
            isInternal: false,
            deviceTreePath: "IODeviceTree:/arm-io@10F00000/usb-drd1@8A280000/usb-drd1-port-ss@01200000",
            mediaType: "Generic",
            isWritableMedia: true
        )
        let devices = [
            USBDeviceLink(location: "00200000", productName: "USB 10/100/1000 LAN", vendorName: "Realtek", bitsPerSecond: 5_000_000_000),
            USBDeviceLink(location: "01200000", productName: "Sabrent", vendorName: "Sabrent", bitsPerSecond: 10_000_000_000)
        ]

        let context = StorageLinkInspector.localContext(
            volume: volume,
            diskInfo: diskInfo,
            usbDevices: devices,
            isCameraSource: false
        )

        XCTAssertEqual(context.medium, .usb)
        XCTAssertTrue(context.detected)
        XCTAssertEqual(context.negotiatedBitsPerSecond, 10_000_000_000)
        XCTAssertTrue(context.headline.contains("10 Gb/s"))
        XCTAssertEqual(context.linkTypicalMBps, 700...1_050)
    }

    func testEthernetContextUsesTheNegotiatedLinkRate() {
        let context = StorageLinkInspector.networkContext(
            host: "192.0.2.2",
            interfaceName: "en7",
            interfaceHardwareName: "USB 10/100/1000 LAN",
            mediaMegabitsPerSecond: 1_000,
            wifiMegabitsPerSecond: nil
        )

        XCTAssertEqual(context.medium, .ethernet)
        XCTAssertTrue(context.detected)
        XCTAssertTrue(context.headline.contains("1 GbE"))
        XCTAssertEqual(context.linkTypicalMBps, 95...115)
    }

    func testWiFiContextUsesTheTransmitRate() {
        let context = StorageLinkInspector.networkContext(
            host: "192.0.2.2",
            interfaceName: "en0",
            interfaceHardwareName: "Wi-Fi",
            mediaMegabitsPerSecond: nil,
            wifiMegabitsPerSecond: 216
        )

        XCTAssertEqual(context.medium, .wifi)
        XCTAssertTrue(context.headline.contains("216"))
        XCTAssertNotNil(context.linkTypicalMBps)
        XCTAssertLessThan(context.linkTypicalMBps?.upperBound ?? 0, 40)
    }
}
