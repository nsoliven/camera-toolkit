import CoreWLAN
import Darwin
import Foundation

// MARK: - Mounted volumes

/// What the speed-test window needs to know about a mounted volume: enough to
/// filter non-storage mounts and to route link detection (local bus vs network
/// share) without calling back into Disk Arbitration.
struct MountedVolumeInfo: Hashable, Sendable {
    var url: URL
    var name: String
    var fileSystemType: String
    var mountSource: String
    var isRemovable: Bool
    var isEjectable: Bool
    var isReadOnly: Bool
    var isDiskImage: Bool
    var totalCapacity: Int64?

    var isNetwork: Bool {
        fileSystemType == "smbfs" || fileSystemType == "nfs" || mountSource.hasPrefix("//")
    }

    /// Virtual filesystems that can appear in the mounted list but are not
    /// storage a speed test can meaningfully measure.
    var isStorageLike: Bool {
        switch fileSystemType.lowercased() {
        case "devfs", "autofs", "map", "nullfs", "bindfs", "synthetic", "mntfs", "fdesc":
            return false
        default:
            return true
        }
    }
}

enum MountedVolumeProbe {
    static func mountedVolumes() async -> [MountedVolumeInfo] {
        await Task.detached(priority: .utility) {
            gather()
        }.value
    }

    static func gather(fileManager: FileManager = .default) -> [MountedVolumeInfo] {
        let keys: Set<URLResourceKey> = [
            .volumeNameKey,
            .volumeIsRemovableKey,
            .volumeIsEjectableKey,
            .volumeIsReadOnlyKey,
            .volumeTotalCapacityKey
        ]
        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) ?? []
        let diskImageMounts = diskImageMountPoints()

        return urls.map { url in
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: keys)
            let mount = statFSInfo(standardized.path)
            return MountedVolumeInfo(
                url: standardized,
                name: values?.volumeName ?? standardized.lastPathComponent,
                fileSystemType: mount?.fileSystemType ?? "",
                mountSource: mount?.mountSource ?? "",
                isRemovable: values?.volumeIsRemovable ?? false,
                isEjectable: values?.volumeIsEjectable ?? false,
                isReadOnly: values?.volumeIsReadOnly ?? false,
                isDiskImage: diskImageMounts.contains(standardized.path),
                totalCapacity: values?.volumeTotalCapacity.map(Int64.init)
            )
        }
    }

    static func statFSInfo(_ path: String) -> (fileSystemType: String, mountSource: String)? {
        var info = Darwin.statfs()
        guard path.withCString({ statfs($0, &info) }) == 0 else { return nil }
        return (
            fileSystemType: stringField(info.f_fstypename),
            mountSource: stringField(info.f_mntfromname)
        )
    }

    /// Mounted disk images expose their mount points through hdiutil; the
    /// volume flags alone cannot tell a .dmg mount from a real drive.
    static func diskImageMountPoints() -> Set<String> {
        guard let data = ShellCommand.output("/usr/bin/hdiutil", ["info", "-plist"]) else { return [] }
        return parseDiskImagePlist(data)
    }

    static func parseDiskImagePlist(_ data: Data) -> Set<String> {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = root["images"] as? [[String: Any]] else {
            return []
        }
        var points = Set<String>()
        for image in images {
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                if let mountPoint = entity["mount-point"] as? String {
                    points.insert(URL(fileURLWithPath: mountPoint).standardizedFileURL.path)
                }
            }
        }
        return points
    }

    private static func stringField<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}

// MARK: - Shell

