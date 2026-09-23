import AppKit
import CameraToolkitCore
import ImageIO
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
@testable import CameraToolkitApp
import XCTest

/// Off-screen renders of the surfaces `NativeUISnapshotTests` doesn't
/// reach: selected tiles and list rows, the burst preview overlay, the
/// organizer sheets, and the setup guide panel. Generated sample media in a
/// temp folder only; runs only when `CT_SNAPSHOT_OUT` names an output
/// folder (use the same `sandbox-exec` + `CFFIXED_USER_HOME` setup as the
/// main harness — the run flips the board's list/tiles default and puts it
/// back). Sheets are opened through the workspace and always dismissed,
/// never confirmed. Note: SwiftUI `.glassEffect` content does not draw in
/// a window parked off every display, so glass surfaces here need an
/// on-screen look too.
@MainActor
final class BoardDetailSnapshotTests: XCTestCase {
    private var outputFolder: URL!
    private var root: URL!
    private var model: DashboardModel!
    private var workspace: EventsWorkspace!
    private var unsorted: ConfiguredLocation!
    private var beachID: UUID!

    private static let modeKey = "CameraToolkit.organize.mode"

    func testRenderBoardDetails() async throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        outputFolder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        let savedMode = UserDefaults.standard.string(forKey: Self.modeKey)
        defer { UserDefaults.standard.set(savedMode, forKey: Self.modeKey) }
        try await makeSampleLibrary()

        let window = SnapshotWindows.main(model: model, workspace: workspace)
        defer { window.orderOut(nil) }
        let size = NSSize(width: 1320, height: 840)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            window.appearance = NSAppearance(named: appearance)

            // Tiles and list rows with a selection and a focused item.
            for mode in [OrganizeBoardMode.tiles, .list] {
                UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
                workspace.selection = .unsorted(unsorted.id)
                try await waitUntil { self.workspace.sources[self.unsorted.id]?.result != nil }
                try await settle(0.8)
                selectSomeStacks()
                try await snapshot(window, size: size, name: "board-unsorted-\(mode.rawValue)-selected-\(suffix)")
                workspace.selection = .event(beachID)
                try await waitUntil { self.workspace.eventStacks[self.beachID] != nil }
                try await settle(0.8)
                try await snapshot(window, size: size, name: "board-event-\(mode.rawValue)-\(suffix)")
                try await snapshot(window, size: NSSize(width: 1040, height: 720), name: "board-event-\(mode.rawValue)-narrow-\(suffix)")
            }
            UserDefaults.standard.set(OrganizeBoardMode.tiles.rawValue, forKey: Self.modeKey)

