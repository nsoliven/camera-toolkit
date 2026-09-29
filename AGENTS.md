# Camera Toolkit Agent Guidelines

## Scope

This repository is the canonical source for the native Swift Camera Toolkit app and its non-destructive camera-media workflow.

## Commands

Run from the repository root:

```sh
swift build
swift test
scripts/package-app.sh
```

Use `scripts/package-app.sh --install` only when the user asks to refresh the installed app.

## Media Safety

- Never delete, unlink, truncate, overwrite, or replace original photos, videos, RAW files, XMP sidecars, Photomator edits, catalogs, or configuration unless the user explicitly identifies the exact data and destructive action.
- For reorganizations, copy first, checksum-verify every indexed file, and preserve the source. Do not use `rsync --delete`, `--remove-source-files`, or an equivalent destructive option without separate explicit authorization.
- A successful copy command is not verification. Run an independent checksum comparison and report any unavailable drive, short read, mismatch, conflict, or excluded metadata sidecar.
- Treat `._*`, `.DS_Store`, generated thumbnails, build output, and temporary candidate catalogs as reproducible artifacts. Keep them clearly distinguishable from source media.
- Never claim a disconnected or offline volume is verified. Resume from the last proven boundary after it is mounted again.

## Configuration And Catalog

- `config.json` is the durable settings source. Events, assignments, display rotations, and burst splits live only in the SQLite catalog once it has been migrated (`CatalogStateStore`); before that, `CatalogStore` mirrors them from `config.json`. Do not invent rows independently when the app's models can generate them.
- Stop the app (which checkpoints the WAL) before copying or replacing `catalog.sqlite`; a copy of the main file alone can miss recent writes. Prefer `CatalogBackupService`, which uses the SQLite backup API.
- Treat files under the user's Camera Toolkit Application Support folder as live state. Create timestamped backups and stop concurrent app writes before atomically replacing configuration or catalog files.
- Build and validate candidate files separately before installation. Require JSON decode success, `PRAGMA integrity_check = ok`, zero foreign-key violations, and exact expected event and assignment counts.
- Preserve unrelated events and assignments during scoped reconciliation. Replace only roots explicitly included in the approved plan.
- Do not commit personal paths, event names, media inventories, local databases, API keys, tokens, or other machine-specific state to this public repository.

## Implementation Rules

- Keep filesystem scanning, copying, hashing, path validation, catalog writes, and safety policy in `CameraToolkitCore`; UI targets should orchestrate those APIs rather than duplicate them.
- Keep copy operations immutable: identical destinations may be skipped, conflicts must remain untouched, and partial files must never be presented as complete.
- Keep long scans and hashes off the main actor, stream large files through bounded buffers, and expose progress for user-visible operations.
- Preserve the existing Finder-style browser and Photomator-opening behavior when changing catalog or thumbnail features.
- Preserve unrelated dirty or untracked files. Stage and commit only files in the requested scope.

## Undo History

- Every user-visible action that can be taken back registers one `UndoEntry` in `EventsWorkspace.undoHistory` (`EventsWorkspace+Undo.swift`) when it finishes; ⌘Z always takes the newest, ⌘⇧Z redoes. Do not add a second undo stack.
- Undo and Redo of anything that touches files run as jobs, reuse the action's refusals, and never replace or delete a file: a moved file is renamed back, a trashed file is restored to the path its manifest records, NAS copies follow through journaled exclusive renames.
- Entries replay only what they recorded (journal id, Trash batch, NAS batch ids, catalog rows, face row snapshots). Persist new kinds through `UndoHistoryStore`; keep memory-only ones to `UndoAction.session`.
- A journal's Undo or Redo is marked (`pendingStep`) before its first rename and closed (`DriveMoveService.finishStep`) only after the catalog and the NAS copies followed; a launch replays whatever is unfinished. NAS renames, Undo and Redo of one queue folder run under one lock and re-read their batch from disk.
- With a drive unplugged or wiped, a step acts on the NAS copies and the catalog only when every file it names has a NAS copy that followed it (`driveLagging` records that the drive is one step behind); otherwise it changes nothing and says which volume it needs.
- Remove from Source, Take Off Drive (its copies wait in Trash), Empty Trash, Sync to NAS, Immich upload and Settings are deliberately outside Undo; their confirmations say so.

## Verification

- Run the full Swift test suite for code changes.
- For packaging changes, compare the installed executable hash with the packaged executable and verify the app launches from the intended bundle.
- For catalog maintenance, separately prove configuration counts, catalog counts, source presence, buffer presence, and checksum results. Do not collapse those into a single success claim.
