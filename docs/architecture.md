# Architecture

The app is split into two targets:

- `CameraToolkitCore`: transfer planning, checksum verification, manifests, quarantine, command construction, Immich API connection checks, editor working-copy creation, and job state.
- `CameraToolkitApp`: native SwiftUI macOS interface, persistent config, Keychain secret storage, Finder-style folder picking, and AppKit editor launching.

## Core Ownership

The UI does not decide whether a file is safe to delete or quarantine. That lives in tested core types:

- `ArchivePlanner`: compares source and destination listings.
- `LocalCheckService`: hash-compares two local trees for tests and preflight behavior.
- `FreeUpService`: converts a fresh check report into quarantine actions.
- `ManifestStore`: builds and verifies SHA-256 manifests.
- `RcloneCommandBuilder`: constructs only allowlisted `rclone` commands.
- `ImmichClient`: normalizes server URLs and tests current Immich API connectivity without uploading.
- `EditorWorkingCopyService`: copies source photos into a working folder before external editors open them.
- `JobRunner`: serialized actor for long-running job state.

## External Tools

The Swift app intentionally does not reimplement `rclone` or photo editors. Reimplementing transfer engines, SMB edge behavior, retry semantics, and checksum comparison would make the rewrite less stable. Swift owns orchestration and safety gates; mature tools do the heavy I/O work.

Preview is the default photo opener. Photomator and Topaz Photo are selectable external editors. The app opens a copied file under the configured working-copy folder, not the source original.

## Testing Boundary

The test suite uses temporary local directories and fake media files. It must stay green before any real volume integration happens.
