# Configuration

Camera Toolkit starts with safe folders under its Application Support directory. Replace those paths in **Camera Toolkit → Settings** before using real media.

## Saved locations

- **Camera sources** are read-only card or staging folders.
- **Buffer drives** hold temporary verified copies, Photomator work, and exports.
- **Library targets** hold permanent originals.

Multiple locations can be saved for each role. Selecting a different source does not discard saved events or assignments from other sources.

## Local state

The app stores configuration, activity history, and the SQLite photo list under the current user's Application Support directory unless those paths are changed in Settings.

Immich API keys are stored in macOS Keychain under the Camera Toolkit service. They are not written into JSON, SQLite, logs, or manifests.

## Immich policy

Each event can be marked for storage only or for a future Immich upload. Album policy can be:

- no album;
- an album named after the event; or
- a custom album name.

These settings describe intent only. The current app can test the server and check checksum presence, but it does not upload assets or create albums.
