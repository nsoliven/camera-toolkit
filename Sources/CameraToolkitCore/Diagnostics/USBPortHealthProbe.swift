import Darwin
import Foundation
import IOKit

// MARK: - Detected facts

/// The enclosure end of the cable under test — the `IOUSBHostDevice`
/// properties that identify the bridge chip. Serial is not a unique
/// identity on its own: some cheap bridges report a placeholder such as
/// `012345678930`, so records also carry the volume UUID.
public struct USBDeviceIdentity: Equatable, Codable, Sendable {
    public var vendorID: Int?
    public var productID: Int?
    public var deviceVersionBCD: Int?
    public var serialNumber: String?
    public var vendorName: String?
    public var productName: String?
    /// Negotiated link rate in bits per second (`UsbLinkSpeed`).
    public var linkBitsPerSecond: Int64?
    /// `UsbPowerSinkAllocation` as the device reports it.
    public var powerSinkAllocation: Int64?

    public init(
        vendorID: Int? = nil,
        productID: Int? = nil,
        deviceVersionBCD: Int? = nil,
        serialNumber: String? = nil,
        vendorName: String? = nil,
        productName: String? = nil,
        linkBitsPerSecond: Int64? = nil,
        powerSinkAllocation: Int64? = nil
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.deviceVersionBCD = deviceVersionBCD
        self.serialNumber = serialNumber
        self.vendorName = vendorName
        self.productName = productName
        self.linkBitsPerSecond = linkBitsPerSecond
        self.powerSinkAllocation = powerSinkAllocation
    }

    /// "Sabrent RTL9210" style label — product name with vendor appended
    /// when it is not already in the product string.
    public var displayName: String {
        let product = productName ?? vendorName ?? "Unknown USB device"
        if let vendorName, !vendorName.isEmpty,
           !product.localizedCaseInsensitiveContains(vendorName) {
            return "\(product) (\(vendorName))"
        }
        return product
    }
}

/// One read of a USB port's health counters and the device behind it.
/// `counters` carries every numeric `kPortStat*` entry the port publishes
/// plus `link-error-count`; values are cumulative since boot and shared
/// per port, so only deltas from a run's baseline are meaningful.
public struct USBPortHealthSample: Equatable, Sendable {
    public var counters: [String: Int64]
    public var device: USBDeviceIdentity?
    /// IORegistry entry id of the port object — stable across a device
    /// drop/reconnect, so sampling can re-resolve the port directly.
    public var portEntryID: UInt64?
    /// The port entry's class name (`AppleUSB30XHCIARMPort` on Apple
    /// Silicon, `AppleUSBXHCIPort` on Intel).
    public var portClassName: String?
    /// The device's `IORegistryEntryLocation` (e.g. `01200000`) — its high
    /// byte identifies which root port the chain is on.
    public var deviceLocation: String?
    /// IOService-plane registry path of the port entry, for diagnostics.
    public var portPath: String?

    public init(
        counters: [String: Int64] = [:],
        device: USBDeviceIdentity? = nil,
        portEntryID: UInt64? = nil,
        portClassName: String? = nil,
        deviceLocation: String? = nil,
        portPath: String? = nil
    ) {
        self.counters = counters
        self.device = device
        self.portEntryID = portEntryID
        self.portClassName = portClassName
        self.deviceLocation = deviceLocation
        self.portPath = portPath
    }

    public var connectCount: Int64 { counters[CounterKey.connectCount] ?? 0 }
    public var enumerationFailures: Int64 { counters[CounterKey.enumerationFailureCount] ?? 0 }
    public var addressFailures: Int64 { counters[CounterKey.addressFailureCount] ?? 0 }
    public var overCurrentCount: Int64 { counters[CounterKey.overCurrentCount] ?? 0 }
    public var linkErrorCount: Int64 { counters[CounterKey.linkErrorCount] ?? 0 }
    /// Sum of every `kPortStatEOF2Violation*` bucket the port reports.
    public var eof2Violations: Int64 {
        counters.reduce(0) { $1.key.hasPrefix(CounterKey.eof2ViolationPrefix) ? $0 + $1.value : $0 }
    }

    /// The failure counters the verdict watches: enumeration, address, and
    /// EOF2 violations. Connects and link errors are graded separately.
    public var failureCount: Int64 {
        enumerationFailures + addressFailures + eof2Violations
    }

