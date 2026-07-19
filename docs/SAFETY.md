# Safety model

Camera Toolkit treats source media as read-only and separates fast planning from verified writes.

## Guarantees

- Scanning and previewing do not modify camera-source files.
- A metadata preview compares relative paths, sizes, and modification dates; its results are never labeled verified.
- A verified copy reads file bytes, calculates checksums, and refuses to replace a conflicting destination.
- Archive operations accept only a verified buffer state, preserve the source copy, and write a checksum manifest.
- Cleanup quarantines matching files under `_Trash/<batch>` on the same volume. It does not immediately delete them.
- Emptying quarantine requires an explicit confirmation token and rejects paths outside an `_Trash` hierarchy.

## Failure behavior

A missing destination is treated as a new copy. A same-name file with different bytes is a conflict. Read, write, or verification errors remain visible in the job result and never become a successful state.

## Testing boundary

Tests create isolated temporary folders and synthetic media bytes. They do not enumerate or write to mounted camera cards, removable drives, network shares, or a user's photo library.

Before changing transfer or cleanup behavior, add a regression test that proves conflict refusal and byte preservation.
