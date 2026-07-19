# Camera Toolkit Swift

Native macOS rewrite of the personal camera ingest, archive, and Immich control panel.

This is a new private repo. The original Python `camera-toolkit` repo is not moved, deleted, or modified by this project.

## Goals

- Native SwiftUI macOS app with a polished `.app` experience.
- Tested Swift safety core before touching real storage.
- Keep mature external transfer tools in the loop: `rclone`, Immich's API, and external photo editors can be launched or called by the app instead of being reimplemented.
- Never run destructive operations directly from UI state.

## Safety Rules

- No real camera cards, NAS paths, or external drives are used by tests.
- Free-up uses live checksum comparison before quarantine.
- Verified files move into `_Trash/<batch>/`; permanent delete is separate and requires `DELETE`.
- Event preview reads paths and file sizes only, so it can show what will move without reading every RAW byte.
- `Copy + Verify` performs SHA-256 checks and never treats a metadata-only preview as verification.
- Archive copies are immutable and checksum-verified before Camera Toolkit marks them safe.
- Low-level command builder rejects destructive `rclone` subcommands such as `sync`, `move`, `delete`, and `purge`.
- Camera cards are never modified by preview, copy, or archive actions.
- Opening a Library photo creates an editor working copy so Photomator does not mutate the source original.
- Immich API keys are stored in macOS Keychain, not in `config.json` or the activity log.

## Current App Surface

- Files is the camera workspace. It browses mounted cards, Crucial, NAS locations, and ordinary folders without sending the user through Finder.
- Sony ARW thumbnails and the larger selection/Space-bar previews come from JPEGs embedded by the camera. This works for A7 V Compressed RAW 2 even when macOS Quick Look cannot decode that RAW variant.
- Selecting one photo opens a larger preview pane with a draggable divider. Space opens the resizable preview window; arrow keys move through a multi-file selection.
- Double-clicking a file uses its macOS default application. Photomator is the app's default protected editor.
- Saved events can be reused across camera cards. Select files, choose or create an event, and click **Assign Selected**; only those files are included in that event's copy.
- **Event Library** (`Option-Command-E`) shows every assignment across its source card/folder, Crucial buffer, and NAS original, with direct file links plus storage-only/per-photo Immich routing.
- **Photo List SQL Inspector** (`Shift-Command-I`) uses the GRDB Swift package to browse SQLite tables, schema SQL, and bounded read-only queries inside the app.
- **Preview Event** is metadata-only and fast. **Copy Event + Verify** is deliberately slower because it reads the selected bytes and performs the safety checksum.
- Config is the single persistent settings screen for folders, batch defaults, Immich, external editors, and working-copy paths.
- Immich can test the current API connection through ping, version, and current-user endpoints. Uploads remain locked until the transfer path is proven separately.
- Immich presence checks stream SHA-1 hashes in bounded chunks and call the stable bulk-upload-check endpoint; the event policy can use no album, an event album, or a custom album without implying that an upload has happened.
- Locked workflow plans show the configured rclone copy/check commands, exiftool metadata read command, Immich `/api/assets` upload endpoint, quarantine target, and editor checkout path. Preview Copy compares the configured source against the configured archive without moving bytes.
- `Command-B` toggles the sidebar. `Command-R` refreshes config, activity log, library scan, copy plan, and Immich connection status when credentials are configured.

## Event Folder Layout

Creating an event makes a stable workspace on Crucial. The same saved event remains available when a different camera or card is selected:

```text
Camera Buffer/<year>/<event>/
├── Sony A7V/Card Copy/     # verified copy of assigned camera files
├── Photomator/             # Photomator project/working files
└── Exports/
    ├── Masters/            # full-resolution final files
    ├── Web/                # web-sized exports
    └── Social/             # social-sized exports
```

Permanent NAS originals are organized separately by event, camera, and media type. Camera Toolkit provides **Open Photomator Folder** and **Open Exports** buttons so these destinations do not have to be remembered.

## Build

```sh
swift test
swift build
```

Package a local `.app` bundle:

```sh
scripts/package-app.sh
open dist/CameraToolkit.app
```

The current app is not demo-only: it reads persistent config, previews real planned paths, and runs Immich connection checks. Byte-moving workflows remain locked, with safety tests available for disposable checks. Core tests use temporary directories only.
