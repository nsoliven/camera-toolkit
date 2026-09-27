# Architecture

Camera Toolkit is a Swift Package with two targets:

- `CameraToolkitApp` owns the AppKit lifecycle, SwiftUI views, keyboard commands, preview cache, Keychain access, and window controllers.
- `CameraToolkitCore` owns configuration, scanning, transfer planning, immutable copy behavior, archive organization, event organization, manifests, SQLite catalog access, Immich reads and uploads, and read-only TrueNAS capacity queries.

## Source layout

```text
Sources/
├── CameraToolkitApp/
│   ├── App/            # application lifecycle and main window
│   ├── Browser/        # board commands and keyboard shortcuts
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

The main window is the **Events** organizer.

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
- `EventStorageLocations` resolves an assignment's source, Buffer, private staging, and NAS paths. `EventPresenceScanner` checks each place by size; a drive copy missing from `Originals` is looked for in the legacy `Card Copy` (flagged `driveIsLegacyLayout`), so an unmigrated drive keeps showing its files, and consumers pair the found `driveRootPath` with the relative path instead of recomputing a root.
- `EventStorageLocations.originalsRoot` is where one camera's files for an event live on a drive: `<event folder>/Originals/<Camera>`, with `<Camera>` the device's display name (`OrganizedArchiveLayout.cameraFolder`, the same names `CameraCatalog` prints on camera chips). `editedRoot` is `<event folder>/Edited`, whose first-level folders are edit tags. `legacyCardCopyRoot` is the layout `Originals` replaced (`<event folder>/<device folder>/Card Copy`); only discovery, the presence fallback, and the layout migration read it.
- Events nest: `SavedCameraEvent.parentEventID` links a subevent to its parent, and `EventHierarchy` walks the chain (root-first ancestors, `displayName` "Parent / Child" breadcrumbs, `flattened` sidebar rows, recursive `resolvedPolicy`). A subevent's folder lives inside its parent's dated folder under the root ancestor's year — `<root>/<root year>/<parent>/<child>/Originals/<Camera>` — so every buffer, private-staging, and archive path is a chain resolution, and a `nil` storage policy inherits the nearest ancestor's setting (top-level default: shared Buffer). A missing parent or a link loop ends the chain, so such an event simply behaves as top-level.
- The NAS mirrors the drive layout. `EventStorageLocations.nasRoot` (`AppConfiguration.archiveLayoutRootPath`; empty derives it from `cameraLibraryRootPath`, dropping a trailing `Originals`, and a configuration written before the setting existed gets the derived value on load) holds `<year>/<event>/Originals/<Camera>/<same subpath>` and `Edited/…` for every storage policy — a private event is kept out of the shared Buffer and Immich, never hidden on the NAS. `archiveURL`, `nasEventFolder`, `nasOriginalsRoot`, `nasEditedRoot`, and `nasMirrorURL(forDrivePath:)` resolve it; `OrganizedArchiveLayout.mirrorRelativePath` keeps a file's subfolders, so same-named files never collide. The legacy archive layout (`<library>/Originals/<year>/<event>/<device>/RAW|JPEG|Video|Camera Support/<flat name>`, `legacyArchiveURL`) is read as a presence fallback (`archiveIsLegacyLayout`) until the NAS layout migration moves an event.
- `OrganizeAssignmentBuilder` keeps an event's `Originals/<Camera>` flat by identifying files by folder plus name, and falls back to the path under the scanned root when names repeat.
- `DriveMoveService` performs exclusive same-volume renames, writes a journal before the first move, supports undo, and prunes folders a move emptied.
- `VerifiedRemovalService` re-hashes drive copies against archived copies and moves them to a same-volume `_Trash` batch only when the whole set matches.
- `MediaTrashService` moves unsorted files into `.Camera Toolkit/_Trash/<batch>` on the volume each file lives on (or the configured removed-files root for non-volume paths), writing a `manifest.json` of original absolute paths before the first rename. `listBatches` reads manifests across trash roots, tolerating legacy manifest-less batches, and `restore` renames entries back without overwriting. Settings → Trash lists batches, restores them, and empties every listed `_Trash` root in one background job after the `DELETE` confirmation. The burst review overlay offers "Move to Trash" for the selected frames via `EventsWorkspace.trashItems` on unsorted boards.
- `OrganizeStacker.stacks` also takes persisted `BurstSplit` overrides: each split pulls its member frames out of whatever group they landed in (prefix-trusted bursts included) and pins them into their own stack. Splits live in `AppConfiguration.burstSplits`, so rescans and event refreshes keep the frames apart; members that left the scan are ignored.
- `StackPreviewOverlay` reviews a burst on the shared `InteractivePreviewCanvas` (Preview/): click toggles zoom at the pointer, drag pans, pinch or `+`/`-`/`0`/`⌘1` adjust zoom. The filmstrip selects Finder-style via `FilmstripSelection` — click anchors one frame, ⇧-click ranges from the anchor, ⌘-click pins or unpins single frames, and ⇧←/⇧→ grow or shrink the range's open edge while plain arrows still step the previewed frame. Right-click (or Delete) trashes the selected frames; "Move to New Burst" splits them off. Frames decode at the 2400 px tile bucket; zooming past ~1.5× requests the 4800 px bucket, which swaps in at a matching image scale so the zoom level and pan offset stay exact. The header also shows each item's folder relative to the scan root, and grid tiles carry it as a tooltip. Preview waits are bounded: a tile/preview decode releases its waiter after 15 s (the operation keeps running so a late finish still caches), and the canvas replaces the spinner with the failure UI after 20 s regardless — a stalled NAS read can never pin a "Reading…" spinner forever.
- `DriveEventDiscovery` finds `<year>/<date name>/Originals/<Camera>` folders — and, during the transition, legacy `<year>/<date name>/<camera>/Card Copy` folders — already on the drive and adopts them as events without moving files. A dated folder inside an event folder is a subevent root, not a camera folder, so discovery recurses; `Edited` is never read as a camera. Adoption matches saved events by their full relative folder path and materializes missing ancestor events, preserving the on-disk parent linkage as `parentEventID`. `cameraFolders(driveRoot:)` lists every camera folder with its layout; the sidebar uses it to say how many still wait for the layout migration.
- Edit tags: every first-level folder under an event's `Edited/` is a tag. `EditTagLinker` reads the family's `Edited/` folders (both drives, `readdir`, junk skipped) and links each edit to the board's originals by file-name stem (`DSC06778-edit.jpg` → `DSC06778.*`, burst prefixes, `(N)`, `-edit`/`_Edited`/` copy` suffixes ignored), falling back to capture time and camera. `EventsWorkspace.refreshEditTags` runs it off the main actor when an event board's stacks land; tiles and list rows wear "Edited · <Tag>", and the filter builder's Edit tag row ("is any of" / "is none of") narrows event boards — the sidebar ignores that row.
- Renaming an event (`EventsWorkspace.renameEvent`) moves its on-disk folder for every storage policy where one exists; subevent folders travel inside it, and adopted assignments for the event and its descendants get their `sourceRootPath` prefixes rewritten to the new folder.
- Search is a lowercase-contains filter over already-scanned data (`OrganizeSearch` in Events/): the sidebar's `.searchable` field matches unsorted locations by name/path, events by breadcrumb title (a parent-name hit keeps the subevent row), and discovered drive events by name; the organize board's header field (⌘F, `BrowserCommand.find`) filters `visibleStacks` by file name, burst label, origin subfolder, or assigned event, composing with Hide Sorted. The board field also opens a filter popover (`OrganizeSearchBar` driving `OrganizeSearchFilter`, held on `EventsWorkspace.search` so all surfaces share it) with People (roster members and unnamed groups the face index saw on the board's stacks, via `FaceIndexStore.peopleByFileKey`), Date (inclusive day range over each stack's capture interval), Event (assigned events plus a "Not Sorted Yet" bucket), and Media (still/RAW/video) chips; picks inside a facet are OR, the facets and the text needle AND together; event boards scope the Event facet to the board's family — `visibleEventStacks` applies picks naming the event or a descendant (an "is none of" subevent pick hides that whole branch) and ignores the rest, so a filter left over from Unsorted can't blank the board. One header chip per direct subevent toggles that "is none of" pick (solid in its `EventPalette` color, an outline while it filters), and each tile and list row wears its owning subevent's tag in the same color. People picks also narrow the sidebar's Events list through `eventPeople`, so an event only stays when a picked roster person appears on its assigned files.

`EventsWorkspace` in the app target orchestrates these services and reuses `DashboardModel`'s single-job gate, transfer queue, and activity log.

## Sync to NAS

`Core/NASSync/` is the one-way Buffer → NAS copy (`EventsWorkspace.syncToNAS` for an event and its subevents, `syncAllToNAS` from File → Sync All Events to NAS), run as a Jobs entry through `runBackgroundJob`:

- `NASSyncPlanner` lists each event's `Originals/` and `Edited/` on its policy drive (then the other drive, for copies left there) with `DirectoryListing` — `getattrlistbulk`, one call per batch of entries, so an SMB share answers per folder instead of per file. `._*`, `.DS_Store`, symlinks, and entries outside `Originals`/`Edited`/known subevent folders (a drive still in the `Card Copy` layout) are reported, never synced. A file whose legacy archive copy (its flattened `RAW|JPEG|Video|…` name, same size) is already on the NAS is held back (`inLegacyLayout`) so an unmigrated event is not duplicated; two drive files that flatten to one legacy name are both copied.
- `NASSyncService` copies each file to the same relative path under `EventStorageLocations.nasRoot`: verified earlier at the same size and drive mtime → skipped; already on the NAS → both hashed, equal is verified, different is a conflict that is never overwritten; missing → streamed through one 4 MiB buffer into an exclusively created temporary, `F_FULLFSYNC`/`fsync`, re-read from the NAS with `F_NOCACHE`, and only a SHA-256 match is renamed in (`NASFileIO.renameExclusive`: `RENAME_EXCL`, or check-then-rename where SMB answers `ENOTSUP`). A failure is recorded and skipped; the job stops early only when the NAS disappears. Progress reports bytes of work (copy + verify read) with a smoothed ETA and Copied / Already on NAS / Conflicts / Failed counters; the per-file report is written to `NAS Sync/` beside the catalog.
- `NASSyncStore` keeps per-file results in the catalog's `nas_sync_files` table (NAS root + case-folded relative path → size, drive mtime, SHA-256, state, verified date). Presence reads it (`EventAssetPresence.archiveVerifiedAt`), the NAS slot says "On NAS ✓ verified <date>", and Take Off Drive only offers files whose mirror copy a sync verified (`archiveIsTrusted`; a legacy-layout copy never counts) — and still re-hashes each pair before moving anything.
- When the NAS is not mounted, the board header and NAS slot offer Connect to NAS…, which opens the configured `nasSMBURL` with `NSWorkspace`.

## Layout migration

`Core/Organize/LayoutMigration/` moves a drive from the legacy `<event>/<device>/Card Copy/…` layout to `<event>/Originals/<Camera>/…` with same-volume renames only. It runs from the app binary's hidden command line, with the app quit:

```text
CameraToolkit --migrate-layout --dry-run [--json <plan.json>]      # read-only
CameraToolkit --migrate-layout --execute --plan <plan.json>        # exactly that reviewed plan
CameraToolkit --migrate-layout --resume <journal.json>             # after an interruption
CameraToolkit --migrate-layout --undo <journal.json>               # full undo
    [--support-dir <folder>]   # or CAMERA_TOOLKIT_SUPPORT_DIR; reads <folder>/config.json and <folder>/catalog.sqlite only
