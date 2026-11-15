# Pet pipeline: finding and grouping dogs

Camera Toolkit groups a person's photos with the face pipeline (`docs/FACE-PIPELINE.md`). This note covers dogs. A dog is detected, described by an identity vector, and grouped with the same `FaceIndexService` code, so a household dog ends up with her own row in the People window under **Pets**, just as a person does. Read FACE-PIPELINE.md first. Every rule there applies here too.

## What it does

- **Scan for Faces** also looks for dogs when **Settings › Organizing › Pets › Look for dogs during face scans** is on and the pet engine is installed. The job runs the face pass first and the dog pass second, over the same burst stacks with the same sampling (first, middle and last frame of a burst below High) and the same video stride. The scan sheet adds one sentence to say dogs are included. There is no new button.
- The People window shows a **People | Pets** switch once pets are set up. Pets uses the same Approved list, Inbox, grids and review actions (approve, merge, rename, confirm, "Not this group", junk, cover, Re-match). Automatic groups are named "Dog N" instead of "Person N", which is how pets are told apart from people.
- Scanning only reads photos. Nothing is written next to media and no file is moved, renamed or deleted.

## Choosing the models

| Need | Options looked at | License | Verdict |
|---|---|---|---|
| Find dogs | Apple Vision `VNRecognizeAnimalsRequest` | OS API | Gives cat and dog boxes but no identity. Using it would put a second detector in Swift, and Swift would have to crop pixels, which FACE-PIPELINE.md rules out. It could later serve as a cheap pre-filter. Not used. |
| | torchvision Faster R-CNN v2 (COCO) | Code BSD-3; weights have no stated license | Good fallback |
| | **RT-DETRv2 R50 (`PekingU/rtdetr_v2_r50vd`)** | **Apache-2.0** (code and weights) | **Chosen.** COCO "dog" class, NMS-free, runs through `transformers` with the authors' own image processor and post-processing |
| | D-FINE, RF-DETR (Nano–L) | Apache-2.0 | Comparable alternatives |
| | YOLOX ONNX | Apache-2.0 | Release assets are stale and need hand-written pre/post-processing. Not used. |
| | Ultralytics YOLO | AGPL-3.0 | Not used: incompatible with an MIT repo |
| | dlib dog-face detector | CC0 | 2016 model, C++ example only, would need hand-written alignment. Not used. |
| Tell dogs apart | **DINOv2 large (`facebook/dinov2-large`)** | **Apache-2.0** | **Chosen.** General-purpose features that work zero-shot for retrieving individual animals; 1024-d CLS token. Measured best of everything below (see "Quality evaluation") |
| | DINOv2 base / small / with registers (large) | Apache-2.0 | Measured: base is close behind large, small and the registers variant are clearly worse |
| | SigLIP 2 so400m, CLIP ViT-L/14 | Apache-2.0 / MIT | Measured: they describe "a small white dog", not which one — far worse at telling individuals apart |
| | MegaDescriptor-L-384 (BVRA) | CC-BY-NC-4.0 | Built for wildlife re-ID, but non-commercial. Measured as a reference only: worse than DINOv2 large on real household dogs, so it is not an upgrade |
| | MiewID (msv2/msv3) | No license published | Includes dogs, but with no license it counts as all rights reserved. Not used. |
| | AvitoTech SigLIP/CLIP animal-ID | Card says Apache-2.0, but trained on PetFace (non-commercial) | Best dog numbers published, but the provenance is unclear. Not used. |
| | DogFaceNet, PetFace | MIT code, but no maintained weights / non-commercial | Need aligned dog faces and landmarks. Not used. |
| | DINOv3 | Custom license, gated download | Not used |

Why whole dogs rather than dog faces: personal photos show dogs from the side, from behind, and mid-run. A whole-body crop is detected far more reliably than a dog face. With one to a few household dogs plus strangers' dogs, coat, build and pose habits are what tell them apart. The cost is that look-alike littermates may share a group, and the user splits that group by hand.

The rule from FACE-PIPELINE.md stands: **the reference implementation runs in a Python sidecar, and Swift never touches pixels after decoding.** Both models load through `transformers` with their own `AutoImageProcessor`. The sidecar only moves bytes and cuts each embedding's crop.

## The engine

