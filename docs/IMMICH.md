# Immich: external library mode

Immich reads the NAS library directly as a read-only **external library**. Camera Toolkit never uploads to it. Uploading would create a second copy of every file, and Immich's checksum for an external-library asset is a hash of its *path*, not its content, so a content check can never recognise one.

## What the app does

| When | What |
|---|---|
| Sync to NAS copied something, or NAS renames ran | Asks Immich to scan the chosen library, then compares paths after 15 s, 1 min, 5 min and 15 min, stopping once nothing is waiting |
| **Check** on an event's Immich slot | Scans and compares now |

It matches each catalog file to an asset by its path under the library's import folder, which must be the NAS root the app syncs to (`<year>/<event>/Originals/<Camera>/…`). Case and Unicode spelling are ignored. The answer is stored in `immich_assets` and shown on the event:

| Status | Meaning |
|---|---|
| `present` | Immich has it (`is_trashed` when someone trashed it there) |
| `offline` | Immich has the asset but its last scan could not find the file |
| `pendingScan` | The NAS has it and Immich has not listed it yet |
| `excluded` | Never imported: a file type Immich does not read, or covered by the library's exclusion patterns |
| `notOnNAS` | No verified NAS copy on record |

If a library has assets and none match a synced file, the check stops and records nothing, because the library is not reading this NAS root.

Checks run outside the job gate, so a slow or absent server never holds up a file job.

## Albums

Events get an album only when asked: by pairing an existing album, or by choosing one in the event's **Album** menu (**Existing Album**, **New Album Named After the Event**, or **No Album**). **Make an album for every event** in Settings is off by default; turned on, every event left at the default gets an album named after it.

**Pairing existing albums.** Choosing a library, or **Pair Albums** in Settings › Services, reads every album on the account (read-only) and pairs it with an event when the match is clear:

- its name equals the event's name or its dated album title, ignoring case and Unicode spelling; or
- at least 80% of its photos, and at least 5, are one event's files, matched by library path.

Nothing ambiguous is paired: two events tying for a name, an album that mixes events, a name and contents that disagree, or an event that matches two albums. Private events need **Allow album**, events set to **No album** keep it, and an event that already has an album keeps that one. Each unpaired album is listed with its reason. Pairing writes nothing to Immich.

A pairing is stored by album ID, so renaming the album in Immich does not break it. The event also keeps the album's name with a custom policy, so an older build still fills the same album by name. An album made by name on a check is paired by ID from then on.

**Filling.** Each check adds the event's online, untrashed photos that are missing from its album. It never removes any, so a photo taken out of such an album comes back on the next check; choose **No Album** to stop that. A paired album that is no longer in Immich is reported, not made again.

**Where it shows.** The event header has an Immich album chip with the album's name, its photo count, "N to add" when some are missing, and buttons for Send to Immich and Open in Immich. Paired events have an album mark in the sidebar. Settings › Services lists every pair with **Unpair**, and every unpaired album with its reason.

## Send to Immich

**Send to Immich…** on the event's chip, its storage capsule, or its sidebar menu opens a list of events, with that event checked. Sending asks Immich to scan now and waits up to 90 seconds for the chosen events' files to appear. Only those events' folders are read, so it is a few requests. It then fills their albums and shows each step: scanning, adding photos to an album, done. Each event lists photos that are not on the NAS yet ("sync first") and photos Immich has not listed yet, which are added on the next check.

A private event never gets an album unless **Allow album** is on for that event. That only governs albums: Immich reads the whole NAS root, so a private event's files are visible in Immich unless the library's exclusion patterns cover them. The event says so when it happens.

## Stacks

**Stack bursts and edits in Immich** (Settings, on by default; nothing happens until a library is chosen) makes, on each check and on Send to Immich:

- each burst the board groups into one stack, with its cover frame on top;
- each RAW file and the JPEG of the same shot into one stack;
- each original and its edit from the event's `Edited` folder (a Photomator export, or a graded copy such as `C0001_709.mp4`) into one stack, edit on top. An edit of a burst frame sits right under the burst's cover.

Groups never cross events. A file not matched to an asset in the chosen library is left out, and a group with fewer than two matched files is not made.

Bursts are grouped from the catalog without reading the NAS, using the board's own rules. Each file's modification time, which the camera set and verified copies keep, stands in for its capture time. Frames the board joins only after a visual check, and manual burst splits, are not known here, so such a burst can come out as two smaller stacks, never a bigger one.

**Other people's stacks are never touched.** Immich's create call merges any stack whose top asset is among the IDs, and pulls other members out of their stacks. So a group with any asset already in a stack the app did not make is skipped and reported. The app keeps every stack it made in `immich_stacks` (group, stack ID, assets). A re-run with nothing changed creates nothing. When a frame was added or renamed, the app makes the group again, which replaces only its own stack. The app never deletes a stack and never changes one it did not make.

Burst tiles the app stacked show a small stack mark, and the event's Immich chip shows "N stacks".

From a script, with the saved server URL, the chosen library (or the only external library on the account), and the Keychain key read inside that one process:

```
CameraToolkit --immich-stacks --dry-run [--event <name>]...
CameraToolkit --immich-stacks [--event <name>]... [--log <file.jsonl>]
```

The dry run only reads. It reports how many stacks it would make, how many are already the app's and unchanged, how many it would leave alone because they are already in someone else's stack, and how many groups are not matched in Immich. A real run writes one JSON line per stack it made to the log (default `<support folder>/Immich Stack Logs/`); that list of stack IDs is what to undo from.

## View in Immich

**View in Immich** sits beside the event's Immich chip and in the event's sidebar menu. It opens the paired album; without an album, the event's folder in Immich's folder view; without a known library, the server's home page. In the photo preview's menu it opens that photo's own Immich page when a check has matched it. It is disabled, with a hint, until a server URL is set.

## Renames

Immich has no notion of a file moving. After a NAS rename the old asset goes offline and is trashed, and the new path becomes a new asset without the old one's albums or face tags. Once Immich's trash window passes, the old asset is gone along with that membership. The file itself is untouched.

The app remembers each rename in `immich_path_moves` for 90 days. With **Keep renamed files in their albums** on in Settings, a check adds the new asset to every album the old one is in. It only adds; it never deletes or restores an Immich asset or empties its trash. Face tags are not carried over: Immich recognises faces again on the new asset, and named-person assignments it cannot match have to be redone there.

## Setup

In Settings › Services enter the server URL and an API key, press **Test Connection**, then choose the library. The key lives in the macOS Keychain only and is sent only as a request header.

Settings says plainly when no key is saved. When an earlier build saved one under another Keychain entry, **Move the Key an Earlier Version Saved** copies it over on your click; macOS asks first, and the old entry is left alone.

Use a key from the account that owns the library, with these permissions: library read and scan, asset read and update, album create and add, stack create and update. Stacks and albums are made as the key's user, so another user's key, even an admin's, cannot stack or album the owner's photos.

## Server version

Written against Immich v3.3.1. Listing a library's assets uses the search fields Immich marks deprecated from v3.2 (`libraryId`, `withDeleted`, `page`), which are the ones that return offline assets without further filtering; they are planned to go in v4.
