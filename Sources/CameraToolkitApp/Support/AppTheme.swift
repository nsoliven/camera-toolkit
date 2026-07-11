import CameraToolkitCore
import SwiftUI

enum AppTheme {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let panel = Color(nsColor: .controlBackgroundColor)
    static let accent = Color.accentColor
    static let mint = Color(nsColor: .systemGreen)
    static let amber = Color(nsColor: .systemOrange)
}

extension Int64 {
    var formattedBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: self)
    }
}

extension JobAction {
    var displayName: String {
        switch self {
        case .previewFiles: "Preview files"
        case .prepareTestData: "Prepare test data"
        case .ingestCard: "Copy to buffer"
        case .syncBuffer: "Copy buffer"
        case .freeUp: "Clear buffer space"
        case .checkout: "Open for editing"
        case .checkinExports: "Save edited files"
        case .immichScan: "Check Immich"
        case .verifyManifest: "Run safety test"
        case .diskSpeed: "Test buffer speed"
        case .networkSpeed: "Test library speed"
        }
    }
}
