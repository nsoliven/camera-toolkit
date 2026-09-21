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
    ├── Faces/          # on-device face detection, embeddings, match/group index
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
- `OrganizeStacker` trusts existing `B0001_` burst prefixes and otherwise chains still frames with neighbouring frame numbers: gaps up to `BurstGroupingConfiguration.automaticGapSeconds` (1.0 s) link directly, gaps through `maximumGapSeconds` (2.0 s) link only when `BurstVisualLinker` cleared the pair by Apple Vision feature-print distance, and longer gaps never link. The linker fingerprints only those recovery-band pairs, decoding the embedded JPEG preview for RAW files, and reports a "Comparing burst frames" scan phase. Visual recovery, the gap limit, and the distance limit are `UserDefaults` options in Settings; disabling recovery returns to pure capture-time grouping.
- `EventStorageLocations` resolves an assignment's source, Buffer, private staging, and NAS paths. `EventPresenceScanner` checks each place by size.
- Events nest: `SavedCameraEvent.parentEventID` links a subevent to its parent, and `EventHierarchy` walks the chain (root-first ancestors, `displayName` "Parent / Child" breadcrumbs, `flattened` sidebar rows, recursive `resolvedPolicy`). A subevent's folder lives inside its parent's dated folder under the root ancestor's year — `<root>/<root year>/<parent>/<child>/<device>/Card Copy` — so every buffer, private-staging, and archive path is a chain resolution, and a `nil` storage policy inherits the nearest ancestor's setting (top-level default: shared Buffer). A missing parent or a link loop ends the chain, so such an event simply behaves as top-level.
- `OrganizeAssignmentBuilder` keeps an event's `Card Copy` flat by identifying files by folder plus name, and falls back to the path under the scanned root when names repeat.
- `DriveMoveService` performs exclusive same-volume renames, writes a journal before the first move, supports undo, and prunes folders a move emptied.
- `VerifiedRemovalService` re-hashes drive copies against archived copies and moves them to a same-volume `_Trash` batch only when the whole set matches.
- `MediaTrashService` moves unsorted files into `.Camera Toolkit/_Trash/<batch>` on the volume each file lives on (or the configured removed-files root for non-volume paths), writing a `manifest.json` of original absolute paths before the first rename. `listBatches` reads manifests across trash roots, tolerating legacy manifest-less batches, and `restore` renames entries back without overwriting. Settings → Trash lists batches, restores them, and empties every listed `_Trash` root in one background job after the `DELETE` confirmation. The burst review overlay offers "Move to Trash" for the selected frames via `EventsWorkspace.trashItems` on unsorted boards.
- `OrganizeStacker.stacks` also takes persisted `BurstSplit` overrides: each split pulls its member frames out of whatever group they landed in (prefix-trusted bursts included) and pins them into their own stack. Splits live in `AppConfiguration.burstSplits`, so rescans and event refreshes keep the frames apart; members that left the scan are ignored.
- `StackPreviewOverlay` reviews a burst on the shared `InteractivePreviewCanvas` (Preview/): click toggles zoom at the pointer, drag pans, pinch or `+`/`-`/`0`/`⌘1` adjust zoom. The filmstrip selects Finder-style via `FilmstripSelection` — click anchors one frame, ⇧-click ranges from the anchor, ⌘-click pins or unpins single frames, and ⇧←/⇧→ grow or shrink the range's open edge while plain arrows still step the previewed frame. Right-click (or Delete) trashes the selected frames; "Move to New Burst" splits them off. Frames decode at the 2400 px tile bucket; zooming past ~1.5× requests the 4800 px bucket, which swaps in at a matching image scale so the zoom level and pan offset stay exact. The header also shows each item's folder relative to the scan root, and grid tiles carry it as a tooltip. Preview waits are bounded: a tile/preview decode releases its waiter after 15 s (the operation keeps running so a late finish still caches), and the canvas replaces the spinner with the failure UI after 20 s regardless — a stalled NAS read can never pin a "Reading…" spinner forever.
- `DriveEventDiscovery` finds `<year>/<date name>/<camera>/Card Copy` folders already on the drive and adopts them as events without moving files. A dated folder inside an event folder is a subevent root, not a camera folder, so discovery recurses; adoption matches saved events by their full relative folder path and materializes missing ancestor events, preserving the on-disk parent linkage as `parentEventID`.
- Renaming an event (`EventsWorkspace.renameEvent`) moves its on-disk folder for every storage policy where one exists; subevent folders travel inside it, and adopted assignments for the event and its descendants get their `sourceRootPath` prefixes rewritten to the new folder.
- Search is a lowercase-contains filter over already-scanned data (`OrganizeSearch` in Events/): the sidebar's `.searchable` field matches unsorted locations by name/path, events by breadcrumb title (a parent-name hit keeps the subevent row), and discovered drive events by name; the organize board's header field (⌘F, `BrowserCommand.find`) filters `visibleStacks` by file name, burst label, origin subfolder, or assigned event, composing with Hide Sorted.

