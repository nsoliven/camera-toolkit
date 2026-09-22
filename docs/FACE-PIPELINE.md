# Face pipeline — engine contract and conventions

This is the standard for everything face-related in Camera Toolkit. Read it before touching `Sources/CameraToolkitCore/Faces/`, the sidecar, or a threshold.

## The rule

**We do not re-implement face ML. We run the reference implementation and test against it.**

Detection, landmark prediction, alignment, preprocessing, and embedding are done by the `insightface` Python package — the code the model authors ship — inside a sidecar process (`Sources/CameraToolkitCore/Resources/face_sidecar.py`). Swift owns files, decoding, SQLite, grouping, and UI. The line between the two is the JSON protocol below, and the Swift side never needs to know what a stride, an anchor, a landmark template, or a channel order is.

Why this is a rule and not a preference: the previous in-house CoreML port had two silent bugs that no test caught for weeks — anchors offset by half a stride (every crop shifted off the ArcFace template) and BGR/RGB swapped into the embedder. Both were places where Swift re-derived something `insightface` already does. Neither could have existed under this rule.

## The engine

| Role | Implementation | Source of truth |
|---|---|---|
| Detector | SCRFD-10G with 5 landmarks (`det_10g.onnx` from `buffalo_l`) | `insightface.model_zoo.SCRFD` |
| Alignment | 5-point similarity warp to 112×112 | `insightface.utils.face_align.norm_crop` |
| Identity | ArcFace ResNet-50 `w600k_r50.onnx` from `buffalo_l`, 512-d L2-normalized | `insightface.model_zoo.ArcFaceONNX` |
| Runtime | onnxruntime with the CoreML execution provider (CPU fallback), model cache under `face-sidecar/ort-cache` | `onnxruntime` |
| Process | one Python process per pool slot; JSON lines over stdin/stdout | `FaceSidecar.swift` |

`FaceEngine.identifier` (`insightface/buffalo_l`) is stamped on every face row (`faces.model`) and every scanned photo (`face_photos.engine`). Rows carrying another identifier are invisible to matching, grouping, and templates, and never satisfy the skip rule, so an engine change re-reads photos instead of mixing embedding spaces. Changing the pack, the model, or anything that changes vectors means changing the identifier.

Install once per Mac: `scripts/setup-face-sidecar.sh` (needs `uv`; fetches an isolated Python 3.12, pins the packages, downloads the pack into `~/Library/Application Support/CameraToolkit/face-sidecar`, warms the CoreML cache). `--check` reports status. Nothing ships in the repo; nothing is ever re-trained.

## Protocol

Each request is one JSON object on one line; each response is one line; stderr is logging.

```text
→ {"event":"ready","pack":"buffalo_l","insightface":"2.0","onnxruntime":"1.30.0","providers":[...]}
← {"id":1,"op":"analyze","image_b64":"<jpeg>","det_sizes":[640],"det_thresh":0.6,"flip_tta":false}
→ {"id":1,"width":2560,"height":1707,"faces":[{"box":[x1,y1,x2,y2],"kps":[[x,y]×5],"det_score":0.93,
     "embedding":[512 floats],"norm":21.7,"crop_b64":"<jpeg 112×112>"}]}
← {"id":2,"op":"embed_crop","image_b64":"<png 112×112>"}   → {"id":2,"embedding":[...],"norm":...}
← {"id":3,"op":"ping"}                                       → {"id":3,"ok":true}
→ {"id":n,"error":"..."}   on any failure
```

- Boxes come back in image pixels with a top-left origin. `FaceSidecarPool.faces(from:)` converts to the app's normalized bottom-left boxes. That conversion is the only geometry Swift does and it has a unit test.
- `norm` is the embedding's pre-normalization L2 norm — ArcFace's built-in quality signal. Stored as `faces.quality`.
- Multiple `det_sizes` (HIGH 640/960, XHIGH 640/960/1024) run the detector per size; results merge under the detector's own NMS.
- `flip_tta` averages the embedding with the mirrored crop (XHIGH).
- Swift sends a bounded, orientation-applied decode as JPEG q0.95 (`FaceScanOptions.detectPixels` long edge). The sidecar decodes with OpenCV into the BGR layout `insightface` expects. Never pre-process pixels on the Swift side.

