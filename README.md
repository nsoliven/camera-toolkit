# Camera Toolkit Swift

Native macOS rewrite of the personal camera ingest, archive, and Immich control panel.

This is a new private repo. The original Python `camera-toolkit` repo is not moved, deleted, or modified by this project.

## Goals

- Native SwiftUI macOS app with a polished `.app` experience.
- Tested Swift safety core before touching real storage.
- Keep mature external transfer tools in the loop: `rclone`, `immich-go`, and `exiftool` can be launched by the app instead of being reimplemented.
- Never run destructive operations directly from UI state.

## Safety Rules

- No real camera cards, NAS paths, or external drives are used by tests.
- Free-up uses live checksum comparison before quarantine.
- Verified files move into `_Trash/<batch>/`; permanent delete is separate and requires `DELETE`.
- Archive copies use `rclone copy --checksum --immutable`.
- Low-level command builder rejects destructive `rclone` subcommands such as `sync`, `move`, `delete`, and `purge`.

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

The current app uses mock data in the UI. Core tests use temporary directories only.
