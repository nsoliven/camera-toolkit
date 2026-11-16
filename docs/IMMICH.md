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

## Renames

Immich has no notion of a file moving. After a NAS rename the old asset goes offline and is trashed, and the new path becomes a new asset without the old one's albums or face tags. Once Immich's trash window passes, the old asset is gone along with that membership. The file itself is untouched.

The app remembers each rename in `immich_path_moves` for 90 days. With **Keep renamed files in their albums** on in Settings, a check adds the new asset to every album the old one is in. It only adds; it never deletes or restores an Immich asset or empties its trash. Face tags are not carried over: Immich recognises faces again on the new asset, and named-person assignments it cannot match have to be redone there.

## Setup

In Settings › Services enter the server URL and an API key, press **Test Connection**, then choose the library. The key lives in the macOS Keychain only and is sent only as a request header. Scanning and listing libraries need an admin user's key.

## Server version

Written against Immich v3.3.1. Listing a library's assets uses the search fields Immich marks deprecated from v3.2 (`libraryId`, `withDeleted`, `page`), which are the ones that return offline assets without further filtering; they are planned to go in v4.
