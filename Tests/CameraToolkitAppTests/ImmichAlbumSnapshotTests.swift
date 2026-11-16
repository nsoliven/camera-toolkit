import AppKit
import CameraToolkitCore
import SwiftUI
@testable import CameraToolkitApp
import XCTest

/// Renders the Immich album pieces off-screen with made-up events and albums:
/// the event header chip, the sidebar marker, the Settings pairs list and the
/// Send to Immich progress, in light and dark. Runs only when
/// `CT_SNAPSHOT_OUT` names an output folder.
@MainActor
final class ImmichAlbumSnapshotTests: XCTestCase {
    func testRenderImmichAlbumViews() throws {
        guard let out = ProcessInfo.processInfo.environment["CT_SNAPSHOT_OUT"] else {
            throw XCTSkip("Snapshot harness runs only with CT_SNAPSHOT_OUT set.")
        }
        let folder = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let chips = VStack(alignment: .leading, spacing: 12) {
            ImmichAlbumChip(info: ImmichAlbumChipInfo(albumName: "Beach Day", inAlbum: 248, toAdd: 12, notOnNAS: 4, canOpen: true), onOpen: {}, onSend: {}) { Button("New Album Named After the Event") {} }
            ImmichAlbumChip(info: ImmichAlbumChipInfo(albumName: "Trip 2026", inAlbum: 1_310, toAdd: 0, notOnNAS: 0, canOpen: true), onOpen: {}, onSend: {}) { Button("No Album") {} }
            ImmichAlbumChip(info: ImmichAlbumChipInfo(albumName: nil, inAlbum: nil, toAdd: 0, notOnNAS: 0, canOpen: false), onOpen: {}, onSend: {}) { Button("No Album") {} }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)

        let sidebar = List {
            Section("Events") {
                EventSidebarRow(name: "Beach Day", color: .orange, isPrivate: false, fileCount: 260, hasImmichAlbum: true, depth: 0, isDropTarget: false, help: "")
                EventSidebarRow(name: "Trip 2026", color: .blue, isPrivate: false, fileCount: 1_310, hasImmichAlbum: true, depth: 0, isDropTarget: false, help: "")
                EventSidebarRow(name: "Day Two", color: .blue, isPrivate: false, fileCount: 402, nasPending: 18, hasImmichAlbum: false, depth: 1, isDropTarget: false, help: "")
                EventSidebarRow(name: "Family Party", color: .purple, isPrivate: true, fileCount: 76, hasImmichAlbum: false, depth: 0, isDropTarget: false, help: "")
                EventSidebarRow(name: "Concert Night", color: .green, isPrivate: false, fileCount: 95, hasImmichAlbum: true, depth: 0, isDropTarget: false, help: "")
            }
        }
        .listStyle(.sidebar)

        let pairs = Form {
            Section("Immich Albums") {
                ImmichPairsListView(
                    pairs: [
                        ImmichPairRow(eventID: UUID(), eventName: "Beach Day", albumName: "Beach Day", inAlbum: 248, albumCount: 248),
                        ImmichPairRow(eventID: UUID(), eventName: "Concert Night", albumName: "Best of the Year", inAlbum: 40, albumCount: 312),
                        ImmichPairRow(eventID: UUID(), eventName: "Trip 2026", albumName: "Trip 2026 · 2026-05-04", inAlbum: 1_310, albumCount: 1_310)
                    ],
                    unpaired: [
                        ImmichUnpairedRow(albumID: "a", albumName: "Screenshots", assetCount: 1_187, reason: ImmichPairingReason.noMatch.text),
                        ImmichUnpairedRow(albumID: "b", albumName: "Favorites", assetCount: 64, reason: ImmichPairingReason.mixed(topShare: 0.45).text),
                        ImmichUnpairedRow(albumID: "c", albumName: "Weekend", assetCount: 30, reason: ImmichPairingReason.tie.text),
                        ImmichUnpairedRow(albumID: "d", albumName: "Family Party", assetCount: 22, reason: ImmichPairingReason.privateEvent.text)
                    ],
                    onUnpair: { _ in }
                )
            }
        }
        .formStyle(.grouped)

        let results = [
            ImmichSendResult(id: UUID(), eventName: "Beach Day", inImmich: 256, albumName: "Beach Day", inAlbum: 256, notOnNAS: 4, waiting: 0),
            ImmichSendResult(id: UUID(), eventName: "Trip 2026", inImmich: 1_310, albumName: "Trip 2026", inAlbum: 1_310, notOnNAS: 0, waiting: 6)
        ]
        let progress = VStack(alignment: .leading, spacing: 18) {
            ImmichSendProgressView(state: ImmichSendState(phase: .scanning(waiting: 18), eventCount: 2))
            Divider()
            ImmichSendProgressView(state: ImmichSendState(phase: .adding(count: 40, album: "Beach Day"), eventCount: 2))
            Divider()
            ImmichSendProgressView(state: ImmichSendState(phase: .done, eventCount: 2, results: results, addedToAlbums: 52))
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"
            try render(AnyView(chips), size: NSSize(width: 760, height: 150), appearance: appearance, to: folder.appendingPathComponent("immich-chip-\(suffix).png"))
            try render(AnyView(sidebar), size: NSSize(width: 280, height: 260), appearance: appearance, to: folder.appendingPathComponent("immich-sidebar-\(suffix).png"))
            try render(AnyView(pairs), size: NSSize(width: 620, height: 470), appearance: appearance, to: folder.appendingPathComponent("immich-pairs-\(suffix).png"))
            try render(AnyView(progress), size: NSSize(width: 520, height: 420), appearance: appearance, to: folder.appendingPathComponent("immich-send-\(suffix).png"))
        }
    }

    private func render(_ view: AnyView, size: NSSize, appearance: NSAppearance.Name, to url: URL, settle: TimeInterval = 0.5) throws {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: appearance)
        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
        host.layoutSubtreeIfNeeded()
        host.display()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        window.orderOut(nil)
    }
}