```

- `LayoutMigrationPlanner` (read-only) walks the Buffer and private staging with `readdir` — `FileManager` hides `._` AppleDouble files — and plans every file under each legacy `Card Copy`: sidecars, `.photo-edit`, `._` twins (a file's twin follows its file, a folder's twin moves to the folder's new twin, a twin of a twin chains), unknown files, `.DS_Store`. A taken destination, on disk or claimed by another legacy folder that maps to the same camera, renames the whole base-name group to `NAME (N).EXT` through `KeepBothNaming`. Anything outside `Card Copy` is left in place and listed; symlinks and other-volume files are refused; skeleton event folders with no media are reported as odd and not touched. It derives every catalog rewrite from the moves and fingerprints the source files (size, inode, mtime), each legacy folder's listing, and a digest of the catalog rows it reads.
- Path-keyed stores and how each is handled: `event_assets` rows adopted from a `Card Copy` get the new root (their id — `CatalogStore.eventAssetID` — changes, and `event_asset_locations` / `immich_assets` follow); rows with an implied drive copy change only when the file is renamed `(N)`; `face_photos.path_key/path/file_name` and `faces.photo_id` are re-keyed for photos at moved paths, and rows at stale paths follow a renamed file's identity; `display_orientations` (name + size + mtime) gets a copy for renamed files; `burst_splits.member_path_keys` are rewritten; `capture-dates.json` keys move with their file; trash `manifest.json` entries that name a legacy `Card Copy` are rewritten so a restore lands in `Originals`; Apply journals recorded before the migration become non-undoable through a `layout-migration.barrier` file in `Move Journals` (`DriveMoveService` refuses them — undoing one would swap assignments back while the files stay put). A queued transfer blocks the plan.
- `LayoutMigrationExecutor` refuses while Camera Toolkit runs (`NSRunningApplication` plus a process-table scan) or while another migration holds the lock, and when anything fingerprinted changed. It then takes a verified, pinned `CatalogBackupService` backup, writes the journal (`Application Support/CameraToolkit/Layout Migrations/<stamp>-<plan>/` with the plan copy, `journal.json`, and an append-only `moves.log`), renames with `renameExclusive` (never over a file), and proves each folder — every file at its destination with its size and inode, gone from its source — before the next. One catalog transaction with deferred foreign keys applies every rewrite and must pass `integrity_check`, no new foreign-key violations, exact row counts, and every confirmed face on a moved photo still attached to an existing file, or it rolls back. Emptied legacy folders are removed with `rmdir` only.
- Resume trusts the filesystem: each planned file is at its source or its destination, by inode; the catalog's `app_state.layoutMigration` marker shows whether the commit landed. Undo refuses when the catalog changed after the migration, takes a safety backup, restores the pre-migration backup through the SQLite backup API, restores the cache and manifests, removes the barrier, recreates the removed folders, and renames every file back.


## NAS layout migration

`Core/NASLayoutMigration/` moves events archived in the legacy NAS layout (`<library>/Originals/<year>/<event>/<camera>/RAW|JPEG|Video|Camera Support|Photos|Saved Clips|Audio/<flat names>`) into the mirror layout with server-side renames on the share — no byte is copied. It is driven by a reviewed mapping and never guesses an event's name or date:

```text
CameraToolkit --migrate-nas-layout --dry-run --mapping <mapping.json> [--json <plan.json>]   # read-only
CameraToolkit --migrate-nas-layout --execute --plan <plan.json> [--verify-sample <n>]
CameraToolkit --migrate-nas-layout --resume <journal.json>
CameraToolkit --migrate-nas-layout --undo <journal.json>
    [--support-dir <folder>]
