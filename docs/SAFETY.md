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

## Event organizer

- Sorting a photo into an event only records the assignment. No file moves until **Apply**, which first shows the exact plan.
- Apply moves a file only when its source and its event folder are on the same drive. The move is a rename: file bytes are never rewritten. A destination that already exists is left untouched and the source stays where it was. A cross-drive request is refused by the move service and handled as a checksum-verified copy instead, which leaves the original in place.
- Every Apply, move between events, and return to Unsorted writes a journal before its first rename. **Undo** renames the completed moves back and restores the event assignments they changed.
- Folders emptied by a move are removed only when they contain nothing but Finder metadata, and never at or above the Unsorted, Buffer, or private staging root. This keeps a private event's folder name from lingering in the shared Buffer.
- Private events never enter the shared Buffer. Their originals wait in a hidden `.Camera Toolkit/Private` folder on the same drive, or a folder chosen in Settings. Hidden folders are not access control; anyone who shows hidden files or reads the drive elsewhere can open them.
- **Take Off Drive** is available only for files that already have a NAS copy. It requires typing `REMOVE`, re-hashes every drive copy and its NAS copy, validates the whole set before the first move, and then moves the drive copies into `.Camera Toolkit/_Trash/<batch>` on the same drive. Nothing is deleted until the removed-files folder is emptied in Settings with a separate `DELETE` confirmation.
- **Move to Trash** — from the unsorted board, an event board, or a single frame in the burst preview — first asks for confirmation, then renames each file into `.Camera Toolkit/_Trash/<batch>` on the same volume the file lives on — card, external drive, or NAS — so the trash travels with the media. Every file is validated before the first rename, moves are exclusive same-device renames that never overwrite, and a file that cannot reach its own volume's Trash is skipped rather than copied. Each batch folder carries a `manifest.json` recording every file's absolute origin, so batches listed in Settings → Trash can be restored even after a drive is remounted. Restoring never overwrites: a file already back in place keeps the trashed copy in the batch.
- **Free Up Source** re-hashes each card or unsorted-folder original against its drive copy and permanently removes the source originals only when the whole set matches, exactly like Free Up Camera. It is never offered for files whose only copy is the drive copy.
- Adopting event folders already on the drive only records assignments. No file moves.
- Immich upload sends only files in events marked **Send to Immich**, skips content Immich already has by SHA-1, and keeps the API key in Keychain.
- Face scans are read-only on media: detection and embedding read photo bytes (or their embedded previews) and — at Medium and High — decoded video frames; they write only to the local catalog database. Naming, merging, and junking groups change catalog rows — a junked group's face rows are deleted from the index, but no photo, sidecar, or catalog event is ever touched. Confirmed faces are frozen and are never reclassified or removed by later scans. Clearing the face index removes the `face_photos`, `faces`, `people`, and `face_templates` rows only — every other catalog table and every file on disk is untouched.

## Failure behavior

A missing destination is treated as a new copy. A same-name file with different bytes is a conflict. Read, write, or verification errors remain visible in the job result and never become a successful state. Source cleanup validates all requested files before removal begins; a removal-system error can still stop a final deletion pass after an earlier file was removed, and that partial result remains visible in the persistent transfer queue and activity log.

## Testing boundary

Tests create isolated temporary folders and synthetic media bytes. They do not enumerate or write to mounted camera cards, removable drives, network shares, or a user's photo library. Immich tests use a recording transport and never contact a server.

Before changing transfer or cleanup behavior, add a regression test that proves conflict refusal and byte preservation.