| Role | Implementation |
|---|---|
| Detector | RT-DETRv2 R50, COCO, label `dog`, revision pinned in `pet_sidecar.py` |
| Crop shown in the app | detector box + 10% margin per side, squared on the longer side, kept inside the photo (`square_crop_box`) |
| Crop the vector is computed from | the detector box alone, centered on a square of the embedder's mean color (`padded_box`), so neither background nor a second dog in the frame enters the vector |
| Identity | DINOv2 large `pooler_output` (layer-normed CLS) of the padded box, L2-normalized, 1024-d. No mirror averaging on any grade (it measured no better) |
| Runtime | PyTorch on the Metal (MPS) device with CPU fallback; one process (`PetSidecarPool`) |
| Protocol | the face sidecar's JSON-lines protocol (`analyze`, `embed_crop`, `ping`), so `FaceSidecarProcess` launches both and `FaceSidecarPool.faces(from:)` does the one box conversion for both |
| Identifier | `pets/rtdetr_v2_r50vd+dinov2-large-boxpad` (`PetFaceEngine.identifier`), stamped on every pet row. The sidecar refuses to start if its `ENGINE` differs |

Install once per Mac with `scripts/setup-pet-sidecar.sh`. It needs `uv`, takes about 2.3 GB under `~/Library/Application Support/CameraToolkit/pet-sidecar`, pins torch 2.15.0 and transformers 5.22.2, and pins the model revisions. Models download once (`--prefetch`). Serving runs with `HF_HUB_OFFLINE=1`, so a scan never touches the network. `ready.json` is written last, so a half-finished install never looks installed. `--check` reports status. The face sidecar is separate and unchanged.

## Where pet data lives

Pet data goes in **`pets.sqlite`, beside `catalog.sqlite`**. It never goes into the catalog.

- It holds the face index's five tables (`face_photos`, `people`, `faces`, `face_templates`, `face_rejections`), column for column (a test guards this). `FaceIndexStore` therefore runs on it unchanged, with `engine: PetFaceEngine.identifier`.
- The catalog schema is not changed at all, and a pet scan never opens the catalog. A scan, Re-match, Junk or **Clear Pet Scan** on pets cannot touch a person, a face, an event or an assignment. `PetIndexTests.testAPetScanWritesOnlyThePetIndex` checks that the catalog's face tables are byte-identical after a pet scan, that the face skip rule still skips every photo, and that media bytes and dates are unchanged.
- The schema comes from a GRDB `DatabaseMigrator` (`PetIndexDatabase`). Every migration is additive. If the file already exists and a migration is pending, it is first copied with SQLite's online backup API to `Backups/pets-<UTC stamp>.sqlite` and integrity-checked; a failed check stops the migration.
- If the file is lost, pets need one re-scan and the names have to be re-entered. No photo or catalog data is affected.

The two code changes the face pipeline needed are both no-ops for people. `FaceIndexStore` and `FaceIndexService` now read the engine identifier from the store instead of a constant (default `FaceEngine.identifier`). The automatic group prefix comes from the engine too ("Person" or "Dog"), so a face Re-match never dissolves a dog group, and a dog Re-match never dissolves a person group.

## Upright detection

Dog detection runs on an upright picture. A vertical RAW's embedded JPEG has no rotation of its own, so a pet pass turns the decode by the camera's rotation (`FaceScanOptions.uprightRawDetection`, set only by `.pets`) and detects and embeds on that. The people pass is unchanged: it still reads the unturned preview, and its boxes and rows are not touched. Measured on three real vertical frames, the sideways picture gave one box over two dogs at 0.52 to 0.74 confidence; upright gave two boxes at 0.85 to 0.92.

- **One stored space.** Boxes go back to the unrotated preview's space (`FaceBoxProjection.storedBox(fromTurned:quarterTurnsCW:)`) before they are stored, so the preview overlay and every existing row keep working. Stored crops are the upright ones.
- **No new identifier.** `PetFaceEngine.identifier` stays the same: the detector, embedder, crop rule and vector space have not changed, only which way up the picture was. Changing it would make every stored photo and row belong to another engine: every template and group vector would disappear from matching until a full rescan, which is what the identifier exists to force.
- **No pet manual boxes.** A drawn box is always a face (`FaceTagRequest`), so nothing crops a stored or drawn dog from a RAW; the sidecar's `embed_crop` is only reached by its test.

### The one-time rescan

`pet_photo_orientation` (`v2-upright-detection`) records, per photo, the camera turn detection ran at. A photo without a row was read before this change. It lives in its own table so the five face tables still match the catalog's column for column.

