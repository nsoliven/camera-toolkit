#!/usr/bin/env python3
"""Camera Toolkit pet sidecar.

Finds dogs in a photo and describes each one with an identity vector, so
the Swift app can group one dog's photos together the way it groups a
person's. Both models run through Hugging Face `transformers` with their
authors' own image processors; this file only moves bytes in and out and
cuts the crop each embedding is computed from.

  detector  RT-DETRv2 R50 (`PekingU/rtdetr_v2_r50vd`, COCO, Apache-2.0)
  identity  DINOv2 base (`facebook/dinov2-base`, Apache-2.0), CLS token,
            L2-normalized, 768-d

Protocol — the face sidecar's: one JSON object per line on stdin, one per
line on stdout; stderr is free-form logging.

  startup   → {"event": "ready", "engine": ..., "torch": ..., "device": ...}
  request   ← {"id": …, "op": "analyze", "image_b64": "<jpeg/png>",
               "det_thresh": 0.5, "flip_tta": false}
  response  → {"id": …, "width": W, "height": H, "faces": [
                 {"box": [x1, y1, x2, y2],          # image pixels, top-left origin
                  "det_score": 0.93,
                  "species": "dog",
                  "embedding": [768 floats],        # L2-normalized
                  "norm": 41.2,                     # pre-normalization norm
                  "crop_b64": "<jpeg of the square crop>"}]}
  request   ← {"id": …, "op": "embed_crop", "image_b64": "<png>"}
  response  → {"id": …, "embedding": [...], "norm": ...}
  request   ← {"id": …, "op": "ping"}      → {"id": …, "ok": true}
  failure   → {"id": …, "error": "message"}

Models are fetched once by `--prefetch` (the setup script runs it) into
`<root>/hf`; serving never touches the network.
"""

import argparse
import base64
import contextlib
import io
import json
import os
import sys
import traceback

DETECTOR = "PekingU/rtdetr_v2_r50vd"
DETECTOR_REVISION = "282494075698cab9faa1096ae26856890030c817"
EMBEDDER = "facebook/dinov2-base"
EMBEDDER_REVISION = "f9e44c814b77203eaa57a6bdbbd535f21ede1415"
# Matches `PetFaceEngine.identifier` in Swift. Any change to a model, a
# revision, the crop rule, or the vector means a new identifier.
ENGINE = "pets/rtdetr_v2_r50vd+dinov2-base"
SPECIES = ("dog",)
# The crop grows the detector's box by this fraction on every side, then
# squares it, so ears and tail stay in and the processor's center crop
# never cuts the dog.
CROP_MARGIN = 0.10
CROP_JPEG_EDGE = 224


def log(message):
    print(f"[pet-sidecar] {message}", file=sys.stderr, flush=True)


