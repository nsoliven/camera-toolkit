import Foundation

struct USBLinkSnapshot: Identifiable, Equatable, Sendable {
    var id: String { "\(name)-\(bitsPerSecond)" }
    var name: String
    var bitsPerSecond: Int64

    var interfaceName: String {
        switch bitsPerSecond {
        case ...500_000_000:
            "USB 2.0"
        case ...5_000_000_000:
            "USB 3.2 Gen 1"
        case ...10_000_000_000:
            "USB 3.2 Gen 2"
        case ...20_000_000_000:
            "USB 3.2 Gen 2x2"
        default:
            "USB4 / faster"
        }
    }

    var formattedLinkRate: String {
        if bitsPerSecond < 1_000_000_000 {
            return "\(bitsPerSecond / 1_000_000) Mb/s"
        }
        return "\(bitsPerSecond / 1_000_000_000) Gb/s"
    }

    var theoreticalMegabytesPerSecond: Int64 {
        bitsPerSecond / 8 / 1_000_000
    }
}

enum USBLinkProbe {
    static func connectedStorageLinks() async -> [USBLinkSnapshot] {
        await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
            process.arguments = ["-r", "-c", "IOUSBHostDevice", "-a"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { return [] }
                return parsePropertyList(data)
            } catch {
                return []
            }
        }.value
    }

    static func parsePropertyList(_ data: Data) -> [USBLinkSnapshot] {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return []
        }

        var links: [USBLinkSnapshot] = []
        func visit(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let product = dictionary["USB Product Name"] as? String,
                   let speed = dictionary["UsbLinkSpeed"] as? NSNumber,
                   isStorageDevice(product: product, vendor: dictionary["USB Vendor Name"] as? String) {
                    let vendor = dictionary["USB Vendor Name"] as? String
                    links.append(USBLinkSnapshot(
                        name: friendlyName(product: product, vendor: vendor),
                        bitsPerSecond: speed.int64Value
                    ))
                }
                for child in dictionary.values {
                    visit(child)
                }
            } else if let array = value as? [Any] {
                for child in array {
                    visit(child)
                }
            }
        }
        visit(root)

        var seen: Set<String> = []
        return links
            .filter { seen.insert($0.id).inserted }
            .sorted {
                if $0.bitsPerSecond == $1.bitsPerSecond { return $0.name < $1.name }
                return $0.bitsPerSecond > $1.bitsPerSecond
            }
    }

    private static func isStorageDevice(product: String, vendor: String?) -> Bool {
        let text = "\(vendor ?? "") \(product)".lowercased()
        return ["storage", "osmo", "sabrent", "jmicron"].contains { text.contains($0) }
    }

    private static func friendlyName(product: String, vendor: String?) -> String {
        if product.localizedCaseInsensitiveContains("Osmo360") {
            return "DJI Osmo 360"
        }
        if product.caseInsensitiveCompare("Sabrent") == .orderedSame {
            return "Sabrent enclosure"
        }
        if let vendor, !vendor.isEmpty, !product.localizedCaseInsensitiveContains(vendor) {
            return "\(product) (\(vendor))"
        }
        return product
    }
}