An ordinary dog scan checks the RAWs in its scope that have no marker: one short header read each, off the main actor, never again once marked. Ordinary photos and new photos cost no header read; a turn of 0 is marked done on the spot. A turn other than 0 means the photo is re-read upright, at its own grade so a lower pass cannot lose small dogs, one transaction per photo. Failed reads, whether of the header or the picture, leave the rows and marker alone and are retried by the next scan. Before the first rescan write, `pets.sqlite` is copied once with the SQLite backup API into `Backups/` under Application Support; the copy stays.

Each rescanned photo's old boxes are paired with the new ones (`PetBoxRemap`) in the shared stored space:

| Old and new | What happens |
|---|---|
| One to one, IoU at least 0.5 | The old row is refreshed in place, so its person, state, templates, rejections and any cover pointing at it stay. |
| One old box over two or more distinct new boxes (each at least 70% inside it, none of them matching it at IoU 0.75 or more): a two-dog merge. A dog already claimed by another old box stays with that box | Each remaining new box is checked against only the old box's group, by the rules that group applies to any dog. An approved pet's templates or a "looks like" row file it as a suggestion, never onto the pet itself; an automatic group needs its average-linkage threshold with the merged row left out. Everything else stays unassigned for the normal pass. The old row is removed unless the user confirmed it, it is a template or a verdict names it, or it is the group's last face. |
| New box with no old box | Stored unassigned; the normal match and group pass files it. |
| Old box with no new box | Removed only if it was an unassigned detection. Anything confirmed, grouped, a template or named in a verdict stays. |

IoU 0.5 is measured on real vertical frames: boxes on the same dog scored 0.64 to 0.96, boxes on a different dog 0.00 to 0.05, and a real two-dog box 0.29 to 0.59 against each dog it spanned. So 0.5 alone cannot tell a two-dog box from its larger dog; a box that covers two distinct new boxes is treated as a merge first, and a box matching one of them at 0.75 or more is a single dog with extra front or back boxes, not a merge.

## Thresholds and where they come from

| Setting | Pet default | Face default | Source |
|---|---|---|---|
| `detScoreThreshold` | 0.5 | 0.6 | detector sweep below: 0.45–0.5 is the knee; 0.6 loses real dogs, 0.4 adds false dogs and duplicate boxes |
| `groupingMinDetScore` | 0.7 | 0.7 | same gate as faces |
| `groupingMinFacePixels` | 96 px | 48 px | dogs are larger than faces; tiny dogs are background |
| `minimumFacePixels` | 128 / 96 / 64 px by grade | 64 / 40 / 30 | product decision |
| `clusterThreshold` | **0.50** | 0.40 | measured: fewest splits of one dog with no look-alike joining her groups |
| `matchThreshold` | **0.60** | 0.45 | measured: the closest of 322 look-alike dogs reached 0.56 against the household dog; suggestions only |
| `flipTTA` | off on every grade | XHIGH | measured no better for dogs |
| `minimumGroupFaces` | 3 | 3 | same |
| `videoDuplicateCosine` | 0.95 | 0.92 | not re-measured for the large model |

Change a default only with a new measurement, as FACE-PIPELINE.md says for faces.

## Quality evaluation

**Set (2026-11-07).** Everything ran read-only on small JPEG renders in a scratch folder; no original, catalog or app state was touched.

- **A real library:** 1,550 photos.
  - 150 from events where the main test dog appears.
  - 1,400 sampled across a year of other events: people, travel, landscapes, indoor parties, plush toys, zoo and farm animals.
- **Ground truth, labelled by hand:** 173 findable dogs.
  - The main dog is a small white long-haired breed, in 116 detections (108 clean enough to group).
  - A second recurring dog appears in 48.
  - A few strangers' dogs.
  - Hard cases are included: back of the head, side profile, low light, motion blur, a dog held against a person, two dogs overlapping, and dogs partly out of frame. So are things that must not count: plush toys, a framed dog photo, a dog figurine, monkeys and goats.
- **Look-alikes:** 322 public photos of other dogs.
  - Small white or fluffy breeds: Bichon Frisé, West Highland White Terrier, Havanese, Pomeranian, Japanese Chin, Samoyed, Great Pyrenees and wheaten terrier, from Wikimedia Commons and the Oxford-IIIT Pet set.
  - Yorkshire terriers.
  - Each is a different dog, so none may ever be grouped with or suggested as a household dog.