```

- `NASLayoutMapping` (`camera-toolkit-nas-layout-mapping`, version 1) lists `{ source, destination, eventID? }` per event folder: `source` under `legacyRoot` (default `<library>/Originals`), `destination` under `mirrorRoot` (default the NAS mirror root). A subevent is its own entry. An optional `eventID` names the catalog event whose assignments say which subfolder under `Originals/<Camera>` each flattened file had; unique matches (and same-named sidecars) go back there, ambiguous names stay flat, and a destination that is not the event's own mirror folder is noted.
- `NASLayoutMigrationPlanner` lists folders with `DirectoryListing` (one `getattrlistbulk` pass per folder; 4,750 files over SMB plan in a few seconds). Media folders flatten into `<destination>/Originals/<Camera>/` keeping any deeper subfolders; camera names normalize through `NASCameraNames` ("Sony-A7V" → "Sony A7V", "DJI Osmo 360"/"Osmo-360" → "Osmo 360", "DJI Nano" → "Osmo Nano", "DJI-Mini-2" → "DJI Mini 2", "Action-6" → "Osmo Action 6"; unknown names are kept and reported); other camera subfolders are kept under `Originals/<Camera>/`; `Originals/` and `Edited/` already in the event keep their inner paths. A taken destination — a file already synced there, or two legacy folders normalizing to one camera — renames the whole base-name group to `NAME (N).EXT` with its sidecars and `._` twins. Unmapped dated subfolders, `.DS_Store`, and orphan `._` files stay; a folder that cannot be listed is reported and skipped. Catalog rows that name a moved NAS path are planned: `face_photos`/`faces` re-keys, `nas_sync_files` relative paths, rotation copies for `(N)` renames, burst-split keys; assignments pointing into the legacy folders block the plan.
- `NASLayoutMigrationExecutor` refuses while Camera Toolkit runs or another migration holds the lock, re-plans the recorded mapping and refuses when anything differs (listings, sizes, mtimes, catalog digest), takes a verified pinned catalog backup, writes the journal (`<support>/NAS Layout Migrations/<stamp>-<plan>/`), then per event renames exclusively (`NASFileIO.renameExclusive`: `RENAME_EXCL`, check-then-rename on `ENOTSUP`), hashes `--verify-sample` files per event before and after their rename (a mismatch stops the run), and re-lists every destination and source folder to prove each file is there with its size and mtime (file ids are not stable over SMB). A rename that fails is recorded and skipped; the run stops before the catalog until a resume moves it. One catalog transaction applies the rewrites with the same checks as the Buffer migration, then `capture-dates.json` is re-keyed and emptied legacy folders are removed with `rmdir`. Resume trusts the filesystem (size + mtime at source or destination) and the catalog marker (`app_state.nasLayoutMigration`); undo restores the catalog from the pre-migration backup (refusing if it changed since), recreates removed folders, and renames every file back.

## Face index

Faces exist to tag events: `event.people` is the unique set of named (roster) people detected on an event's photos, surfaced as chips on event headers and names in the sidebar. The pipeline is fully on-device and lives in `CameraToolkitCore/Faces/`; the ML itself is the reference `insightface` package in a Python sidecar, never re-implemented in Swift (`docs/FACE-PIPELINE.md` is the contract):

```text
unsorted media (LOW scans stills only; MED/HIGH also sample video frames)
    │ FaceImageDecoder: bounded, orientation-applied decode (embedded JPEG for RAW)
    ▼
