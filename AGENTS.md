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

## Verification

- Run the full Swift test suite for code changes.
- For packaging changes, compare the installed executable hash with the packaged executable and verify the app launches from the intended bundle.
- For catalog maintenance, separately prove configuration counts, catalog counts, source presence, buffer presence, and checksum results. Do not collapse those into a single success claim.
