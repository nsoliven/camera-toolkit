#!/bin/zsh
set -euo pipefail

# One-time developer conversion of the face *detector* used by MED and
# above. Downloads the same official InsightFace `buffalo_l` pack as
# convert-arcface.sh, extracts only `det_10g.onnx` (SCRFD-10G, the pack's
# detector with 5-point landmarks), and converts it to float16 CoreML
# `.mlpackage`s installed under:
#
#   ~/Library/Application Support/CameraToolkit/Models/
#
# The ONNX trace bakes per-shape constants, so each input size ships as
# its own fixed-shape package:
#
#   det_10g.mlpackage       640 letterbox input — MED, and every pass's base
#   det_10g_960.mlpackage   960 letterbox input — HIGH's second scale
#
# Runtime is pure CoreML — no Python, no server. This script is a
# throwaway-venv developer step, same as convert-arcface.sh.
#
# Usage: scripts/convert-scrfd.sh [--force]
#   --force   reconvert even if the detectors are already installed

force=false
[[ "${1:-}" == "--force" ]] && force=true

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
models_dir="$HOME/Library/Application Support/CameraToolkit/Models"
zip_url="https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
sizes=(640 960)

pending=()
for size in "${sizes[@]}"; do
  if [[ $size == 640 ]]; then
    destination="$models_dir/det_10g.mlpackage"
  else
    destination="$models_dir/det_10g_${size}.mlpackage"
  fi
  if [[ -d "$destination" && $force == false ]]; then
    echo "Already installed: $destination"
  else
    pending+=("$size")
  fi
done

if [[ ${#pending[@]} -eq 0 ]]; then
  echo "All detector packages installed. Pass --force to reconvert."
  exit 0
fi

work="$(mktemp -d /tmp/scrfd-convert.XXXXXX)"
trap 'rm -rf "$work"' EXIT

packages=(
  "coremltools==9.0"
  "onnx==1.17.0"
  "onnx2torch==1.5.15"
  "onnxruntime==1.30.0"
  "torch==2.14.0"
)

if command -v uv >/dev/null 2>&1; then
  uv venv --python 3.12 "$work/venv" >/dev/null
  uv pip install --quiet --python "$work/venv/bin/python" "${packages[@]}"
elif command -v python3 >/dev/null 2>&1; then
  python3 -m venv "$work/venv"
  "$work/venv/bin/pip" install --quiet "${packages[@]}"
else
  echo "python3 (or uv) is required for the one-time conversion." >&2
  exit 1
fi

echo "Downloading buffalo_l (~275 MB) from the official InsightFace release…"
curl -fL --retry 3 -o "$work/buffalo_l.zip" "$zip_url"
unzip -o -q "$work/buffalo_l.zip" "det_10g.onnx" -d "$work"

mkdir -p "$models_dir"
"$work/venv/bin/python" - "$work" "$models_dir" "${pending[@]}" <<'PY'
import shutil
import sys

import numpy as np
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert

work, models_dir = sys.argv[1], sys.argv[2]
sizes = [int(s) for s in sys.argv[3:]]
onnx_path = f"{work}/det_10g.onnx"
torch_model = convert(onnx_path).eval()
session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
input_name = session.get_inputs()[0].name

def destination(size):
    name = "det_10g.mlpackage" if size == 640 else f"det_10g_{size}.mlpackage"
    return f"{models_dir}/{name}", f"{work}/{name}"

# Expected SCRFD anchors per input side: 2 per cell at strides 8/16/32.
def anchors(side):
    return sum(2 * (side // s) ** 2 for s in (8, 16, 32))

def check(outputs, side):
    """Nine outputs, anchor counts match, scores already in [0, 1]."""
    assert len(outputs) == 9, f"expected 9 outputs at {side}, got {len(outputs)}"
    by_channels = {1: [], 4: [], 10: []}
    for value in outputs.values():
        arr = np.asarray(value, dtype=np.float64)
        channels = arr.shape[-1]
        assert channels in by_channels, f"unexpected output shape {arr.shape}"
        by_channels[channels].append(arr)
    total = anchors(side)
    for channels in (1, 4, 10):
        assert sum(a.shape[-2] for a in by_channels[channels]) == total, \
            f"{channels}-channel anchors at {side}: {sum(a.shape[-2] for a in by_channels[channels])} != {total}"
    scores = np.concatenate([a.ravel() for a in by_channels[1]])
    assert scores.min() >= 0.0 and scores.max() <= 1.0, \
        "score outputs are not probabilities — sigmoid is not baked into the graph"

rng = np.random.RandomState(7)

for size in sizes:
    destination_path, package_path = destination(size)
    traced = torch.jit.trace(torch_model, torch.randn(1, 3, size, size))
    model = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[ct.TensorType(shape=(1, 3, size, size))],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS14,
    )
    model.save(package_path)

    loaded = ct.models.MLModel(package_path)
    coreml_input = loaded.get_spec().description.input[0].name
    x = rng.rand(1, 3, size, size).astype(np.float32) * 2 - 1
    converted = loaded.predict({coreml_input: x})
    check(converted, size)

    # Cross-check against the ONNX original: fp16 drift is fine, but the
    # outputs must still point the same way. Both sides are sorted into the
    # canonical (channel count, anchor count) order before comparison.
    reference = session.run(None, {input_name: x})
    ref_sorted = sorted(reference, key=lambda a: (a.shape[-1], -a.size))
    got_sorted = sorted(
        [np.asarray(v, dtype=np.float64) for v in converted.values()],
        key=lambda a: (a.shape[-1], -a.size),
    )
    for ref, got in zip(ref_sorted, got_sorted):
        r, g = ref.ravel(), got.ravel()
        cosine = float(np.dot(r, g) / (np.linalg.norm(r) * np.linalg.norm(g)))
        assert cosine >= 0.995, f"detector output diverged from ONNX at {size} (cosine {cosine})"

    shutil.copytree(package_path, destination_path, dirs_exist_ok=True)
    print(f"verified + installed {size}px detector: {destination_path} (cosine vs ONNX >= 0.995)")
PY

echo "Medium and High face scans are now available in Camera Toolkit."
