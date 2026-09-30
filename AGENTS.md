# Camera Toolkit Agent Guidelines

## Scope

This repository is the canonical source for the native Swift Camera Toolkit app and its non-destructive camera-media workflow.

## Never Store Personal Information

This repository is public. Nothing personal goes into it — not in code, tests, fixtures, docs, comments, scripts, commit messages, or branch names.

- Never write real people's names (the owner, family, friends, anyone shown in photos), real event or trip names, real places tied to the owner's life, real file names from the owner's library, media inventories, or face/person data.
- Never write machine- or network-specific details: user home paths, volume or drive names, NAS share names and server paths, hostnames, IP addresses, usernames, SSH hosts, email addresses, API keys, or tokens.
- Briefs, bug reports, screenshots, and logs will often contain real names and paths. Treat them as private context: reproduce the shape of the problem with neutral fixtures instead — people such as "Alex" and "Sam", events such as "Trip 2026", "Beach Day", or "Family Party", volumes such as `/Volumes/Buffer` and `/Volumes/nas_share`, and generated file names such as `DSC00001.ARW`.
- Personal helper scripts that hard-code the owner's paths or events stay outside the repository, or untracked and git-ignored.
- Before committing, run `scripts/audit-public-repo.sh`. It also checks the owner's private term list when one exists outside the repository; never copy that list into the repository.
- If personal information is found in the repository or its history, stop and tell the user. Removing it requires rewriting history, which only the user can approve.

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
- Do not commit local databases, configuration, or any other machine-specific state (see Never Store Personal Information).

## Implementation Rules

- Keep filesystem scanning, copying, hashing, path validation, catalog writes, and safety policy in `CameraToolkitCore`; UI targets should orchestrate those APIs rather than duplicate them.
- Keep copy operations immutable: identical destinations may be skipped, conflicts must remain untouched, and partial files must never be presented as complete.
- Keep long scans and hashes off the main actor, stream large files through bounded buffers, and expose progress for user-visible operations.
- Preserve the existing Finder-style browser and Photomator-opening behavior when changing catalog or thumbnail features.
- Preserve unrelated dirty or untracked files. Stage and commit only files in the requested scope.

## Board Rendering

- Tiles and rows never touch the filesystem or the network on the main actor: a tile reads the in-memory thumbnail cache while it draws, and stats, redirects and decodes run on `TileImageLoader`'s queues. Thumbnails of NAS photos are also kept in `ThumbnailDiskCache` (under Caches, rebuildable, size-capped) — never write them into the library.
- Keep the tile board a flat `LazyVStack` of fixed-height rows and give every list element exactly one view. Do not put nested `ForEach`/`Section` content per tile, `ViewThatFits`, or a per-tile `ProgressView` in the scrolling path — each was measured to cost more the deeper the board is scrolled.
- Read workspace state where it is drawn (a tile's or row's own body, a region's own view), not in the board's body, so a change re-runs the views that show it and not the board. The event board's header, storage strip, toolbar title, status caption and bottom bar are each their own view with their own reads; keep `EventBoardView.body` to what decides what the grid draws. Long derived answers a header only decorates with (cameras, people) come from the deferred `shown...`/`...ForDisplay` accessors, with `EventChipsWatcher` noticing when they went stale.
- A tile depends on its own files and stack, not on the workspace as a whole. Ask `tileAssignment(for:)`, `badge(for:in:)`, `isStackSelected`/`isStackFocused` and `editTags(for:in:)` — each observed by key through `KeyedObservation` (`fileFacts`, `stackFacts`, `boardFacts`) — never `assignment(for:)`, `selectedStackIDs` or a revision counter from a tile or row. Whoever changes one of those answers must `touch` the keys it changed, or `touchAll()` when it cannot list them (a sweep, an index rebuild).
- Views read the configuration through its facets — `DashboardModel.eventsForDisplay`, `locationsForDisplay`, `orientationsForDisplay` and their revisions, `pathsRevision`, `assignmentCountSnapshot` — not through `model.configuration`, which every catalog change rewrites (a move rewrote it three times and redrew every view that had read any part of it). An event's last-used stamp is drawn nowhere: do not compare it (`SavedCameraEvent.sameAsDrawn`) and do not let it move a revision.
- Tiles, list rows and tile rows are equatable values (`BoardTileCell`, `BoardRowCell`, `BoardTileRowView`, `BoardListEntryView`) so a grid update that changes a few of them updates a few. Keep everything they draw in `==`, and keep handlers reachable through `BoardTileActions` (closures never decide the picture).
- A Move to Event landing (`landMove`) is cut into slices, each drawn before the next starts (`RunLoopTurn.afterCommit`): the catalog and counts, the tiles' new paths, the storage strip and its rows, the follow-ups. The job stays running — and holds the job gate — until the last slice, so nothing starts on a half-landed move. A write that lands a lot at once belongs in its own slice; do not put two of them in one turn.
- After changing the board, the bars or thumbnail loading, run `BoardScrollPerfTests` (opt-in, needs an awake display; see the header of that file) and `HostedMoveResponsivenessTests` with `CT_PERF_BUDGETS=1` in a release build, and report the machine's load average with the numbers. The move harness selects a stack, then waits for the scroll to it and the lazy stack's row building to finish before it clicks, as a person's own frames would.

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
