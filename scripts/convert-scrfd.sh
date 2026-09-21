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
#   det_10g.mlpackage        640 letterbox input — MED, every pass's base
#   det_10g_960.mlpackage    960 letterbox input — HIGH's second scale
#   det_10g_1024.mlpackage  1024 letterbox input — XHIGH's third scale
#
# `--34g /path/to/scrfd_34g.onnx` additionally converts a locally supplied
# SCRFD-34G ONNX into `det_34g*.mlpackage` siblings at the same sizes —
# the optional, default-off XHIGH detector. The file is never downloaded;
# supply it yourself. The buffalo_l download is skipped when only the 34G
# conversion is pending.
#
# Runtime is pure CoreML — no Python, no server. This script is a
# throwaway-venv developer step, same as convert-arcface.sh.
#
# Usage: scripts/convert-scrfd.sh [--force] [--34g /path/to/scrfd_34g.onnx]
#   --force       reconvert even if the detectors are already installed
#   --34g PATH    also convert this local SCRFD-34G ONNX into det_34g*
#                 siblings (optional XHIGH detector, default off)

force=false
large_onnx=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force) force=true ;;
    --34g)
      shift
      large_onnx="${1:-}"
      if [[ -z "$large_onnx" || ! -f "$large_onnx" ]]; then
        echo "--34g needs a path to a local scrfd_34g ONNX file." >&2
        exit 2
      fi
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
models_dir="$HOME/Library/Application Support/CameraToolkit/Models"
zip_url="https://github.com/deepinsight/insightface/releases/download/v0.7/buffalo_l.zip"
sizes=(640 960 1024)

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

pending_large=()
if [[ -n "$large_onnx" ]]; then
  for size in "${sizes[@]}"; do
    if [[ $size == 640 ]]; then
      destination="$models_dir/det_34g.mlpackage"
    else
      destination="$models_dir/det_34g_${size}.mlpackage"
    fi
    if [[ -d "$destination" && $force == false ]]; then
      echo "Already installed: $destination"
    else
      pending_large+=("$size")
    fi
  done
fi

if [[ ${#pending[@]} -eq 0 && ${#pending_large[@]} -eq 0 ]]; then
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

if [[ ${#pending[@]} -gt 0 ]]; then
  echo "Downloading buffalo_l (~275 MB) from the official InsightFace release…"
  curl -fL --retry 3 -o "$work/buffalo_l.zip" "$zip_url"
  unzip -o -q "$work/buffalo_l.zip" "det_10g.onnx" -d "$work"
fi
if [[ ${#pending_large[@]} -gt 0 ]]; then
  cp "$large_onnx" "$work/det_34g.onnx"
fi

join_by_comma() { local IFS=,; echo "$*"; }

mkdir -p "$models_dir"
"$work/venv/bin/python" - "$work" "$models_dir" \
    "$(join_by_comma "${pending[@]:-}")" \
    "$([[ ${#pending_large[@]} -gt 0 ]] && echo "$work/det_34g.onnx" || echo "")" \
    "$(join_by_comma "${pending_large[@]:-}")" <<'PY'
import shutil
import sys

import numpy as np
import onnxruntime as ort
import torch
import coremltools as ct
from onnx2torch import convert

work, models_dir = sys.argv[1], sys.argv[2]
sizes_10g = [int(s) for s in sys.argv[3].split(",") if s]
large_onnx = sys.argv[4]
sizes_34g = [int(s) for s in sys.argv[5].split(",") if s]

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

def destination(prefix, size):
    name = f"{prefix}.mlpackage" if size == 640 else f"{prefix}_{size}.mlpackage"
    return f"{models_dir}/{name}", f"{work}/{name}"

rng = np.random.RandomState(7)

def convert_family(onnx_path, prefix, sizes):
    torch_model = convert(onnx_path).eval()
    session = ort.InferenceSession(onnx_path, providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name

    for size in sizes:
        destination_path, package_path = destination(prefix, size)
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

        # Cross-check against the ONNX original: fp16 drift is fine, but
        # the outputs must still point the same way. Both sides are sorted
        # into the canonical (channel count, anchor count) order first.
        reference = session.run(None, {input_name: x})
        ref_sorted = sorted(reference, key=lambda a: (a.shape[-1], -a.size))
        got_sorted = sorted(
            [np.asarray(v, dtype=np.float64) for v in converted.values()],
            key=lambda a: (a.shape[-1], -a.size),
        )
        for ref, got in zip(ref_sorted, got_sorted):
            r, g = ref.ravel(), got.ravel()
            cosine = float(np.dot(r, g) / (np.linalg.norm(r) * np.linalg.norm(g)))
            assert cosine >= 0.995, f"{prefix} output diverged from ONNX at {size} (cosine {cosine})"

        shutil.copytree(package_path, destination_path, dirs_exist_ok=True)
        print(f"verified + installed {size}px detector: {destination_path} (cosine vs ONNX >= 0.995)")

if sizes_10g:
    convert_family(f"{work}/det_10g.onnx", "det_10g", sizes_10g)
if large_onnx and sizes_34g:
    convert_family(large_onnx, "det_34g", sizes_34g)
PY

echo "Medium and above face scans are now available in Camera Toolkit."