## Thresholds and where they come from

| Setting | Default | Meaning | Source |
|---|---|---|---|
| `detScoreThreshold` | 0.6 | detections below are not stored | between Immich's 0.7 and InsightFace's 0.5; keeps boxes for review |
| `groupingMinDetScore` | 0.7 | below this a face is stored but never grouped | Immich default |
| `groupingMinFacePixels` | 48 px (decoded image, short side) | below this a face is never grouped | measured: sub-40 px crops were the junk piles |
| `minimumGroupFaces` | 3 | a new cluster needs this many faces to become "Person N" | Immich `minRecognizedFaces` |
| `clusterThreshold` | 0.40 | mean cosine to a group's members to join it (average linkage) | Immich max distance 0.6 → similarity 0.4 |
| `matchThreshold` | 0.45 | best template cosine to propose a named person | InsightFace publishes 0.30–0.45 for this model |
| `minimumFacePixels` | 64 / 40 / 30 px native by grade | detection size floor | product decision (FACE-PLAN.md) |

Change a default only with a measurement on real data — the confirmed faces in the catalog are the ground truth (same-person vs different-person cosine distributions). Never tune by eye on one pile.

## Grouping

`FaceIndexService.assignToGroups` is average-linkage, single pass, deterministic (detection-confidence order):

1. Faces failing the quality gate (`qualifiesForGrouping`) are skipped; they can still be proposed to named people.
2. A face joins the existing cluster with the highest **mean** cosine to all its members when that mean clears `clusterThreshold`; otherwise it opens a cluster. Comparing to one face (first, or a sliding mean) is what built the 700-person piles — two strangers can both resemble a hub face and not each other.
3. Rejections (`face_rejections`) bar a face from a person and veto groups whose rejected faces describe the candidate better.
4. A cluster opened this pass is persisted only at `minimumGroupFaces`; smaller ones leave their faces ungrouped.

Re-match dissolves the automatic "Person N" groups and re-runs this over stored vectors; named people and confirmed faces never move.

## Confirmed faces and engine migration

A confirmed label is trusted; its measurement is not. When a re-scan produces a detection overlapping a confirmed face (IoU > 0.5), `FaceIndexStore.replaceFaces` refreshes that row's box, embedding, quality, crop, and `model` in place and keeps the person. That is how a named gallery moves into a new engine's space without anyone re-tagging: run a scan, templates follow the refreshed rows.

## Verifying

- `swift test --filter FaceSidecarParityTests` — embeds a synthetic pattern through the sidecar and compares against a golden vector produced by the original ONNX model with InsightFace preprocessing (cosine ≥ 0.98), checks the swapped-channel pattern lands elsewhere, exercises the pool, and unit-tests the box conversion and install contract.
- `swift test --filter FaceIndexTests` — grouping semantics, quality gate, minimum group size, engine skip rule, confirmed refresh.
- Regenerating the golden vector: run `w600k_r50.onnx` through onnxruntime on `FaceSidecarFixture.pattern()` with `(x − 127.5) / 127.5` in RGB order (see `arcface_onnx.py`), and paste the 512 values into `FaceSidecarParityTests.swift`.

## Do not

- Do not add a second detector or embedder path in Swift (Vision, CoreML, a "fast mode" model). One engine, one space.
- Do not touch pixels between decode and the sidecar besides bounding the size and applying orientation.
- Do not copy formulas out of `insightface` into Swift "for speed". If something must move, move it into the sidecar and keep calling the library.
- Do not change a threshold, the pack, or the pins without recording the measurement here.