def emit(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def square_crop_box(box, width, height, margin=CROP_MARGIN):
    """The square region an embedding is computed from, in image pixels.

    The detector's box grown by `margin` on each side, squared on its
    longer side around the same center, then shifted (not shrunk) to stay
    inside the image when it can. Pure, so a test pins it.
    """
    x1, y1, x2, y2 = box
    bw, bh = x2 - x1, y2 - y1
    side = max(bw, bh) * (1 + 2 * margin)
    side = min(side, float(max(width, height)))
    cx, cy = (x1 + x2) / 2, (y1 + y2) / 2
    left, top = cx - side / 2, cy - side / 2
    left = min(max(left, 0.0), max(width - side, 0.0)) if side <= width else (width - side) / 2
    top = min(max(top, 0.0), max(height - side, 0.0)) if side <= height else (height - side) / 2
    return (left, top, left + side, top + side)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True, help="pet sidecar root; models live in <root>/hf")
    parser.add_argument("--cpu", action="store_true", help="skip the Metal (MPS) device")
    parser.add_argument("--prefetch", action="store_true", help="download models, warm up, print ready, exit")
    args = parser.parse_args()

    os.environ["HF_HOME"] = os.path.join(args.root, "hf")
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    if not args.prefetch:
        os.environ["HF_HUB_OFFLINE"] = "1"
    # Detection ops MPS lacks fall back to the CPU instead of failing.
    os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

    import numpy as np
    import torch
    import transformers
    from PIL import Image, ImageOps
    from transformers import AutoImageProcessor, AutoModel, RTDetrV2ForObjectDetection

    device = "mps" if (not args.cpu and torch.backends.mps.is_available()) else "cpu"

    with contextlib.redirect_stdout(sys.stderr):
        det_processor = AutoImageProcessor.from_pretrained(DETECTOR, revision=DETECTOR_REVISION)
        detector = RTDetrV2ForObjectDetection.from_pretrained(DETECTOR, revision=DETECTOR_REVISION).to(device).eval()
        emb_processor = AutoImageProcessor.from_pretrained(EMBEDDER, revision=EMBEDDER_REVISION)
        embedder = AutoModel.from_pretrained(EMBEDDER, revision=EMBEDDER_REVISION).to(device).eval()

    species_by_label = {
        int(index): name for index, name in detector.config.id2label.items() if name in SPECIES
    }
    if not species_by_label:
        raise SystemExit("the detector has no dog class")

    ready = {
        "event": "ready",
        "engine": ENGINE,
        "detector": f"{DETECTOR}@{DETECTOR_REVISION[:7]}",
        "embedder": f"{EMBEDDER}@{EMBEDDER_REVISION[:7]}",
        "torch": torch.__version__,
        "transformers": transformers.__version__,
        "device": device,
        "providers": [device],
    }

    def decode_image(payload):
        image = Image.open(io.BytesIO(base64.b64decode(payload)))
        # Swift already applied the orientation; this only guards a raw
        # file sent by hand.
        image = ImageOps.exif_transpose(image)
        return image.convert("RGB")

    @torch.inference_mode()
    def detect(image, threshold):
        inputs = det_processor(images=image, return_tensors="pt").to(device)
        outputs = detector(**inputs)
        target = torch.tensor([[image.height, image.width]], device=device)
        result = det_processor.post_process_object_detection(outputs, target_sizes=target, threshold=float(threshold))[0]
        found = []
        for score, label, box in zip(result["scores"].cpu(), result["labels"].cpu(), result["boxes"].cpu()):
            species = species_by_label.get(int(label))
            if species is not None:
                found.append((float(score), species, [float(v) for v in box.tolist()]))
        found.sort(key=lambda item: -item[0])
        return found

    @torch.inference_mode()
    def embed(crops, flip_tta):
        inputs = emb_processor(images=crops, return_tensors="pt").to(device)
        features = embedder(**inputs).pooler_output
        if flip_tta:
            mirrored = [ImageOps.mirror(crop) for crop in crops]
            flipped = embedder(**emb_processor(images=mirrored, return_tensors="pt").to(device)).pooler_output
            features = (features + flipped) / 2.0
        features = features.float().cpu().numpy().astype(np.float64)
        norms = np.linalg.norm(features, axis=1)
        normalized = features / np.maximum(norms[:, None], 1e-12)
        return normalized, norms

    def crop_bytes(crop):
        thumb = crop.resize((CROP_JPEG_EDGE, CROP_JPEG_EDGE), Image.Resampling.BICUBIC)
        buffer = io.BytesIO()
        thumb.save(buffer, format="JPEG", quality=82)
        return base64.b64encode(buffer.getvalue()).decode("ascii")

    def analyze(request):
        image = decode_image(request["image_b64"])
        width, height = image.size
        found = detect(image, request.get("det_thresh", 0.5))
        if not found:
            return {"width": width, "height": height, "faces": []}
        crops = []
        for _, _, box in found:
            left, top, right, bottom = square_crop_box(box, width, height)
            # PIL pads outside the image with black, which only happens
            # when the square is larger than the photo's short side.
            crops.append(image.crop((round(left), round(top), round(right), round(bottom))))
        vectors, norms = embed(crops, bool(request.get("flip_tta", False)))
        faces = []
        for (score, species, box), crop, vector, norm in zip(found, crops, vectors, norms):
            faces.append({
                "box": box,
                "det_score": score,
                "species": species,
                "embedding": [round(float(v), 7) for v in vector],
                "norm": float(norm),
                "crop_b64": crop_bytes(crop),
            })
        return {"width": width, "height": height, "faces": faces}

    def embed_crop(request):
        crop = decode_image(request["image_b64"])
        vectors, norms = embed([crop], bool(request.get("flip_tta", False)))
        return {"embedding": [round(float(v), 7) for v in vectors[0]], "norm": float(norms[0])}

    if args.prefetch:
        # One pass through both models compiles the Metal kernels and
        # proves the install end to end.
        blank = Image.new("RGB", (640, 480), (127, 127, 127))
        detect(blank, 0.5)
        embed([blank], False)
        emit(ready)
        return
    emit(ready)

    operations = {"analyze": analyze, "embed_crop": embed_crop, "ping": lambda request: {"ok": True}}

    for raw in sys.stdin.buffer:
        raw = raw.strip()
        if not raw:
            continue
        request_id = None
        try:
            request = json.loads(raw)
            request_id = request.get("id")
            handler = operations.get(request.get("op"))
            if handler is None:
                raise ValueError(f"unknown op {request.get('op')!r}")
            response = handler(request)
            response["id"] = request_id
            emit(response)
        except Exception as error:  # noqa: BLE001 — every failure must reach the caller
            log(traceback.format_exc())
            emit({"id": request_id, "error": f"{type(error).__name__}: {error}"})


if __name__ == "__main__":
    main()