- **Simulation:** grouping replays `FaceIndexService.assignToGroups` (average linkage, detection-confidence order, 3-dog minimum). "After approval" approves the largest group of the main dog, keeps 8 farthest-first templates like `rebuildRosterTemplates`, and matches every other dog against them.

**Detector (unchanged RT-DETRv2), on the real library at score 0.5:**

| Measure | Result |
|---|---|
| Dogs found (recall) | 165 of 173 (95%) |
| Detections that were really dogs (precision) | 97% |
| Look-alike photos with their dog found | 322 of 322 |
| Plush toys called "dog" | 0 of 40+ photos with plush toys (the detector calls them "teddy bear") |

What it missed:
- 3 shots where it called the white dog a teddy bear;
- 1 dim indoor shot;
- 1 frame where two dogs touching came out as one box;
- 2 dogs mostly hidden behind a person.

False dogs: 3 boxes on monkeys (COCO has no monkey class), 1 goat, and 2 dog figurines.

**Telling dogs apart, before → after:**

| Measure | Before (DINOv2 base, margin crop, 0.60 / 0.68) | After (DINOv2 large, padded box, 0.50 / 0.60) |
|---|---|---|
| Separation of the main dog from every other dog (pairwise ROC AUC) | 0.946 | **0.982** |
| Groups the main dog is split into | 6 | **4** |
| Main dog in her largest group | 46 of 108 | **70 of 108** |
| Main dog filed in another dog's group | 7 | **1** |
| Other dogs in the main dog's groups | 0 | 1 (a box that also held the second dog) |
| After approving her largest group: her other photos suggested as "Looks like" | 13 of 70 | **29 of 46** |
| …so her photos named or suggested | 59 of 108 (55%) | **99 of 108 (92%)** |
| Wrong dogs suggested as her (look-alikes, second dog, false dogs) | 0 | **0** |
| Closest look-alike to her (cosine) | 0.58 | 0.56 |
| Second recurring dog | 1 group, 7 wrong dogs in it | 1 group (43 of 45), 1 wrong |

**What each change bought** (pairwise AUC, main dog vs every other dog):
- Padding the box instead of the margin crop was the big step: 0.946 → 0.967 on base.
- Large instead of base on top of it: 0.982.
- Mirror averaging, a 448-px input, mean-patch pooling and a second merge pass over whole groups all measured equal or worse, so none ships.

**Still weak:**
- **One dog still splits into a few groups.** Merging 3 small groups into the first one takes three clicks. The 9 photos neither grouped nor suggested are dim, blurred or back-of-head shots.
- **Strangers of the same breed group together.** Of 338 look-alike detections, 292 landed in 26 "Dog N" groups that mix different dogs of one breed. They never touch a named pet: approve, ignore or junk them.
- **The white fluffy breeds sometimes read as "teddy bear"** and are missed. Treating teddy-bear boxes as dogs would bring in every plush toy, so it is not done.
- **Animals with no COCO class (monkeys) and figurines can come back as dogs.** They rarely resemble a named pet, so they land in "Dog N" groups or nowhere.
- These numbers come from one personal library with two recurring dogs. A home with two near-identical dogs of the same breed will split and mix more.

## Verifying

- `swift test --filter PetIndexTests` covers the schema matching the catalog, migrate and backup, the scan writing only the pet index, Clear, the engine stamps, "Dog N", options, and the install contract.
- `swift test --filter PetGalleryTests` covers the Pets side of the window: browsing creates no file, and review actions write only the pet index.
- `CT_PET_SIDECAR_ROOT=<install> swift test --filter PetSidecarTests` runs the real sidecar: protocol, a blank image with no dog, and a stable 1024-d unit vector. Add `CT_PET_SAMPLE_DIR=<folder of dog JPEGs>` to scan that folder read-only into a throwaway index and print the groups. Without an install these tests skip.

## Not done yet

- Pet review actions are not in the Undo history. Destructive ones (Remove group, Clear Pet Scan) keep their confirmations, and none can touch a file.
- `pets.sqlite` is not part of the catalog backup set mirrored to the NAS. It is backed up locally before migrations and once before the first upright rescan.
- Event chips and the board's People filter list people only; pets show in the People window. Adding pets to the chips needs a paw marker on the chip.
- Cats: COCO has the class, and adding `"cat"` to `SPECIES` in the sidecar would find them. That changes what the engine stores, so it needs a new identifier and a species column.
