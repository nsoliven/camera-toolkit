# Safety model

Camera Toolkit treats source media as read-only during normal browsing and transfer work, and separates fast planning from verified writes. Permanently freeing camera space is a distinct, confirmation-gated exception after checksum verification.

## Guarantees

- Scanning and previewing do not modify camera-source files.
- A metadata preview compares relative paths, sizes, and modification dates; its results are never labeled verified.
- A verified copy reads file bytes, calculates checksums, and refuses to replace a conflicting destination.
- Archive operations accept only a verified buffer state, preserve the source copy, and write a checksum manifest.
- **Free Up Camera** is available only for an explicit transfer set whose Buffer copies are all verified. It requires typing `REMOVE`, hashes every source file and Buffer copy again, verifies the files did not change during that pass, and validates the entire set before removing the first source file.
- A missing, changed, differently sized, or checksum-mismatched file blocks source removal for the whole set.
- Source removal is permanent because putting files in an external volume's Trash would not free camera space. The verified Buffer copies are never modified by this action.
- Storage speed tests never write to configured camera/card sources. Writable Buffer and library tests use one unique hidden temporary file, require free-space headroom, flush it before measuring read speed, and remove it after success, cancellation, or failure.
- Buffer-to-archive cleanup quarantines matching Buffer files under `_Trash/<batch>` on the same volume. It does not immediately delete them.
- Emptying quarantine requires an explicit confirmation token and rejects paths outside an `_Trash` hierarchy.

## Failure behavior

A missing destination is treated as a new copy. A same-name file with different bytes is a conflict. Read, write, or verification errors remain visible in the job result and never become a successful state. Source cleanup validates all requested files before removal begins; a removal-system error can still stop a final deletion pass after an earlier file was removed, and that partial result remains visible in the persistent transfer queue and activity log.

## Testing boundary

Tests create isolated temporary folders and synthetic media bytes. They do not enumerate or write to mounted camera cards, removable drives, network shares, or a user's photo library.

Before changing transfer or cleanup behavior, add a regression test that proves conflict refusal and byte preservation.
