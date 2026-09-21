#!/bin/zsh
set -euo pipefail

# One-time developer conversion of the frozen identity model.
#
# Downloads the official InsightFace `buffalo_l` model pack (a GitHub release
# asset), extracts only `w600k_r50.onnx` (ArcFace ResNet-50 trained on
# WebFace600K), and converts it to a float16 CoreML `.mlpackage` installed at:
#
#   ~/Library/Application Support/CameraToolkit/Models/w600k_r50.mlpackage
#
# Runtime is pure CoreML — no Python, no server. This script is the only
# Python step, and it runs in a throwaway venv on a development machine.
#
# coremltools removed its ONNX frontend in 7.x, so the path is
# ONNX → PyTorch (onnx2torch) → CoreML (mlprogram, fp16). The converted
# embedding is verified against onnxruntime: same input, cosine ≥ 0.99.
#
# Usage: scripts/convert-arcface.sh [--force]
#   --force   reconvert even if the model is already installed

force=false
[[ "${1:-}" == "--force" ]] && force=true

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
models_dir="$HOME/Library/Application Support/CameraToolkit/Models"
destination="$models_dir/w600k_r50.mlpackage"
zip_url="https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"

if [[ -d "$destination" && $force == false ]]; then
  echo "Already installed: $destination"
  echo "Pass --force to reconvert."
  exit 0
fi

# Prefer a Python that has working coremltools wheels: 3.12/3.13. `uv` can
# fetch a standalone interpreter without touching the system Python.
work="$(mktemp -d /tmp/arcface-convert.XXXXXX)"
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
unzip -o -q "$work/buffalo_l.zip" "w600k_r50.onnx" -d "$work"

mkdir -p "$models_dir"
"$work/venv/bin/python" - "$work" "$destination" <<'PY'
import shutil
import sys

import numpy as np
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert

work, destination = sys.argv[1], sys.argv[2]
onnx_path = f"{work}/w600k_r50.onnx"
package_path = f"{work}/w600k_r50.mlpackage"

torch_model = convert(onnx_path).eval()
example = torch.randn(1, 3, 112, 112)
traced = torch.jit.trace(torch_model, example)

model = ct.convert(
    traced,
    convert_to="mlprogram",
    inputs=[ct.TensorType(shape=(1, 3, 112, 112))],
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.macOS14,
)
model.save(package_path)

# Verify the conversion: the CoreML embedding must point the same direction
# as the ONNX original on an identical input.
rng = np.random.RandomState(42)
x = rng.randn(1, 3, 112, 112).astype(np.float32)
reference = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"]) \
    .run(None, {"input.1": x})[0].astype(np.float64).ravel()
converted = list(ct.models.MLModel(package_path).predict({"input_1": x}).values())[0] \
    .astype(np.float64).ravel()
assert converted.shape == (512,), f"expected 512-d embedding, got {converted.shape}"
cosine = float(np.dot(reference, converted) / (np.linalg.norm(reference) * np.linalg.norm(converted)))
assert cosine >= 0.99, f"converted model diverged from ONNX (cosine {cosine})"
print(f"verified: 512-d embedding, cosine vs ONNX = {cosine:.4f}")

shutil.copytree(package_path, destination, dirs_exist_ok=True)
PY

echo "Installed: $destination"
echo "Face scans are now available in Camera Toolkit (LOW · FAST on an Unsorted folder)."