`EventsWorkspace` in the app target orchestrates these services and reuses `DashboardModel`'s single-job gate, transfer queue, and activity log.

## Face index

Faces exist to tag events: `event.people` is the unique set of named (roster) people detected on an event's photos, surfaced as chips on event headers and names in the sidebar. The pipeline is fully on-device and lives in `CameraToolkitCore/Faces/`:

```text
unsorted media (LOW scans stills only; MED/HIGH also sample video frames)
    │ LOW:  VisionFaceDetector — Vision rectangles+landmarks on a bounded
    │        decode, min-size floor ~64px
    │ MED:  SCRFDDetector — SCRFD CoreML letterboxed to 640, ~40px floor,
    │        stills + sparse video keyframes (one frame per ~30s, capped)
    │ HIGH: SCRFDDetector at 640 and 960 canvas scales, ~30px floor,
    │        stills + ~1fps video frames
    ▼
FaceAligner: 5-point similarity warp to 112×112 (box-crop fallback)
    │ ArcFaceEmbedder: single frozen identity model → 512-d L2-normalized vector
    ▼
FaceIndexService: cosine vs roster templates → proposed, else greedy
    cosine clustering into unnamed "Other" groups; video faces dedup by
    embedding cosine so a clip records distinct appearances, not seconds
    ▼
FaceIndexStore: faces/people/face_templates/face_photos tables in the catalog
```

