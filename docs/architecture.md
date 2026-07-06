# Architecture

The app is split into two targets:

- `CameraToolkitCore`: transfer planning, checksum verification, manifests, quarantine, command construction, and job state.
- `CameraToolkitApp`: native SwiftUI macOS interface backed by mock data until real workflows are wired in.

## Core Ownership

The UI does not decide whether a file is safe to delete or quarantine. That lives in tested core types:

- `ArchivePlanner`: compares source and destination listings.
- `LocalCheckService`: hash-compares two local trees for tests and preflight behavior.
- `FreeUpService`: converts a fresh check report into quarantine actions.
- `ManifestStore`: builds and verifies SHA-256 manifests.
- `RcloneCommandBuilder`: constructs only allowlisted `rclone` commands.
- `JobRunner`: serialized actor for long-running job state.

## External Tools

The Swift app intentionally does not reimplement `rclone`. Reimplementing transfer engines, SMB edge behavior, retry semantics, and checksum comparison would make the rewrite less stable. Swift owns orchestration and safety gates; mature tools do the heavy I/O work.

## Testing Boundary

The test suite uses temporary local directories and fake media files. It must stay green before any real volume integration happens.