    /// Counter key names as macOS publishes them.
    public enum CounterKey {
        public static let connectCount = "kPortStatConnectCount"
        public static let enumerationFailureCount = "kPortStatEnumerationFailureCount"
        public static let addressFailureCount = "kPortStatAddressFailureCount"
        public static let overCurrentCount = "kPortStatOverCurrentCount"
        public static let powerStateTime = "kPortStatPowerStateTime"
        public static let eof2ViolationPrefix = "kPortStatEOF2Violation"
        public static let linkErrorCount = "link-error-count"
    }
}

// MARK: - Pure parsing and deltas

/// Pure parsing of registry property dictionaries into health samples —
/// unit-tested with fixtures, never touching IOKit itself.
public enum USBPortHealthParser {
    /// Reads an `IOUSBHostDevice` property dictionary into an identity.
    /// Missing or mistyped keys stay nil rather than guessing.
    public static func deviceIdentity(_ properties: [String: Any]) -> USBDeviceIdentity {
        USBDeviceIdentity(
            vendorID: int(properties["idVendor"]),
            productID: int(properties["idProduct"]),
            deviceVersionBCD: int(properties["bcdDevice"]),
            serialNumber: properties["kUSBSerialNumberString"] as? String,
            vendorName: properties["USB Vendor Name"] as? String,
            productName: properties["USB Product Name"] as? String,
            linkBitsPerSecond: (properties["UsbLinkSpeed"] as? NSNumber)?.int64Value,
            powerSinkAllocation: (properties["UsbPowerSinkAllocation"] as? NSNumber)?.int64Value
        )
    }

    /// Pulls the numeric counters out of a port entry's property
    /// dictionary: every `kPortStat*` number inside `port-statistics` plus
    /// the top-level `link-error-count`. Non-numeric values are skipped.
    public static func portCounters(_ properties: [String: Any]) -> [String: Int64] {
        var counters: [String: Int64] = [:]
        if let statistics = properties["port-statistics"] as? [String: Any] {
            for (key, value) in statistics where key.hasPrefix("kPortStat") {
                if let number = value as? NSNumber {
                    counters[key] = number.int64Value
                }
            }
        }
        if let linkErrors = properties[USBPortHealthSample.CounterKey.linkErrorCount] as? NSNumber {
            counters[USBPortHealthSample.CounterKey.linkErrorCount] = linkErrors.int64Value
        }
        return counters
    }

