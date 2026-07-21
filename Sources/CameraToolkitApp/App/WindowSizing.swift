import AppKit

enum CameraToolkitPopOutWindow: CaseIterable {
    case settings
    case transferQueue
    case storageSpeedTests
    case eventLibrary
    case photoDatabase
    case keyboardShortcuts
    case preview
    case driveInformation

    var minimumContentSize: NSSize {
        switch self {
        case .settings: NSSize(width: 660, height: 520)
        case .transferQueue: NSSize(width: 720, height: 440)
        case .storageSpeedTests: NSSize(width: 720, height: 520)
        case .eventLibrary: NSSize(width: 940, height: 600)
        case .photoDatabase: NSSize(width: 820, height: 540)
        case .keyboardShortcuts: NSSize(width: 620, height: 480)
        case .preview: NSSize(width: 640, height: 440)
        case .driveInformation: NSSize(width: 640, height: 520)
        }
    }
}

@MainActor
enum CameraToolkitWindowSizing {
    private static let practicalUnlimitedSize = NSSize(width: 100_000, height: 100_000)

    static func configure(_ window: NSWindow, as kind: CameraToolkitPopOutWindow) {
        let minimumContentSize = kind.minimumContentSize
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumContentSize
        window.minSize = window.frameRect(
            forContentRect: NSRect(origin: .zero, size: minimumContentSize)
        ).size
        window.contentMaxSize = practicalUnlimitedSize
        window.maxSize = practicalUnlimitedSize
    }
}
