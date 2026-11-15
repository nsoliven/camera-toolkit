# Configuration

Camera Toolkit starts with safe folders under its Application Support directory. Replace those paths in **Camera Toolkit → Settings** before using real media.

## Saved locations

- **Camera sources** are read-only card or staging folders.
- **Buffer drives** hold temporary verified copies, Photomator work, and exports.
- **Library targets** hold permanent originals.

Multiple locations can be saved for each role. Selecting a different source does not discard saved events or assignments from other sources.

## Local state

The app stores configuration, activity history, and the SQLite photo list under the current user's Application Support directory unless those paths are changed in Settings.

- `config.json` holds settings. Events, photo assignments, display rotations, and burst splits live in the photo list (`catalog.sqlite`), together with people and face labels. The first launch after upgrading moves them out of an older `config.json` and keeps a `config.pre-sqlite-<date>.json` copy of the original.
- `Backups/` holds verified backup sets (`ctbackup-<date>.*`): the photo list, its face labels as JSON, `config.json`, and a manifest. The same sets are copied to the Settings backup folder on the NAS when it is mounted. Settings shows the last backup and offers **Back Up Now** and **Restore Face Labels…**.
- Restore the photo list and `config.json` from the same backup set; the app refuses to save when they do not belong together.

Immich and TrueNAS API keys are stored in macOS Keychain under the Camera Toolkit service. They are not written into JSON, SQLite, logs, or manifests.

## TrueNAS capacity

macOS can report a synthetic filesystem capacity for an SMB mount. Camera Toolkit labels that value **SMB estimate** instead of treating it as authoritative.

For exact capacity, add the TrueNAS HTTPS server URL and a read-only API key in Settings. The app uses the mounted Library root's SMB share name to find its backing dataset automatically. You can enter a full dataset name such as `pool/photos` when automatic matching is unavailable. Self-signed servers require explicitly trusting the current certificate; Camera Toolkit saves only its SHA-256 fingerprint and rejects later certificate changes.

The sidebar then shows dataset free space, while its help text also identifies the underlying pool, pool free space, and health. No NAS address, dataset, username, or key is part of the repository defaults.

## Immich

`immichLibraryID` picks the external library that reads the NAS root; empty leaves Immich alone. `immichCarriesAlbumsAcrossRenames` keeps renamed files in their albums. Each event's album policy can be:

- `none`
- `event`
- `custom`

Private events get no album unless opted in. See `IMMICH.md`.