    /// `end - start` per counter key. Keys missing on one side count as 0 —
    /// a counter that only appears after the baseline is still new
    /// activity — and deltas clamp at zero so a reset counter never
    /// reports negative failures.
    public static func delta(from start: [String: Int64], to end: [String: Int64]) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for key in Set(start.keys).union(end.keys) {
            let change = (end[key] ?? 0) - (start[key] ?? 0)
            if change > 0 {
                result[key] = change
            }
        }
        return result
    }

    /// "USB-C port 2" from a device location like `02100000`: the top byte
    /// of the USB locationID is the root port number. Returns nil when the
    /// string is not parseable hex.
    public static func portLabel(forLocation location: String?) -> String? {
        guard let location,
              let value = UInt64(location.trimmingCharacters(in: .whitespaces), radix: 16) else {
            return nil
        }
        let port = (value >> 24) & 0xFF
        guard port > 0 else { return nil }
        return "USB-C port \(port)"
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

// MARK: - Probe seam

/// Where the run gets its once-a-second port reads. Tests substitute a
/// fake; production walks the IORegistry.
public protocol USBPortHealthProbing: Sendable {
    /// Full walk: volume → BSD disk → IOMedia → `IOUSBHostDevice` → port.
    /// Returns nil when the volume is not USB-attached.
    func sample(volumeRoot: URL) -> USBPortHealthSample?
    /// Re-read just the port's counters by registry entry id — the port
    /// entry survives the device behind it dropping off the bus, so this
    /// keeps counting through a crash-and-reconnect storm.
    func samplePort(entryID: UInt64) -> USBPortHealthSample?
}

// MARK: - IOKit probe

/// The real probe. A mount's BSD name resolves to its `IOMedia` entry via
/// `IOBSDNameMatching`; parent iteration in the IOService plane reaches
/// the `IOUSBHostDevice`, then the port object that carries the counters.
public struct USBPortHealthProbe: USBPortHealthProbing {
    /// Safety bound on parent walks — a healthy chain is ~6 entries.
    private static let parentWalkLimit = 16

    public init() {}

    public func sample(volumeRoot: URL) -> USBPortHealthSample? {
        guard let bsdName = Self.bsdDiskName(forVolumeAt: volumeRoot) else { return nil }
        return sample(bsdName: bsdName)
    }

    /// `/Volumes/X` → `disk8s2` via statfs (`/dev/disk8s2`), nil when the
    /// mount cannot be stat'ed or has no `/dev` source (network share).
    public static func bsdDiskName(forVolumeAt url: URL) -> String? {
        var info = Darwin.statfs()
        guard url.withUnsafeFileSystemRepresentation({ path in
            path.map { statfs($0, &info) == 0 } ?? false
        }) else { return nil }
        let mountSource = withUnsafeBytes(of: info.f_mntfromname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return bsdDiskName(mountSource: mountSource)
    }

    /// `/dev/disk8s2` → `disk8s2`; anything not under `/dev/` is not a
    /// local disk (SMB mounts carry `//host/share`).
    public static func bsdDiskName(mountSource: String) -> String? {
        guard mountSource.hasPrefix("/dev/") else { return nil }
        let name = String(mountSource.dropFirst("/dev/".count))
        return name.isEmpty ? nil : name
    }

    /// Resolves a BSD leaf (`disk8s2`) to the port counters behind it.
    /// Internal so tests can exercise the walk against the real registry
    /// only where hardware exists; the parsing above stays pure.
    func sample(bsdName: String) -> USBPortHealthSample? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOBSDNameMatching(kIOMainPortDefault, 0, bsdName),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let media = IOIteratorNext(iterator)
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }

        guard let device = Self.firstAncestor(
            of: media,
            matching: { entry in
                Self.className(of: entry) == "IOUSBHostDevice"
                    || Self.properties(of: entry)["UsbLinkSpeed"] != nil
            }
        ) else { return nil }
        defer { IOObjectRelease(device) }

        let deviceProperties = Self.properties(of: device)
        let identity = USBPortHealthParser.deviceIdentity(deviceProperties)

        guard let port = Self.firstAncestor(
            of: device,
            matching: { entry in
                let properties = Self.properties(of: entry)
                return properties["port-statistics"] != nil
                    || properties[USBPortHealthSample.CounterKey.linkErrorCount] != nil
            }
        ) else {
            return USBPortHealthSample(
                device: identity,
                deviceLocation: deviceProperties["IORegistryEntryLocation"] as? String
            )
        }
        defer { IOObjectRelease(port) }

        return sample(portEntry: port, device: identity, deviceProperties: deviceProperties)
    }

    public func samplePort(entryID: UInt64) -> USBPortHealthSample? {
        let entry = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IORegistryEntryIDMatching(entryID)
        )
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return sample(portEntry: entry, device: nil, deviceProperties: [:])
    }

    private func sample(
        portEntry: io_registry_entry_t,
        device: USBDeviceIdentity?,
        deviceProperties: [String: Any]
    ) -> USBPortHealthSample {
        let properties = Self.properties(of: portEntry)
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(portEntry, &entryID)
        return USBPortHealthSample(
            counters: USBPortHealthParser.portCounters(properties),
            device: device,
            portEntryID: entryID == 0 ? nil : entryID,
            portClassName: Self.className(of: portEntry),
            deviceLocation: deviceProperties["IORegistryEntryLocation"] as? String,
            portPath: Self.path(of: portEntry)
        )
    }

    /// Walks IOService-plane parents until `matching` accepts an entry,
    /// returning it retained. Nil when the chain ends or the walk limit is
    /// hit without a match.
    private static func firstAncestor(
        of entry: io_registry_entry_t,
        matching: (io_registry_entry_t) -> Bool
    ) -> io_registry_entry_t? {
        var current = entry
        for _ in 0..<parentWalkLimit {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == KERN_SUCCESS,
                  parent != 0 else {
                break
            }
            if matching(parent) {
                return parent
            }
            if current != entry {
                IOObjectRelease(current)
            }
            current = parent
        }
        if current != entry {
            IOObjectRelease(current)
        }
        return nil
    }

    private static func properties(of entry: io_registry_entry_t) -> [String: Any] {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(
            entry, &properties, kCFAllocatorDefault, 0
        ) == KERN_SUCCESS else { return [:] }
        return properties?.takeRetainedValue() as? [String: Any] ?? [:]
    }

    private static func className(of entry: io_object_t) -> String? {
        var name = [CChar](repeating: 0, count: 128)
        guard IOObjectGetClass(entry, &name) == KERN_SUCCESS else { return nil }
        return String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func path(of entry: io_registry_entry_t) -> String? {
        var path = [CChar](repeating: 0, count: 512)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS else {
            return nil
        }
        return String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
