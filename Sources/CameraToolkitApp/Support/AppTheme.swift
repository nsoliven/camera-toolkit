import CameraToolkitCore
import SwiftUI

enum AppTheme {
    static let background = LinearGradient(
        colors: [
            Color(nsColor: .windowBackgroundColor),
            Color(red: 0.06, green: 0.09, blue: 0.10).opacity(0.28),
            Color(red: 0.12, green: 0.13, blue: 0.10).opacity(0.18)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let panel = Color(nsColor: .controlBackgroundColor).opacity(0.86)
    static let accent = Color(red: 0.08, green: 0.47, blue: 0.62)
    static let mint = Color(red: 0.12, green: 0.58, blue: 0.42)
    static let amber = Color(red: 0.86, green: 0.55, blue: 0.16)
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