enum ShellCommand {
    static func output(_ executable: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return data
        } catch {
            return nil
        }
    }

    static func text(_ executable: String, _ arguments: [String]) -> String? {
        output(executable, arguments).flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - Detected facts

/// A USB host device from the I/O registry, including the location used to
/// match a mounted volume's device-tree path.
struct USBDeviceLink: Equatable, Sendable {
    var location: String
    var productName: String
    var vendorName: String?
    var bitsPerSecond: Int64
}

/// The fields `diskutil info -plist` reports about a volume's bus and media.
struct DiskVolumeInfo: Equatable, Sendable {
    var busProtocol: String?
    var solidState: Bool?
    var isInternal: Bool?
    var deviceTreePath: String?
    var mediaType: String?
    var isWritableMedia: Bool?
}

// MARK: - Link context

/// What macOS could tell us about how a target is attached: the medium, the
/// negotiated link when detectable, and the typical ranges to compare a
/// measurement against. `detected == false` means the figures are assumptions
/// and must be labelled "typical" in the UI.
struct StorageLinkContext: Equatable, Sendable {
    enum Medium: String, Equatable, Sendable {
        case usb
        case thunderbolt
        case ethernet
        case wifi
        case internalStorage
        case networkShare
        case unknown
    }

    var medium: Medium
    var headline: String
    var detail: String?
    var detected: Bool
    var negotiatedBitsPerSecond: Int64?
    /// What the wire itself typically carries.
    var linkTypicalMBps: ClosedRange<Double>?
    /// What the media behind the wire typically does.
    var mediaTypicalReadMBps: ClosedRange<Double>?
    var mediaTypicalWriteMBps: ClosedRange<Double>?
    var isSolidState: Bool?

    /// The binding constraint: whichever of link and media is typically slower.
    var typicalRead: ClosedRange<Double>? {
        Self.slower(mediaTypicalReadMBps, linkTypicalMBps)
    }

    var typicalWrite: ClosedRange<Double>? {
        Self.slower(mediaTypicalWriteMBps ?? mediaTypicalReadMBps, linkTypicalMBps)
    }

    static func slower(_ a: ClosedRange<Double>?, _ b: ClosedRange<Double>?) -> ClosedRange<Double>? {
        switch (a, b) {
        case let (a?, b?):
            return TransferSpeedReference.midpoint(of: a) <= TransferSpeedReference.midpoint(of: b) ? a : b
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }
}

enum StorageLinkInspector {
    static func contexts(for targets: [StorageBenchmarkTarget]) async -> [String: StorageLinkContext] {
        await Task.detached(priority: .utility) {
            let usbDevices = usbHostDevices()
            var map: [String: StorageLinkContext] = [:]
            for target in targets where target.isAvailable {
                guard let volume = target.volumeInfo else { continue }
                if volume.isNetwork {
                    map[target.id] = networkContext(mountSource: volume.mountSource)
                } else {
                    let diskInfo = diskVolumeInfo(at: volume.url)
                    // A drive that is the Buffer or library as well as a camera
                    // source is still media, not a card — card typicals apply
                    // only to pure card sources.
                    let isPureCardSource = target.roleNames.contains("Camera Source")
                        && !target.roleNames.contains("Buffer")
                        && !target.roleNames.contains("Photo Library")
                    map[target.id] = localContext(
                        volume: volume,
                        diskInfo: diskInfo,
                        usbDevices: usbDevices,
                        isCameraSource: isPureCardSource
                    )
                }
            }
            return map
        }.value
    }

    // MARK: Local volumes

    static func localContext(
        volume: MountedVolumeInfo,
        diskInfo: DiskVolumeInfo?,
        usbDevices: [USBDeviceLink],
        isCameraSource: Bool
    ) -> StorageLinkContext {
        let media = mediaTypical(volume: volume, diskInfo: diskInfo, isCameraSource: isCameraSource)
        let bus = diskInfo?.busProtocol?.lowercased() ?? ""

        if bus.contains("usb") {
            let location = diskInfo?.deviceTreePath.flatMap(usbLocationSuffix)
            let device = location.flatMap { suffix in
                usbDevices.first { $0.location.lowercased() == suffix }
            }
            if let device {
                let linkName = USBLinkSnapshot(name: device.productName, bitsPerSecond: device.bitsPerSecond).interfaceName
                return StorageLinkContext(
                    medium: .usb,
                    headline: "\(linkName) · negotiated \(formattedBitsPerSecond(device.bitsPerSecond))",
                    detail: joinedDetail(deviceDetail(product: device.productName, vendor: device.vendorName, diskInfo: diskInfo), media.note),
                    detected: true,
                    negotiatedBitsPerSecond: device.bitsPerSecond,
                    linkTypicalMBps: TransferSpeedReference.usbTypical(bitsPerSecond: device.bitsPerSecond),
                    mediaTypicalReadMBps: media.range,
                    mediaTypicalWriteMBps: media.range,
                    isSolidState: diskInfo?.solidState
                )
            }
            return StorageLinkContext(
                medium: .usb,
                headline: "USB storage",
                detail: joinedDetail("Negotiated speed not detected — typical range shown", media.note),
                detected: false,
                linkTypicalMBps: nil,
                mediaTypicalReadMBps: media.range,
                mediaTypicalWriteMBps: media.range,
                isSolidState: diskInfo?.solidState
            )
        }

        if bus.contains("thunderbolt") {
            return StorageLinkContext(
                medium: .thunderbolt,
                headline: "Thunderbolt storage",
                detail: joinedDetail(deviceDetail(product: nil, vendor: nil, diskInfo: diskInfo), media.note),
                detected: true,
                negotiatedBitsPerSecond: nil,
                linkTypicalMBps: TransferSpeedReference.thunderboltTypical,
                mediaTypicalReadMBps: media.range,
                mediaTypicalWriteMBps: media.range,
                isSolidState: diskInfo?.solidState
            )
        }

        if bus.contains("sata") {
            return StorageLinkContext(
                medium: .internalStorage,
                headline: "SATA storage",
                detail: joinedDetail(deviceDetail(product: nil, vendor: nil, diskInfo: diskInfo), media.note),
                detected: true,
                linkTypicalMBps: TransferSpeedReference.sataSSD,
                mediaTypicalReadMBps: media.range,
                mediaTypicalWriteMBps: media.range,
                isSolidState: diskInfo?.solidState
            )
        }

        if bus.contains("pci") || bus.contains("nvme") || bus.contains("apple fabric") || diskInfo?.isInternal == true {
            return StorageLinkContext(
                medium: .internalStorage,
                headline: "Internal storage",
                detail: joinedDetail(deviceDetail(product: nil, vendor: nil, diskInfo: diskInfo), media.note),
                detected: true,
                linkTypicalMBps: TransferSpeedReference.internalNVMe,
                mediaTypicalReadMBps: media.range,
                mediaTypicalWriteMBps: media.range,
                isSolidState: diskInfo?.solidState ?? true
            )
        }

        return StorageLinkContext(
            medium: .unknown,
            headline: "External storage",
            detail: joinedDetail("Connection not detected — typical range shown", media.note),
            detected: false,
            mediaTypicalReadMBps: media.range,
            mediaTypicalWriteMBps: media.range,
            isSolidState: diskInfo?.solidState
        )
    }

    /// Where a media range came from — `note` is set when the range is a
    /// published product spec rather than anything this Mac measured.
    private static func mediaTypical(
        volume: MountedVolumeInfo,
        diskInfo: DiskVolumeInfo?,
        isCameraSource: Bool
    ) -> (range: ClosedRange<Double>, note: String?) {
        if isCameraSource {
            if volume.name.localizedCaseInsensitiveContains("osmo") {
                return (
                    TransferSpeedReference.osmoInternalTypical,
                    "Up to 600 MB/s is DJI's published figure for the Osmo 360 — a spec sheet number, not a measurement"
                )
            }
            return (TransferSpeedReference.cameraCardTypical, nil)
        }
        switch diskInfo?.solidState {
        case true: return (TransferSpeedReference.internalNVMe, nil)
        case false: return (100...180, nil)
        case nil: return (TransferSpeedReference.usbSSDUndetected, nil)
        }
    }

    private static func joinedDetail(_ parts: String?...) -> String? {
        let joined = parts.compactMap { $0 }.joined(separator: " · ")
        return joined.isEmpty ? nil : joined
    }

    // MARK: Network volumes

    static func networkContext(mountSource: String) -> StorageLinkContext {
        let host = parseMountHost(mountSource)
        let interface = host.flatMap(routeInterface(to:))
        let wifiRate = interface.flatMap(wifiTransmitRate(interface:))
        let hardwareName = interface.flatMap(hardwarePortName(interface:))
        let mediaRate = interface.flatMap(ifconfigMediaRate(interface:))
        return networkContext(
            host: host,
            interfaceName: interface,
            interfaceHardwareName: hardwareName,
            mediaMegabitsPerSecond: mediaRate,
            wifiMegabitsPerSecond: wifiRate
        )
    }

    static func networkContext(
        host: String?,
        interfaceName: String?,
        interfaceHardwareName: String?,
        mediaMegabitsPerSecond: Int?,
        wifiMegabitsPerSecond: Double?
    ) -> StorageLinkContext {
        let via = interfaceHardwareName ?? interfaceName
        if let wifiMegabitsPerSecond {
            let range = TransferSpeedReference.wifiTypical(megabitsPerSecond: wifiMegabitsPerSecond)
            return StorageLinkContext(
                medium: .wifi,
                headline: "Wi-Fi · negotiated \(Int(wifiMegabitsPerSecond.rounded())) Mb/s",
                detail: "Share\(host.map { " on \($0)" } ?? "")\(via.map { " via \($0)" } ?? "") — Wi-Fi goodput varies with signal; NAS media figures are estimates until a write test measures them",
                detected: true,
                negotiatedBitsPerSecond: Int64(wifiMegabitsPerSecond * 1_000_000),
                linkTypicalMBps: range,
                mediaTypicalReadMBps: TransferSpeedReference.nasPoolReadTypical,
                mediaTypicalWriteMBps: TransferSpeedReference.nasPoolWriteTypical
            )
        }
        if let mediaMegabitsPerSecond {
            let range = TransferSpeedReference.smbTypical(megabitsPerSecond: Double(mediaMegabitsPerSecond))
            let gigabits = mediaMegabitsPerSecond >= 1_000
                ? "\(mediaMegabitsPerSecond / 1_000)\(mediaMegabitsPerSecond % 1_000 == 0 ? "" : ".5") GbE"
                : "\(mediaMegabitsPerSecond) MbE"
            return StorageLinkContext(
                medium: .ethernet,
                headline: "SMB · \(gigabits) link\(via.map { " via \($0)" } ?? "")",
                detail: "Share\(host.map { " on \($0)" } ?? "") — NAS pool is a spinning-disk estimate until tested",
                detected: true,
                negotiatedBitsPerSecond: Int64(mediaMegabitsPerSecond) * 1_000_000,
                linkTypicalMBps: range,
                mediaTypicalReadMBps: TransferSpeedReference.nasPoolReadTypical,
                mediaTypicalWriteMBps: TransferSpeedReference.nasPoolWriteTypical
            )
        }
        return StorageLinkContext(
            medium: .networkShare,
            headline: "Network share\(host.map { " on \($0)" } ?? "")",
            detail: "Link rate not detected — typical range shown; NAS media figures are estimates until a write test measures them",
            detected: false,
            linkTypicalMBps: TransferSpeedReference.genericNetworkTypical,
            mediaTypicalReadMBps: TransferSpeedReference.nasPoolReadTypical,
            mediaTypicalWriteMBps: TransferSpeedReference.nasPoolWriteTypical
        )
    }

    // MARK: System queries

    static func diskVolumeInfo(at url: URL) -> DiskVolumeInfo? {
        guard let data = ShellCommand.output("/usr/sbin/diskutil", ["info", "-plist", url.path]) else { return nil }
        return parseDiskUtilInfo(data)
    }

    static func usbHostDevices() -> [USBDeviceLink] {
        guard let data = ShellCommand.output("/usr/sbin/ioreg", ["-r", "-c", "IOUSBHostDevice", "-a"]) else { return [] }
        return parseUSBDevices(data)
    }

    static func routeInterface(to host: String) -> String? {
        guard let output = ShellCommand.text("/sbin/route", ["-n", "get", host]) else { return nil }
        return parseRouteInterface(output)
    }

    static func ifconfigMediaRate(interface: String) -> Int? {
        guard let output = ShellCommand.text("/sbin/ifconfig", [interface]) else { return nil }
        return parseIfconfigMediaRate(output)
    }

    static func wifiTransmitRate(interface: String) -> Double? {
        guard interface.hasPrefix("en"),
              let wifi = CWWiFiClient.shared().interface(withName: interface),
              wifi.transmitRate() > 0 else {
            return nil
        }
        return wifi.transmitRate()
    }

    static func hardwarePortName(interface: String) -> String? {
        guard let output = ShellCommand.text("/usr/sbin/networksetup", ["-listallhardwareports"]) else { return nil }
        return parseHardwarePorts(output)[interface]
    }

    // MARK: Parsers

    static func parseDiskUtilInfo(_ data: Data) -> DiskVolumeInfo? {
        guard let dict = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return DiskVolumeInfo(
            busProtocol: dict["BusProtocol"] as? String,
            solidState: (dict["SolidState"] as? NSNumber)?.boolValue,
            isInternal: (dict["Internal"] as? NSNumber)?.boolValue,
            deviceTreePath: dict["DeviceTreePath"] as? String,
            mediaType: dict["MediaType"] as? String,
            isWritableMedia: (dict["WritableMedia"] as? NSNumber)?.boolValue
        )
    }

    static func parseUSBDevices(_ data: Data) -> [USBDeviceLink] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return []
        }
        var devices: [USBDeviceLink] = []
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let product = dictionary["USB Product Name"] as? String,
                   let location = dictionary["IORegistryEntryLocation"] as? String,
                   let speed = dictionary["UsbLinkSpeed"] as? NSNumber {
                    devices.append(USBDeviceLink(
                        location: location,
                        productName: product,
                        vendorName: dictionary["USB Vendor Name"] as? String,
                        bitsPerSecond: speed.int64Value
                    ))
                }
                for child in dictionary.values { visit(child) }
            } else if let array = value as? [Any] {
                for child in array { visit(child) }
            }
        }
        visit(root)
        return devices
    }

    /// `IODeviceTree:.../usb-drd1-port-ss@01200000` → `01200000`, the address
    /// that also appears as `IORegistryEntryLocation` on the USB host device.
    static func usbLocationSuffix(_ deviceTreePath: String) -> String? {
        guard let lastComponent = deviceTreePath.split(separator: "/").last,
              lastComponent.contains("@"),
              let address = lastComponent.split(separator: "@").last,
              !address.isEmpty else {
            return nil
        }
        return String(address).lowercased()
    }

    /// `//user@nas.local/share` → `nas.local`; `//nas/share` → `nas`.
    static func parseMountHost(_ mountSource: String) -> String? {
        guard mountSource.hasPrefix("//") else { return nil }
        let withoutSlashes = mountSource.dropFirst(2)
        let withoutUser = withoutSlashes.split(separator: "@", maxSplits: 1).last ?? withoutSlashes[...]
        let host = withoutUser.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
        return host.isEmpty ? nil : host
    }

    static func parseRouteInterface(_ output: String) -> String? {
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("interface:") else { continue }
            let name = trimmed.dropFirst("interface:".count).trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// Parses `media: autoselect (1000baseT <full-duplex>)` style lines into
    /// megabits per second. Returns nil when the interface reports no rate
    /// (`media: autoselect` alone, Wi-Fi, or inactive links).
    static func parseIfconfigMediaRate(_ output: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"(\d+)\s*([Gg])?base"#) else { return nil }
        for line in output.split(separator: "\n") where line.contains("media:") {
            let text = String(line)
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  let digitsRange = Range(match.range(at: 1), in: text),
                  let digits = Int(text[digitsRange]),
                  digits > 0 else {
                continue
            }
            let gigabit = match.range(at: 2).location != NSNotFound
            return gigabit ? digits * 1_000 : digits
        }
        return nil
    }

    /// Maps `networksetup -listallhardwareports` output to a device → port name
    /// dictionary (`en7` → `USB 10/100/1000 LAN`).
    static func parseHardwarePorts(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        var pendingPort: String?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Hardware Port:") {
                pendingPort = String(trimmed.dropFirst("Hardware Port:".count)).trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Device:"), let pendingPort {
                let device = String(trimmed.dropFirst("Device:".count)).trimmingCharacters(in: .whitespaces)
                if !device.isEmpty { map[device] = pendingPort }
            }
        }
        return map
    }

    static func formattedBitsPerSecond(_ bitsPerSecond: Int64) -> String {
        if bitsPerSecond < 1_000_000_000 {
            return "\(bitsPerSecond / 1_000_000) Mb/s"
        }
        let gigabits = Double(bitsPerSecond) / 1_000_000_000
        return gigabits.truncatingRemainder(dividingBy: 1) == 0
            ? "\(Int(gigabits)) Gb/s"
            : String(format: "%.1f Gb/s", gigabits)
    }

    private static func deviceDetail(product: String?, vendor: String?, diskInfo: DiskVolumeInfo?) -> String? {
        var parts: [String] = []
        if let product, !product.isEmpty {
            parts.append(vendor.map { product.localizedCaseInsensitiveContains($0) ? product : "\(product) (\($0))" } ?? product)
        }
        if let mediaType = diskInfo?.mediaType, !mediaType.isEmpty, mediaType != "Generic" {
            parts.append(mediaType)
        }
        if diskInfo?.solidState == true {
            parts.append("solid-state")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