- The identity model is a fixed, generated `.mlpackage` under `Application Support/CameraToolkit/Models`, produced once per machine by `scripts/convert-arcface.sh` — the only Python anywhere; nothing ships or re-trains. Embedding vectors are keyed by a fixed model name and never mix spaces. The MED/HIGH detector comes from the same model pack via `scripts/convert-scrfd.sh`: one fixed-shape package per input size (`det_10g.mlpackage` at 640, `det_10g_960.mlpackage` at 960), decoded in-app by anchors at strides 8/16/32 with cross-scale NMS.
- Scan grades are ordered (`none < low < med < high < xhigh`); a photo whose recorded grade covers the requested mode is skipped, keyed by file identity (name + size + mtime) so replugging a drive or moving a file never re-runs detection. The stamped grade is what actually ran — an XHIGH request runs the HIGH pipeline and stamps `.high` so a later XHIGH implementation still re-scans.
- Detection follows the scanner's burst grouping: a burst of stills decodes up to three spread frames (all of a small burst; first/middle/last beyond that) and stamps the un-sampled members covered at the same grade — near-identical frames repeat the same faces, and covered frames keep any faces a lower grade already found. Bare item lists without an `OrganizeScanResult` scan every still.
- MED/HIGH refuse to run without the detector package installed rather than silently falling back to LOW detection; the scan sheet gates Medium/High on its presence.
- Confirmed faces are frozen: photo re-scans never delete or reclassify them, and overlapping fresh detections are dropped instead of duplicating.
- The People window (View → People, ⌘⌥P) offers the three review queues — roster, new groups, unsure — with name/merge/junk/confirm actions. Naming a group promotes it to the roster, confirms its faces, and pins distinct-photo members as match templates; merges keep unconfirmed faces reviewable as proposals. Re-match re-evaluates stored vectors against the gallery on CPU only.
- Face work runs inside `runAsyncJob` like other file jobs; FAST on uses every core, FAST off is two workers — never changes models or floors. Quality is the mode, Fast is how hard the Mac works. The same `FaceScanSheet` opens from an unsorted location or an event board (or its sidebar row's menu): an event scan runs `FaceIndexService` on the event board's own stacks — the reachable `bestLocalPath` copies — against the same catalog, so faces found there or in Unsorted share one index and one set of skip rules. `EventBoardView` and the sidebar read `eventPeople` through `EventsWorkspace`, cached per faces-revision so rows share one catalog pass; board search matches a roster person name against a stack's files through `rosterNamesByFileKey`, so typing a person keeps both the event and the bursts they appear in.

Connectivity is refreshed explicitly instead of relying on Finder: `EventsWorkspace.refreshConnectivity()` re-checks each configured location with cheap mount-table and folder-stat probes, bumps `connectivityRevision` so views that call `isConnected` re-render, re-runs `DriveEventDiscovery` and the cached per-event presence summaries, and rescans only unsorted sources whose earlier scan failed — plus sources on a volume that just mounted. Healthy cached scan results are never rescanned by a connectivity refresh. `NSWorkspace` `didMount`/`didUnmount` observers (registered once via `observeVolumeChanges()`, called from `EventsWorkspace.start()` and `AppShell.onAppear`) drive it automatically through a ~0.75 s trailing debounce that remembers mounted volume URLs, so a flapping hub collapses into one refresh pass; sidebar rows, the setup guide's place cards, the Settings "Where Things Live" rows, and the event storage strip each offer a Refresh/Check Again control that calls it. Refresh never mounts shares itself — the configuration stores local paths and service URLs, not network share URLs, so there is no mount URL to retry. `PhotoBrowserView` listens for the same notifications to refresh capacity dots and reload the current folder when its drive comes back.

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

`AppConfiguration` is JSON-encoded local state. It stores selected locations, events with their storage policy, file assignments, integration endpoints, and policy—not API keys. `DashboardModel.updateConfiguration` coalesces mutations into a trailing-debounced JSON write (~250 ms) and flushes synchronously on `applicationWillTerminate`, so bursts cost one write and the last state is always durable. `CatalogStore` mirrors those relationships into SQLite for fast cross-drive event browsing — its bootstrap also owns the face-index tables (`face_photos`, `faces`, `people`, `face_templates`) that `FaceIndexStore` reads and writes. Catalog writes are serialized through GRDB, and the in-app inspector accepts bounded read-only queries only.

Integration API keys are stored separately by `KeychainSecretStore`. `ImmichClient` performs connection checks, checksum-presence reads, streamed multipart uploads, and album creation. `TrueNASClient` uses the secure JSON-RPC WebSocket API, optionally pins a self-signed TLS certificate, resolves a mounted SMB share to its deepest matching dataset, and reads dataset/pool capacity without changing NAS state.

## Responsiveness and memory

- Folder scanning and copy work run outside the main actor and report coalesced progress updates.
- Thumbnail requests are asynchronous, deduplicated per path and size bucket while a decode is in flight, and cached with a fixed cost limit.
- RAW decoding reads the embedded JPEG instead of decoding the full sensor payload.
- Preview images are downsampled to a requested pixel budget before becoming `NSImage` instances.
- Capture-time reads touch a bounded header block and are cached on disk.
- Immich uploads stream file bytes through a bound stream pair instead of loading clips into memory.
- SQLite sync is debounced and runs at utility priority.
- A machine-readable debug stream (`DebugLog`, Core/Diagnostics) appends one JSON line per event to `~/Library/Logs/CameraToolkit/debug.jsonl` — tile/preview decode start/finish/timeout, video probes, trash and job finishes — with duration, outcome, extension, size, and a sanitized error (`NSError` domain+code, never a path beyond the basename). Writes queue on a utility serial queue, failures are swallowed, and the file trims its oldest half in place past 4 MB so a `tail -F` survives.

The test suite includes large-file hashing and decoded-image bounds so changes to these paths remain measurable.
