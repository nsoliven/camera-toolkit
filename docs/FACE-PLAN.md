# Face-for-events — implementation brief

Read this as product law. Do not reopen model shopping. Do not add features this doc does not ask for.

Owner wants a **personal Swift photo app** (existing). Faces exist only to **tag events** so they can sort/filter albums by who was there. Not a face-research product. Not Immich. Python sidecar for ML is OK. Storage: SQLite.

Hardware: **M4 Max**. Library scale: ~**20k photos** first, grows. People they care about: **~20**, maybe 50 later.

---

## What the owner thinks (do not fight this)

- Events are the product. Faces are tags on events.
- Plug in a drive → compute should just run. No science UI.
- They do **not** care about generalizing to thousands of identities.
- They do **not** want tiny background heads most of the time. Group-shot faces that are clearly people are fine. 15px tourists are not.
- ArcFace is fine. Frozen. Never fine-tune on 20 people.
- Unnamed people should still be **grouped** (Immich-style) so they can grab a whole cluster and name/merge it.
- Confirmed labels are **trusted**. Do not reclassify them. Ever.
- FAST **on** pins the Mac. FAST **off** is the quiet pass. Not a quality tier.
- First ingest can be rough. After they name people, cheap passes should get good because the gallery exists.
- They will review when they want: roster, new groups, unsure. Don’t mark unreviewed work as “accepted quality.”
- Keep the writeup short in product. No model names in the UI.

---

## Pipeline (always this order)

1. Drive in → hash files → skip known hashes.
2. EXIF date/GPS → **events** (time-gap albums). Events do not wait on faces.
3. Face pass (mode + optional FAST throttle).
4. `event.people` = unique roster people on that event’s photos. Other groups do not clutter event chips unless the user named them.

Old files are not touched unless the user hits **Rescan**.

---

## Two knobs

### 1. Quality — `LOW | MED | HIGH | XHIGH`

How hard we search for **real, reasonably large faces**, and how many extra views we harvest. Same identity model every time.

### 2. Speed — `FAST` on/off

**ON** pins the Mac (max workers, runs hot). **OFF** is the quiet 2-wide pass. Same models. Default **ON**. FAST is not a fifth quality. Quiet overnight = High with FAST off.

Auto ingest = **LOW + FAST**.

---

## Models (locked)

| Role | Model | Notes |
|---|---|---|
| Identity (all modes) | **InsightFace ArcFace R50 `w600k_r50`** (buffalo_l recognizer) | 512-d, L2-normalized. **Never change per mode.** Gallery dies if you swap. |
| LOW detect | **Apple Vision** (`VNDetectFaceRectangles` + landmarks) | ANE, large/clear faces. Does **not** group or recognize. |
| MED / HIGH / XHIGH detect | **SCRFD-10G** (buffalo_l detector), 5-point landmarks | Better box + ArcFace-native align. |
| XHIGH detect extra | Optional SCRFD-34G **only** if we still miss real group-shot faces. Default off. | Do not hunt 15px heads. |
| Align | 5-point → 112×112 ArcFace crop | Vision landmarks mapped to 5-point on LOW. |
| Group / match | Cosine on R50 vectors | Roster 1:N, then cluster leftovers. |

**Rejected:** MobileFaceNet for “speed,” antelopev2 / R100, RetinaFace-R50 as default, training/finetuning ArcFace, dual embedding spaces, Apple Vision for identity.

Accuracy that matters: family, aging, profile, kids. CFP-FP / AgeDB-30. Not LFW.

---

## What each quality mode actually does

Min face size is the small-face policy. Not a different recognizer.

| Mode | Detect | Min face (guide) | Extra | ~20k new stills, FAST off |
|---|---|---|---|---|
| **LOW** | Vision | ~60–80px | stills only, poster frame for video | ≤3 min |
| **MED** | SCRFD-10G @ 640 | ~40px | stills; light video keyframes | 10–20 min |
| **HIGH** | 10G @ 640 and 960 | ~30px+ (still a real face) | video ~1 fps | 1–2 h (video is the hour) |
| **XHIGH** | 10G (optional 34G), scales 640/960/1024 | same ~30px floor | video ~2 fps, hflip TTA, rebuild templates | overnight if lots of video; stills-only is much less |

XHIGH is **more angles/lighting/video of the ~20 people**, and better templates. It is **not** “detect every head in the crowd.”

If the library is almost all stills, HIGH/XHIGH will not naturally fill hours. Do not pad with a bigger identity net.

---

## Scan rules

Per **photo**: `scan_grade` = none < low < med < high < xhigh.

Per **face**: `cached` | `proposed` | `confirmed` | `other`.

