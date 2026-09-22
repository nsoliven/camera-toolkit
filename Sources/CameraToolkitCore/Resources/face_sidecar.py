#!/usr/bin/env python3
"""Camera Toolkit face sidecar.

The reference InsightFace pipeline (`buffalo_l`: SCRFD-10G detection with
five landmarks, ArcFace `w600k_r50` embeddings) behind a line protocol, so
the Swift app never re-implements detection, alignment, or preprocessing.
Everything identity-related happens inside `insightface` exactly as its
authors wrote it; this file only moves bytes in and out.

Protocol — one JSON object per line on stdin, one per line on stdout;
stderr is free-form logging:

  startup   → {"event": "ready", "pack": ..., "insightface": ..., ...}
  request   ← {"id": "…", "op": "analyze", "image_b64": "<jpeg/png>",
               "det_sizes": [640], "det_thresh": 0.6, "flip_tta": false}
  response  → {"id": "…", "width": W, "height": H, "faces": [
                 {"box": [x1, y1, x2, y2],          # image pixels, top-left origin
                  "kps": [[x, y] × 5],
                  "det_score": 0.93,
                  "embedding": [512 floats],        # L2-normalized
                  "norm": 21.7,                     # pre-normalization norm (quality)
                  "crop_b64": "<jpeg of the aligned 112×112 crop>"}]}
  request   ← {"id": "…", "op": "embed_crop", "image_b64": "<112×112 png>"}
  response  → {"id": "…", "embedding": [...], "norm": ...}
  request   ← {"id": "…", "op": "ping"}      → {"id": "…", "ok": true}
  failure   → {"id": "…", "error": "message"}

Run `--prefetch` once (the setup script does) to download the model pack
and warm the CoreML cache without serving requests.
"""

import argparse
import base64
import contextlib
import json
import os
import sys
import traceback


def log(message):
    print(f"[face-sidecar] {message}", file=sys.stderr, flush=True)


def emit(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", required=True, help="InsightFace root; the pack lives at <root>/models/<pack>")
    parser.add_argument("--pack", default="buffalo_l")
    parser.add_argument("--cpu", action="store_true", help="skip the CoreML provider")
    parser.add_argument("--prefetch", action="store_true", help="download models, warm caches, print ready, exit")
    args = parser.parse_args()

    import cv2
    import numpy as np
    import onnxruntime as ort

    ort.set_default_logger_severity(3)
    import insightface
    from insightface.app import FaceAnalysis
    from insightface.utils import face_align

    cache = os.path.join(args.root, "ort-cache")
    os.makedirs(cache, exist_ok=True)
    if args.cpu:
        providers = ["CPUExecutionProvider"]
        provider_options = [{}]
    else:
        providers = ["CoreMLExecutionProvider", "CPUExecutionProvider"]
        provider_options = [{"ModelCacheDirectory": cache}, {}]

    # insightface prints model paths to stdout while loading; keep the
    # protocol stream clean.
    with contextlib.redirect_stdout(sys.stderr):
        app = FaceAnalysis(
            name=args.pack,
            root=args.root,
            allowed_modules=["detection", "recognition"],
            providers=providers,
            provider_options=provider_options,
        )
        app.prepare(ctx_id=0, det_size=(640, 640), det_thresh=0.5)
    detector = app.det_model
    recognizer = app.models["recognition"]

    ready = {
        "event": "ready",
        "pack": args.pack,
        "insightface": insightface.__version__,
        "onnxruntime": ort.__version__,
        "providers": getattr(getattr(detector, "session", None), "get_providers", lambda: providers)(),
        "detector": os.path.basename(getattr(detector, "model_file", "")),
        "recognizer": os.path.basename(getattr(recognizer, "model_file", "")),
    }
    if args.prefetch:
        # Compile every detector input shape a grade can ask for, so the
        # first HIGH/XHIGH scan does not stall on CoreML.
        blank = np.zeros((1024, 1024, 3), dtype=np.uint8)
        for size in (640, 960, 1024):
            detector.detect(blank, input_size=(size, size), max_num=0, metric="default")
        recognizer.get_feat(np.zeros((112, 112, 3), dtype=np.uint8))
        emit(ready)
        return
    emit(ready)

    def decode_image(payload):
        raw = np.frombuffer(base64.b64decode(payload), dtype=np.uint8)
        image = cv2.imdecode(raw, cv2.IMREAD_COLOR)  # BGR, what insightface expects
        if image is None:
            raise ValueError("could not decode the image")
        return image

    def detect(image, det_sizes, det_thresh):
        detector.det_thresh = float(det_thresh)
        boxes, landmarks = [], []
        for size in det_sizes:
            size = int(size)
            found, kps = detector.detect(image, input_size=(size, size), max_num=0, metric="default")
            if found is not None and len(found):
                boxes.append(found)
                landmarks.append(kps)
        if not boxes:
            return np.zeros((0, 5), np.float32), np.zeros((0, 5, 2), np.float32)
        boxes = np.vstack(boxes)
        landmarks = np.vstack(landmarks)
        if len(det_sizes) > 1:
            # Each scale is already NMS'd; merge the scales with the same rule.
            order = boxes[:, 4].argsort()[::-1]
            boxes, landmarks = boxes[order], landmarks[order]
            keep = detector.nms(boxes)
            boxes, landmarks = boxes[keep], landmarks[keep]
        return boxes, landmarks

    def embed_aligned(aligned, flip_tta):
        feature = recognizer.get_feat(aligned).flatten().astype(np.float64)
        if flip_tta:
            mirrored = recognizer.get_feat(cv2.flip(aligned, 1)).flatten().astype(np.float64)
            feature = (feature + mirrored) / 2.0
        norm = float(np.linalg.norm(feature))
        if norm > 0:
            feature = feature / norm
        return feature, norm

    def crop_bytes(aligned):
        ok, encoded = cv2.imencode(".jpg", aligned, [int(cv2.IMWRITE_JPEG_QUALITY), 82])
        return base64.b64encode(encoded.tobytes()).decode("ascii") if ok else None

    def analyze(request):
        image = decode_image(request["image_b64"])
        height, width = image.shape[:2]
        det_sizes = request.get("det_sizes") or [640]
        det_thresh = request.get("det_thresh", 0.6)
        flip_tta = bool(request.get("flip_tta", False))
        boxes, landmarks = detect(image, det_sizes, det_thresh)
        faces = []
        for box, kps in zip(boxes, landmarks):
            aligned = face_align.norm_crop(image, landmark=kps, image_size=112)
            embedding, norm = embed_aligned(aligned, flip_tta)
            faces.append({
                "box": [float(v) for v in box[:4]],
                "kps": [[float(x), float(y)] for x, y in kps],
                "det_score": float(box[4]),
                "embedding": [round(float(v), 7) for v in embedding],
                "norm": norm,
                "crop_b64": crop_bytes(aligned),
            })
        return {"width": int(width), "height": int(height), "faces": faces}

    def embed_crop(request):
        image = decode_image(request["image_b64"])
        if image.shape[:2] != (112, 112):
            image = cv2.resize(image, (112, 112), interpolation=cv2.INTER_AREA)
        embedding, norm = embed_aligned(image, bool(request.get("flip_tta", False)))
        return {"embedding": [round(float(v), 7) for v in embedding], "norm": norm}

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
