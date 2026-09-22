#!/bin/zsh
# Installs the face sidecar once per Mac: a private Python environment with
# the reference InsightFace package, the `buffalo_l` model pack, and a warm
# CoreML cache. Nothing is committed to the repository and nothing lands
# outside the app's own support folder.
#
#   scripts/setup-face-sidecar.sh            install or update
#   scripts/setup-face-sidecar.sh --check    report status, change nothing
#
# Requires `uv` (brew install uv). It fetches an isolated Python 3.12 if the
# Mac has none, so the system or Homebrew Python is never touched.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sidecar_script="$repo_root/Sources/CameraToolkitCore/Resources/face_sidecar.py"
root="${CAMERA_TOOLKIT_FACE_SIDECAR_ROOT:-$HOME/Library/Application Support/CameraToolkit/face-sidecar}"
venv="$root/venv"
python="$venv/bin/python"
pack_marker="$root/models/buffalo_l/w600k_r50.onnx"
python_version="3.12"

# Pinned so every Mac runs the same reference code. Bump deliberately and
# re-run the parity tests (swift test --filter FaceSidecar).
requirements=(
  "insightface==2.0"
  "onnxruntime==1.30.0"
  "opencv-python-headless>=4.10"
  "numpy>=1.26,<3"
)

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
elif [[ $# -gt 0 ]]; then
  echo "usage: scripts/setup-face-sidecar.sh [--check]" >&2
  exit 2
fi

if $check_only; then
  if [[ -x "$python" && -f "$pack_marker" ]]; then
    echo "Face sidecar installed at $root"
    "$python" -c 'import insightface, onnxruntime; print(f"insightface {insightface.__version__}, onnxruntime {onnxruntime.__version__}")'
    exit 0
  fi
  echo "Face sidecar is not installed. Run scripts/setup-face-sidecar.sh" >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required: brew install uv" >&2
  exit 1
fi

mkdir -p "$root"
echo "Creating Python $python_version environment at $venv…"
uv venv --quiet --clear --python "$python_version" "$venv"
echo "Installing the reference face packages…"
uv pip install --quiet --python "$python" "${requirements[@]}"

echo "Downloading the buffalo_l model pack and warming the CoreML cache…"
"$python" "$sidecar_script" --root "$root" --prefetch > "$root/ready.json"

cat > "$root/setup.json" <<JSON
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "python": "$python_version",
  "requirements": [$(printf '"%s",' "${requirements[@]}" | sed 's/,$//')]
}
JSON

echo "Installed: $root"
echo "Camera Toolkit can now scan for faces at every quality."
