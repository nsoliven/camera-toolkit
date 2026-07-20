import Foundation

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }

    var formattedWholeStorage: String {
        let byteCount = Swift.max(self, 0)
        let valueAndUnit: (value: Double, unit: String)

        switch byteCount {
        case 1_000_000_000_000...:
            valueAndUnit = (Double(byteCount) / 1_000_000_000_000, "TB")
        case 1_000_000_000...:
            valueAndUnit = (Double(byteCount) / 1_000_000_000, "GB")
        case 1_000_000...:
            valueAndUnit = (Double(byteCount) / 1_000_000, "MB")
        case 1_000...:
            valueAndUnit = (Double(byteCount) / 1_000, "KB")
        default:
            return "\(byteCount) B"
        }

        return "\(Int(valueAndUnit.value.rounded())) \(valueAndUnit.unit)"
    }
}