            try await renderPreviewOverlay(appearance: appearance, suffix: suffix)
            try await renderSheets(window, suffix: suffix)
            try await renderGuide(window, suffix: suffix)
        }
    }

    // MARK: - Surfaces

    private func selectSomeStacks() {
        guard let stacks = workspace.sources[unsorted.id]?.result?.stacks.sorted(by: { $0.captureDate < $1.captureDate }) else { return }
        workspace.selectStacks(stacks.dropFirst(1).prefix(3).map(\.id))
        workspace.focusedStackID = stacks.dropFirst(3).first?.id
    }

    private func renderPreviewOverlay(appearance: NSAppearance.Name, suffix: String) async throws {
        let stacks = try XCTUnwrap(workspace.sources[unsorted.id]?.result?.stacks)
            .sorted { $0.captureDate < $1.captureDate }
        let burst = try XCTUnwrap(stacks.first { $0.isBurst })
        let host = PreviewHost(workspace: workspace, stacks: stacks, stackID: burst.id)
        let window = BoardDetailSnapshotWindows.host(host, size: NSSize(width: 1100, height: 760))
        defer { window.orderOut(nil) }
        window.appearance = NSAppearance(named: appearance)
        try await settle(2.0)
        try await render(window, name: "preview-overlay-\(suffix)")
        // I opens Frame Info and T turns on face tagging, through the
        // overlay's own key handling.
        type("i", in: window)
        type("t", in: window)
        try await settle(1.0)
        try await render(window, name: "preview-overlay-info-tag-\(suffix)")
        type("t", in: window)
        type("i", in: window)
        // Detail width with the sidebar open at the window's minimum size.
        window.setContentSize(NSSize(width: 740, height: 640))
        try await settle(1.2)
        try await render(window, name: "preview-overlay-narrow-\(suffix)")
    }

    private func type(_ characters: String, in window: NSWindow) {
        for phase in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: phase,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private func renderSheets(_ window: NSWindow, suffix: String) async throws {
        workspace.selection = .unsorted(unsorted.id)
        try await settle(0.8)
        let stacks = try XCTUnwrap(workspace.sources[unsorted.id]?.result?.stacks)

        workspace.requestNewEvent(from: unsorted.id)
        try await captureSheet(window, name: "sheet-event-details-\(suffix)") { self.workspace.newEventRequest = nil }

        workspace.prepareApply(sourceLocationID: unsorted.id)
        try await waitUntil { self.workspace.pendingApplyPlan != nil }
        try await captureSheet(window, name: "sheet-apply-plan-\(suffix)") { self.workspace.pendingApplyPlan = nil }

        workspace.requestTrash(Array(stacks.prefix(2).flatMap(\.items)), from: unsorted.id)
        try await captureSheet(window, name: "sheet-trash-\(suffix)") { self.workspace.pendingTrash = nil }

        workspace.pendingRemoval = RemovalRequest(kind: .source, eventID: beachID, fileCount: 12, byteCount: 48_000_000)
        try await captureSheet(window, name: "sheet-removal-\(suffix)") { self.workspace.pendingRemoval = nil }

        workspace.faceScanRequest = FaceScanRequest(subject: .location(unsorted.id))
        try await captureSheet(window, name: "sheet-face-scan-\(suffix)") { self.workspace.faceScanRequest = nil }
    }

    private func captureSheet(_ window: NSWindow, name: String, dismiss: @escaping () -> Void) async throws {
        try await waitUntil { window.attachedSheet != nil }
        let sheet = try XCTUnwrap(window.attachedSheet)
        sheet.ignoresMouseEvents = true
        try await settle(1.2)
        try await render(sheet, name: name)
        dismiss()
        try await waitUntil { window.attachedSheet == nil }
        try await settle(0.4)
    }

    private func renderGuide(_ window: NSWindow, suffix: String) async throws {
        workspace.selection = .unsorted(unsorted.id)
        workspace.startGuide()
        let guide = try XCTUnwrap(workspace.guide)
        for step in [SetupGuideStep.welcome, .buffer, .createEvent] {
            guide.step = step
            try await snapshot(window, size: NSSize(width: 1320, height: 840), name: "guide-\(step)-\(suffix)")
        }
        guide.isCollapsed = true
        try await snapshot(window, size: NSSize(width: 1320, height: 840), name: "guide-collapsed-\(suffix)")
        guide.close()
        try await settle(0.4)
    }

    // MARK: - Rendering

    private func snapshot(_ window: NSWindow, size: NSSize, name: String) async throws {
        window.setContentSize(size)
        try await settle(1.2)
        try await render(window, name: name)
    }

    private func render(_ window: NSWindow, name: String) async throws {
        let frameView = try XCTUnwrap(window.contentView?.superview)
        frameView.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let url = outputFolder.appendingPathComponent("\(name).png")
        if CGPreflightScreenCaptureAccess() {
            // Another harness capturing at the same moment can make a
            // capture fail; retry before settling for the view-tree
            // fallback, which cannot draw glass.
            for _ in 0..<5 {
                if let image = await captureWindowWithTimeout(window) {
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
                    return
                }
                try await settle(1.0)
            }
        }
        print("snapshot \(name): screen capture unavailable, drew the view tree instead (no glass)")
        let bounds = frameView.bounds
        let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: bounds))
        frameView.cacheDisplay(in: bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    /// ScreenCaptureKit can wedge (a leaked continuation) when several
    /// harnesses capture at once; give up after a few seconds and fall back
    /// to drawing the view tree.
    private func captureWindowWithTimeout(_ window: NSWindow, seconds: Double = 8) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let gate = ResumeGate()
            Task { @MainActor in
                let image = try? await self.captureWindow(window)
                if gate.claim() { continuation.resume(returning: image) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    private func captureWindow(_ window: NSWindow) async throws -> CGImage? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        configuration.width = Int(window.frame.width * scale)
        configuration.height = Int(window.frame.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    private func settle(_ seconds: Double) async throws {
        try await Task.sleep(for: .milliseconds(Int(seconds * 1_000)))
    }

    private func waitUntil(timeout: TimeInterval = 30, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for the harness")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - Sample library (same shape as NativeUISnapshotTests)

    private func makeSampleLibrary() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CameraToolkitBoardSnapshots-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let configuration = AppConfiguration(
            demoRootPath: root.appendingPathComponent("Safety Test").path,
            importSourcePath: root.appendingPathComponent("Card").path,
            archivePath: root.appendingPathComponent("Library/Originals").path,
            bufferPath: root.appendingPathComponent("Drive/Camera Buffer").path,
            cameraLibraryRootPath: root.appendingPathComponent("Library").path,
            catalogDatabasePath: root.appendingPathComponent("catalog.sqlite").path,
            activityLogPath: root.appendingPathComponent("activity.jsonl").path,
            selectedDeviceID: "sony-a7v"
        )
        model = DashboardModel(
            jobs: [],
            configuration: configuration,
            configurationStore: ConfigurationStore(url: root.appendingPathComponent("config.json"))
        )
        workspace = EventsWorkspace(model: model, supportFolder: root.appendingPathComponent("Support", isDirectory: true))

        let folder = root.appendingPathComponent("Drive/Unsorted A7V", isDirectory: true)
        let palette: [(CGFloat, CGFloat, CGFloat)] = [
            (0.95, 0.62, 0.30), (0.25, 0.55, 0.85), (0.35, 0.72, 0.45), (0.80, 0.35, 0.50),
            (0.55, 0.45, 0.85), (0.90, 0.80, 0.35), (0.30, 0.70, 0.75), (0.65, 0.40, 0.30),
        ]
        var index = 1
        for (day, hour) in [("2026:08:26", 10), ("2026:08:26", 17), ("2026:08:27", 9), ("2026:08:28", 14)] {
            for shot in 0..<9 {
                let burst = shot < 4
                let seconds = burst ? shot : shot * 40
                let time = String(format: "%@ %02d:%02d:%02d", day, hour, seconds / 60, seconds % 60)
                let prefix = burst ? String(format: "B%04d_", index / 10 + 1) : ""
                try writeJPEG(
                    folder.appendingPathComponent(String(format: "Transfer 1/%@DSC%05d.JPG", prefix, index)),
                    captured: time,
                    color: palette[(index + shot) % palette.count],
                    portrait: shot % 5 == 3
                )
                index += 1
            }
        }
        unsorted = ConfiguredLocation(role: .importSource, name: "Unsorted A7V", path: folder.path, deviceID: "sony-a7v")
        model.updateConfiguration { $0.configuredLocations.append(self.unsorted) }

        workspace.scan(unsorted)
        try await waitUntil { self.workspace.sources[self.unsorted.id]?.result != nil }
        let result = try XCTUnwrap(workspace.sources[unsorted.id]?.result)

        beachID = try XCTUnwrap(workspace.createEvent(name: "Beach Day", date: day("2026-08-26"), policy: .buffer))
        let sunset = try XCTUnwrap(workspace.createEvent(name: "Sunset", date: day("2026-08-26"), policy: nil, parentEventID: beachID))
        let birthday = try XCTUnwrap(workspace.createEvent(name: "Birthday", date: day("2026-08-27"), policy: .buffer))
        _ = workspace.createEvent(name: "Client Shoot", date: day("2026-08-28"), policy: .archiveOnly)

        let stacks = result.stacks.sorted { $0.captureDate < $1.captureDate }
        let calendar = Calendar.current
        let first = stacks.filter { calendar.component(.day, from: $0.captureDate) == 26 }
        workspace.assign(stackIDs: Set(first.prefix(4).map(\.id)), from: unsorted.id, to: beachID)
        workspace.assign(stackIDs: Set(first.dropFirst(4).prefix(3).map(\.id)), from: unsorted.id, to: sunset)
        let second = stacks.filter { calendar.component(.day, from: $0.captureDate) == 27 }
        workspace.assign(stackIDs: Set(second.prefix(2).map(\.id)), from: unsorted.id, to: birthday)
    }

    private func day(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)!
    }

    private func writeJPEG(_ url: URL, captured: String, color: (CGFloat, CGFloat, CGFloat), portrait: Bool) throws {
        let width = portrait ? 400 : 600
        let height = portrait ? 600 : 400
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let top = CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        let bottom = CGColor(red: color.0 * 0.35, green: color.1 * 0.35, blue: color.2 * 0.45, alpha: 1)
        let gradient = try XCTUnwrap(CGGradient(colorsSpace: space, colors: [top, bottom] as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: CGPoint(x: CGFloat(width), y: 0), options: [])
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
        context.fillEllipse(in: CGRect(x: width / 3, y: height / 3, width: width / 3, height: width / 3))
        let image = try XCTUnwrap(context.makeImage())

        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: captured],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "ILCE-7M5"],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

/// Resumes a continuation exactly once, whichever racer arrives first.
@MainActor
private final class ResumeGate {
    private var claimed = false

    func claim() -> Bool {
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

/// The burst preview overlay on its own, with a real binding, the way a
/// board hosts it.
private struct PreviewHost: View {
    let workspace: EventsWorkspace
    let stacks: [OrganizeStack]
    @State var stackID: String?

    var body: some View {
        StackPreviewOverlay(
            workspace: workspace,
            stacks: stacks,
            stackID: $stackID,
            eventForStack: { workspace.assignedEvent(for: $0).event },
            onAssign: { _, _ in },
            onNewEvent: { _ in },
            onTrashItems: { _ in },
            onSplitItems: { _ in },
            onRotate: { _, _ in }
        )
    }
}

@MainActor
private enum BoardDetailSnapshotWindows {
    static func host(_ view: some View, size: NSSize) -> NSWindow {
        let window = BoardDetailOffscreenWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Preview"
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity))
        window.setContentSize(size)
        window.ignoresMouseEvents = true
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        return window
    }
}

/// Stays off every display and draws with the active-window look without
/// taking focus from the owner's session.
private final class BoardDetailOffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}
