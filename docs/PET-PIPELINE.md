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
| Tell dogs apart | **DINOv2 base (`facebook/dinov2-base`)** | **Apache-2.0** | **Chosen.** General-purpose features that work zero-shot for retrieving individual animals; 768-d CLS token |
| | MegaDescriptor (BVRA) | CC-BY-NC-4.0 | Built for wildlife re-ID, but non-commercial, and the original training set probably had no dogs. A possible opt-in upgrade. |
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
| Crop | detector box + 10% margin per side, squared on the longer side, kept inside the photo (`square_crop_box`) |
| Identity | DINOv2 base `pooler_output` (layer-normed CLS), L2-normalized, 768-d. XHIGH averages it with the mirrored crop (`flip_tta`) |
| Runtime | PyTorch on the Metal (MPS) device with CPU fallback; one process (`PetSidecarPool`) |
| Protocol | the face sidecar's JSON-lines protocol (`analyze`, `embed_crop`, `ping`), so `FaceSidecarProcess` launches both and `FaceSidecarPool.faces(from:)` does the one box conversion for both |
| Identifier | `pets/rtdetr_v2_r50vd+dinov2-base` (`PetFaceEngine.identifier`), stamped on every pet row. The sidecar refuses to start if its `ENGINE` differs |

Install once per Mac with `scripts/setup-pet-sidecar.sh`. It needs `uv`, takes about 1.2 GB under `~/Library/Application Support/CameraToolkit/pet-sidecar`, pins torch 2.15.0 and transformers 5.22.2, and pins the model revisions. Models download once (`--prefetch`). Serving runs with `HF_HUB_OFFLINE=1`, so a scan never touches the network. `ready.json` is written last, so a half-finished install never looks installed. `--check` reports status. The face sidecar is separate and unchanged.

## Where pet data lives

Pet data goes in **`pets.sqlite`, beside `catalog.sqlite`**. It never goes into the catalog.

- It holds the face index's five tables (`face_photos`, `people`, `faces`, `face_templates`, `face_rejections`), column for column (a test guards this). `FaceIndexStore` therefore runs on it unchanged, with `engine: PetFaceEngine.identifier`.
- The catalog schema is not changed at all, and a pet scan never opens the catalog. A scan, Re-match, Junk or **Clear Pet Scan** on pets cannot touch a person, a face, an event or an assignment. `PetIndexTests.testAPetScanWritesOnlyThePetIndex` checks that the catalog's face tables are byte-identical after a pet scan, that the face skip rule still skips every photo, and that media bytes and dates are unchanged.
- The schema comes from a GRDB `DatabaseMigrator` (`PetIndexDatabase`). Every migration is additive. If the file already exists and a migration is pending, it is first copied with SQLite's online backup API to `Backups/pets-<UTC stamp>.sqlite` and integrity-checked; a failed check stops the migration.
- If the file is lost, pets need one re-scan and the names have to be re-entered. No photo or catalog data is affected.

The two code changes the face pipeline needed are both no-ops for people. `FaceIndexStore` and `FaceIndexService` now read the engine identifier from the store instead of a constant (default `FaceEngine.identifier`). The automatic group prefix comes from the engine too ("Person" or "Dog"), so a face Re-match never dissolves a dog group, and a dog Re-match never dissolves a person group.

## Thresholds and where they come from

| Setting | Pet default | Face default | Source |
|---|---|---|---|
| `detScoreThreshold` | 0.5 | 0.6 | RT-DETR scores; 0.5 kept every real dog in the sample below |
| `groupingMinDetScore` | 0.7 | 0.7 | same gate as faces |
| `groupingMinFacePixels` | 96 px | 48 px | dogs are larger than faces; tiny dogs are background |
| `minimumFacePixels` | 128 / 96 / 64 px by grade | 64 / 40 / 30 | product decision |
| `clusterThreshold` | **0.60** | 0.40 | measured, see below |
| `matchThreshold` | **0.68** | 0.45 | above the largest different-dog cosine seen at p90 (0.60); suggestions only |
| `minimumGroupFaces` | 3 | 3 | same |
| `videoDuplicateCosine` | 0.95 | 0.92 | DINOv2 vectors of consecutive frames sit closer |

**Measurement (2026-11-07):** 50 public-domain photos from Wikimedia Commons of two dogs of the same breed and the same black coat. This is the hard case: no breed or colour cue.

- The sidecar processed a 1280-px photo in a median 0.07 s on an Apple Silicon GPU.
- 40 photos had one dog. The 9 with none were a costumed person, a sculpture, and dogs too small to matter; all correct rejections.
- Pairwise cosine: same dog median 0.53, p90 0.69. Different dog median 0.52, p90 0.60, max 0.76. Single pairs overlap, so pairwise thresholds alone are not enough.
- Average-linkage grouping (the `assignToGroups` rule):
  - At 0.55–0.62, every group of 3+ held one dog. One dog was split into 2–3 groups, which the user merges.
  - At 0.65, one wrong dog joined a group.
  - At 0.70, under half the photos were grouped.
  - 0.60 is the default.
- Through the Swift path (`PetSidecarTests.testScanningASampleFolderFindsAndGroupsDogs`), the same folder gave 35 dogs and 3 groups with no failures.

These numbers come from two dogs. Change a default only with a measurement on the owner's confirmed pets, as FACE-PIPELINE.md says for faces.

## Verifying

- `swift test --filter PetIndexTests` covers the schema matching the catalog, migrate and backup, the scan writing only the pet index, Clear, the engine stamps, "Dog N", options, and the install contract.
- `swift test --filter PetGalleryTests` covers the Pets side of the window: browsing creates no file, and review actions write only the pet index.
- `CT_PET_SIDECAR_ROOT=<install> swift test --filter PetSidecarTests` runs the real sidecar: protocol, a blank image with no dog, and a stable 768-d unit vector. Add `CT_PET_SAMPLE_DIR=<folder of dog JPEGs>` to scan that folder read-only into a throwaway index and print the groups. Without an install these tests skip.

## Not done yet

- Pet review actions are not in the Undo history. Destructive ones (Remove group, Clear Pet Scan) keep their confirmations, and none can touch a file.
- `pets.sqlite` is not part of the catalog backup set mirrored to the NAS. It is backed up locally before migrations only.
- Event chips and the board's People filter list people only; pets show in the People window. Adding pets to the chips needs a paw marker on the chip.
- Cats: COCO has the class, and adding `"cat"` to `SPECIES` in the sidecar would find them. That changes what the engine stores, so it needs a new identifier and a species column.