FaceSidecarPool → face_sidecar.py (insightface buffalo_l, onnxruntime CoreML)
    │ SCRFD-10G detect + 5 landmarks at 640 (HIGH +960, XHIGH +1024)
    │ norm_crop 5-point warp to 112×112 → ArcFace w600k_r50 → 512-d unit vector
    │ returns box, det_score, embedding, quality (pre-norm), aligned crop
    ▼
FaceIndexService: native min-size floor per grade; cosine vs roster templates
    → files onto the Inbox "looks like" row for that approved person;
    leftovers grouped by average linkage (mean cosine ≥ 0.40)
    behind a quality gate (det ≥ 0.7, ≥ 48 decoded px) and a minimum of 3
    faces per new "Person N"; video faces dedup by embedding cosine
    ▼
FaceIndexStore: faces/people/face_templates/face_rejections/face_photos in the catalog
```

- The engine is installed once per Mac by `scripts/setup-face-sidecar.sh` into `Application Support/CameraToolkit/face-sidecar` (pinned `insightface` + `onnxruntime` in a private Python 3.12, the `buffalo_l` pack, a warm CoreML cache). Every face row and scanned photo carries `FaceEngine.identifier`; rows from another engine are ignored and re-scanned, so embedding spaces never mix.
- Scan grades are ordered (`none < low < med < high < xhigh`); a photo whose recorded grade covers the requested mode is skipped, keyed by file identity (name + size + mtime) so replugging a drive or moving a file never re-runs detection. The stamped grade is what actually ran — an XHIGH request runs the HIGH pipeline and stamps `.high` so a later XHIGH implementation still re-scans.
- Detection follows the scanner's burst grouping: a burst of stills decodes up to three spread frames (all of a small burst; first/middle/last beyond that) and stamps the un-sampled members covered at the same grade — near-identical frames repeat the same faces, and covered frames keep any faces a lower grade already found. Bare item lists without an `OrganizeScanResult` scan every still.
- Every grade refuses to run without the sidecar installed; the scan sheet and People window say which script to run.
- Confirmed faces keep their label through re-scans: a fresh detection overlapping one refreshes its box, vector, quality, and crop in place (this is also how a named gallery migrates to a new engine) — it is never deleted, reclassified, or duplicated.
- The People window (View → People, ⌘⌥P) is a two-list review surface: Approved (people the user named, confirmed, or tagged) and Inbox (automatic "Person N" clusters plus "looks like" rows holding faces the matcher filed near an approved person). A scan never attaches faces to an approved person — classification lands in the Inbox. Approving a row promotes it, confirms only its own faces, and pins distinct-photo members as match templates; merging an Inbox row into an approved person is the other explicit approval and confirms the moved faces. Inbox faces read strongest-match first so the doubtful ones sit at the bottom. Re-match re-evaluates stored vectors on CPU only and files matches into the Inbox, never onto approved people. Event chips, the People filter, and board person-name search count approved people with confirmed faces only.
- Face work runs inside `runAsyncJob` like other file jobs; FAST on uses every core, FAST off is two workers — never changes models or floors. Quality is the mode, Fast is how hard the Mac works. The same `FaceScanSheet` opens from an unsorted location or an event board (or its sidebar row's menu): an event scan runs `FaceIndexService` on the event board's own stacks — the reachable `bestLocalPath` copies — against the same catalog, so faces found there or in Unsorted share one index and one set of skip rules. `EventBoardView` and the sidebar read `eventPeople` through `EventsWorkspace`, cached per faces-revision so rows share one catalog pass; board search matches an approved person's name against a stack's files through `personNamesByFileKey`, so typing a person keeps both the event and the bursts they appear in.

Connectivity is refreshed explicitly instead of relying on Finder: `EventsWorkspace.refreshConnectivity()` re-checks each configured location with cheap mount-table and folder-stat probes, bumps `connectivityRevision` so views that call `isConnected` re-render, re-runs `DriveEventDiscovery` and the cached per-event presence summaries, and rescans only unsorted sources whose earlier scan failed — plus sources on a volume that just mounted. Healthy cached scan results are never rescanned by a connectivity refresh. `NSWorkspace` `didMount`/`didUnmount` observers (registered once via `observeVolumeChanges()`, called from `EventsWorkspace.start()` and `AppShell.onAppear`) drive it automatically through a ~0.75 s trailing debounce that remembers mounted volume URLs, so a flapping hub collapses into one refresh pass; sidebar rows, the setup guide's place cards, the Settings "Where Things Live" rows, and the event storage strip each offer a Refresh/Check Again control that calls it. Refresh never mounts shares itself — the configuration stores local paths and service URLs, not network share URLs, so there is no mount URL to retry.

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

`AppConfiguration` is the in-memory state the UI works on: selected locations, events with their storage policy, file assignments, display rotations, burst splits, integration endpoints, and policy—not API keys. Its durable homes are split:

- **Settings** live in `config.json`. `DashboardModel.updateConfiguration` coalesces mutations into a trailing-debounced write (~250 ms) and flushes synchronously on `applicationWillTerminate`.
- **Events, assignments, display rotations, and burst splits** (`CatalogOwnedState`) live only in the SQLite catalog. `CatalogStateWriter` writes the rows that changed since its last successful write — one transaction per save, off the main actor — through `CatalogStateStore`. A failed save writes nothing, keeps the unsaved state in `Backups/unsaved-events-*.json`, and retries the whole difference with the next change.
- The first launch after the upgrade migrates a legacy `config.json` into the catalog (`CatalogStateStartup`): a pinned, verified backup first, then a byte-verified `config.pre-sqlite-<stamp>.json` copy, then one transaction that validates exact counts, an exact read-back, `integrity_check`, and no new foreign-key violations before it commits. Any mismatch rolls back and the session stays on the old `config.json` path. An unreadable config, or a settings-only config over a catalog that was never migrated, starts in a suspended mode that writes nothing durable.

`CatalogStore.bootstrap` keeps the schema, settings mirror, and face-index tables (`face_photos`, `faces`, `people`, `face_templates`, `face_rejections`) that `FaceIndexStore` reads and writes; once the catalog owns the event state it no longer mirrors events from a configuration snapshot. Every catalog reader and writer shares one connection per file (`CatalogDatabase`: WAL on a local volume, `synchronous = NORMAL`, 5 s busy timeout, foreign keys on), checkpointed at quit. The in-app inspector accepts bounded read-only queries only.

`CatalogBackupService` backs the catalog up with the SQLite online backup API — at launch when the newest backup is over a day old, after a burst of catalog writes, and from Settings — into `Application Support/CameraToolkit/Backups` and the configured NAS folder. Every set holds the catalog snapshot, the face labels (`FaceLabelExport`), `config.json`, and a manifest, and is verified before it counts. Retention keeps 7 daily and 4 weekly sets and only ever deletes files a manifest of its own lists.

Integration API keys are stored separately by `KeychainSecretStore`. `ImmichClient` performs connection checks, checksum-presence reads, streamed multipart uploads, and album creation. `TrueNASClient` uses the secure JSON-RPC WebSocket API, optionally pins a self-signed TLS certificate, resolves a mounted SMB share to its deepest matching dataset, and reads dataset/pool capacity without changing NAS state.

## Responsiveness and memory

- Folder scanning and copy work run outside the main actor and report coalesced progress updates.
- Thumbnail requests are asynchronous, deduplicated per path and size bucket while a decode is in flight, and cached with a fixed cost limit.
- RAW decoding reads the embedded JPEG instead of decoding the full sensor payload.
- Preview images are downsampled to a requested pixel budget before becoming `NSImage` instances.
- Capture-time reads touch a bounded header block and are cached on disk.
- Immich uploads stream file bytes through a bound stream pair instead of loading clips into memory.
- SQLite sync is debounced and runs at utility priority; event and assignment saves write only changed rows on a background writer.
- A machine-readable debug stream (`DebugLog`, Core/Diagnostics) appends one JSON line per event to `~/Library/Logs/CameraToolkit/debug.jsonl` — tile/preview decode start/finish/timeout, video probes, trash and job finishes — with duration, outcome, extension, size, and a sanitized error (`NSError` domain+code, never a path beyond the basename). Writes queue on a utility serial queue, failures are swallowed, and the file trims its oldest half in place past 4 MB so a `tail -F` survives.

The test suite includes large-file hashing and decoded-image bounds so changes to these paths remain measurable.
