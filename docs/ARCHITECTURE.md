# Architecture

Camera Toolkit is a Swift Package with two targets:

- `CameraToolkitApp` owns the AppKit lifecycle, SwiftUI views, keyboard commands, preview cache, Keychain access, and window controllers.
- `CameraToolkitCore` owns configuration, scanning, transfer planning, immutable copy behavior, archive organization, manifests, SQLite catalog access, and Immich reads.

## Source layout

```text
Sources/
├── CameraToolkitApp/
│   ├── App/            # application lifecycle and main window
│   ├── Browser/        # commands, shortcuts, and Finder clipboard support
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
    ├── Configuration/  # persisted settings and event-name policy
    ├── Import/         # scanning, planning, copy, and archive organization
    ├── Integrations/   # external service clients
    ├── Media/          # media parsing and streaming file hashes
    ├── Models/         # shared value types
    └── Safety/         # manifests, quarantine, and local safety simulation
```

Swift Package Manager discovers source files recursively, so these folders describe ownership without adding target-level coupling.

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

`AppConfiguration` is JSON-encoded local state. It stores selected locations, events, file assignments, and Immich policy—not API keys. `CatalogStore` mirrors those relationships into SQLite for fast cross-drive event browsing. Catalog writes are serialized through GRDB, and the in-app inspector accepts bounded read-only queries only.

The Immich API key is stored separately by `KeychainSecretStore`. `ImmichClient` currently performs connection and checksum-presence reads; it has no upload method.

## Responsiveness and memory

- Folder scanning and copy work run outside the main actor and report coalesced progress updates.
- Thumbnail requests are asynchronous, deduplicated, and cached with a fixed cost limit.
- RAW decoding reads the embedded JPEG instead of decoding the full sensor payload.
- Preview images are downsampled to a requested pixel budget before becoming `NSImage` instances.
- SQLite sync is debounced and runs at utility priority.

The test suite includes large-file hashing and decoded-image bounds so changes to these paths remain measurable.