**Default run (new files only):**
- Process if never seen, or `scan_grade` < this mode.
- Skip photo if `scan_grade` ≥ this mode.
- Skip **face** if `confirmed`. Same photo may still get *new* unconfirmed faces found.

**FAST/LOW auto-ingest cache:**
- Embeddings are cheap to keep. Replug must not re-run detect/embed if hash+model match.
- If the user **never reviewed**, do **not** treat that as accepted gospel. Higher modes may still upgrade `proposed` faces.
- If roster changed (name/merge), **re-match cached vectors** to gallery (CPU). No GPU.

**Rescan:** separate action, not default. Runs on already-scanned files. UI shows **Before / After**. User apply or discard. Confirmed faces still do not move.

**Confirmed:** user said this is Dad. Frozen. Higher mode must not un-Dad it. May add *other* faces on that photo.

---

## Gallery (this is what makes LOW good later)

Closed set of ~20 named people.

- Each person: several **templates** (8–15 after XHIGH; 1+ after first name). Diverse views (front, side, glasses, years) — not 8 random.
- New face → cosine vs templates. ≥ ~0.45–0.50 → `proposed` that person. Else → Other clustering.
- Adding person 21: user names an Other group (or a face). Templates stored. Next pass matches them. No retrain. Optional MED/HIGH backfill onto old events.
- Do **not** auto-create roster people forever. Auto clusters live in **Other groups**. User **promotes** to roster.

LOW after a good gallery is 1:N, not full-library reclustering. That’s the speed + quality story. Same R50.

---

## Others / grouping

Like Immich, but roster chips on events only show **named** people.

- All faces that pass min-size get embedded (strangers too).
- Leftovers clustered (DBSCAN/HNSW-style). Unnamed groups: “Person 7, 40 photos.”
- User can: name group, merge into a roster person, junk (statue/dog).
- Clustering Others is **not** a time problem. Detect+embed is. Do not skip grouping to save clock.

---

## Review UI (3 tabs)

1. **People** — roster ~20. Rename, merge, split, pin template, remove from roster.
2. **New groups** — clusters this run created/changed. Adopt or junk.
3. **Unsure** — `proposed` below high confidence. Confirm / not this person / Other.

Confirm → `confirmed`. Until then, higher modes may overwrite proposals.

Event UI: date first; face chips fill in live. Filter events by roster person. That’s the payoff.

No model picker, no threshold sliders on the main path, no “retrain.”

---

## Compute UI

One sheet:

- Quality: LOW / MED / HIGH / XHIGH
- FAST: toggle
- Scope: new files (default) | Rescan (before/after)
- Progress: photos, pending, ETA. No buffalo names.

Unplug = pause. Replug = resume hashes.

---

## Implement order

1. Ingest + events (hash, EXIF, time gaps). No faces.
2. LOW: Vision → R50 → SQLite. Match roster if templates exist, else cluster all (including Others). Event chips for named only.
3. Name/merge UI + confirmed lock. This is what makes LOW good.
4. MED: SCRFD-10G, min-size ~40px, process new + lower-grade + unreviewed proposed.
5. FAST on = pin the runner; off = 2-wide quiet pass.
6. HIGH / XHIGH: extra scale, video fps, TTA, template mining. Same R50.
7. Rescan + before/after.

---

## SQLite sketch (minimum)

- `photos`: path, hash, taken_at, scan_grade, indexed_at
- `people`: id, name, is_roster, centroid optional, face_count
- `faces`: photo_id, person_id nullable, box, det_score, quality, embedding BLOB (512 float32 L2), model=`w600k_r50`, state=`cached|proposed|confirmed|other`, scan_grade
- `templates`: person_id, face_id, pose/quality optional
- `events`: time range; `event_people` derived from confirmed+proposed roster faces

One embedding space. If model name changes someday, re-embed. Don’t mix.

---

## Timing sanity (M4 Max, 20k stills)

Decode (esp. software HEIC) can dominate. JPEG is cheap. Cluster step is seconds.

- LOW+FAST: a few minutes, GPU not pinned
- LOW FAST off: ~3 min if batched
- MED: ~8–20 min
- HIGH/XHIGH hours come from **video frames + extra scales**, not R50

Stock InsightFace batch=1 will miss LOW’s 3 min cap. Batch + overlap decode is the actual hard engineering. Models are decided.

---

## Do not

- Different recognizer per mode
- Fine-tune ArcFace on the family
- Max GPU on default ingest
- Stamp unreviewed LOW as final grade
- Overwrite confirmed faces
- Optimize for tiny-face mAP
- Auto-fill the roster with every cluster
- Make events wait on ML
- Add antelopev2 “just in case”
