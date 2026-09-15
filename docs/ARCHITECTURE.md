# Architecture

Camera Toolkit is a Swift Package with two targets:

- `CameraToolkitApp` owns the AppKit lifecycle, SwiftUI views, keyboard commands, preview cache, Keychain access, and window controllers.
- `CameraToolkitCore` owns configuration, scanning, transfer planning, immutable copy behavior, archive organization, event organization, manifests, SQLite catalog access, Immich reads and uploads, and read-only TrueNAS capacity queries.

## Source layout

```text
Sources/
├── CameraToolkitApp/
│   ├── App/            # application lifecycle, main window, Events/Files switch
│   ├── Browser/        # commands, shortcuts, and Finder clipboard support
│   ├── Events/         # event-first organizer: workspace, burst boards, storage strip
│   ├── Model/          # observable application state and async job coordination
│   ├── Preview/        # bounded thumbnail and preview decoding
│   ├── Security/       # macOS Keychain storage
│   ├── Support/        # small app-wide helpers
│   └── Views/
│       ├── Components/
│       ├── Screens/
│       └── Windows/
└── CameraToolkitCore/
    ├── Catalog/        # GRDB schema, sync, inspection, and activity history
    ├── Configuration/  # persisted settings, event policy, and event-name policy
    ├── Import/         # scanning, planning, copy, and archive organization
    ├── Integrations/   # external service clients
    ├── Media/          # media parsing and streaming file hashes
    ├── Models/         # shared value types
    ├── Organize/       # capture times, burst stacks, event storage, drive moves
    └── Safety/         # manifests, quarantine, and local safety simulation
```

Swift Package Manager discovers source files recursively, so these folders describe ownership without adding target-level coupling.

## Event-first organizer

The main window opens on **Events**. The file browser remains available as **File Browser**.

```text
unsorted folder or card
    │ OrganizeScanner: RAW header capture times, sidecar pairing, bursts, days
    ▼
sort into events ── assignments only, undoable
    │ Apply: same drive → DriveMoveService rename + journal
    │        other drive → verified copy through the transfer queue
    ▼
event folder: shared Buffer, or hidden private staging
    │ OrganizedArchiveService + SHA-256
    ▼
NAS library originals ── Take Off Drive: VerifiedRemovalService → drive _Trash
    │ ImmichClient upload + album
    ▼
Immich
```

- `CaptureDateReader` reads EXIF `DateTimeOriginal` from a small TIFF header block for RAW files and through ImageIO for JPEG and HEIC. `CaptureDateCache` remembers results by path, size, and modification time.
- `OrganizeScanner` pairs sidecars and RAW+JPEG twins, reads capture times in parallel, and shifts files without a camera timestamp by the folder's camera-clock offset so video lands on the same day as photos.
- `OrganizeStacker` trusts existing `B0001_` burst prefixes and otherwise chains still frames at most one second apart with neighbouring frame numbers.
- `EventStorageLocations` resolves an assignment's source, Buffer, private staging, and NAS paths. `EventPresenceScanner` checks each place by size.
- `OrganizeAssignmentBuilder` keeps an event's `Card Copy` flat by identifying files by folder plus name, and falls back to the path under the scanned root when names repeat.
- `DriveMoveService` performs exclusive same-volume renames, writes a journal before the first move, supports undo, and prunes folders a move emptied.
- `VerifiedRemovalService` re-hashes drive copies against archived copies and moves them to a same-volume `_Trash` batch only when the whole set matches.
- `DriveEventDiscovery` finds `<year>/<date name>/<camera>/Card Copy` folders already on the drive and adopts them as events without moving files.

`EventsWorkspace` in the app target orchestrates these services and reuses `DashboardModel`'s single-job gate, transfer queue, and activity log.

## Import flow

```text
camera source
    │ metadata preview
    ▼
copy plan ── conflicts stay untouched
    │ immutable copy + checksum
    ▼
temporary buffer
    │ organized archive + checksum manifest
    ▼
photo library originals
```

`ArchivePlanner` produces metadata or checksum-backed plans. `LocalTransferService` performs no-overwrite copies. `OrganizedArchiveService` maps verified source records into event/camera/media folders and writes the final manifest.

## Catalog and configuration

`AppConfiguration` is JSON-encoded local state. It stores selected locations, events with their storage policy, file assignments, integration endpoints, and policy—not API keys. `CatalogStore` mirrors those relationships into SQLite for fast cross-drive event browsing. Catalog writes are serialized through GRDB, and the in-app inspector accepts bounded read-only queries only.

Integration API keys are stored separately by `KeychainSecretStore`. `ImmichClient` performs connection checks, checksum-presence reads, streamed multipart uploads, and album creation. `TrueNASClient` uses the secure JSON-RPC WebSocket API, optionally pins a self-signed TLS certificate, resolves a mounted SMB share to its deepest matching dataset, and reads dataset/pool capacity without changing NAS state.

## Responsiveness and memory

- Folder scanning and copy work run outside the main actor and report coalesced progress updates.
- Thumbnail requests are asynchronous, deduplicated, and cached with a fixed cost limit.
- RAW decoding reads the embedded JPEG instead of decoding the full sensor payload.
- Preview images are downsampled to a requested pixel budget before becoming `NSImage` instances.
- Capture-time reads touch a bounded header block and are cached on disk.
- Immich uploads stream file bytes through a bound stream pair instead of loading clips into memory.
- SQLite sync is debounced and runs at utility priority.

The test suite includes large-file hashing and decoded-image bounds so changes to these paths remain measurable.
