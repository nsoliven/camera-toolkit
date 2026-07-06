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
- Archive copies use `rclone copy --checksum --immutable`.
- Low-level command builder rejects destructive `rclone` subcommands such as `sync`, `move`, `delete`, and `purge`.
- Clicking a photo opens an editor working copy by default, so Preview, Photomator, or Topaz Photo do not mutate the source original.
- Immich API keys are stored in macOS Keychain, not in `config.json` or the activity log.

## Current App Surface

- Overview and Import run the safe fake-folder demo.
- Library scans the configured import source for common photo and RAW formats; clicking a row opens a protected working copy in Preview by default.
- Config is the single persistent settings screen for folders, batch defaults, Immich, external editors, and working-copy paths.
- Immich can test the current API connection through ping, version, and current-user endpoints. Uploads remain locked until the transfer path is proven separately.

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

The current app uses fake local folders for transfer demos. Core tests use temporary directories only.
