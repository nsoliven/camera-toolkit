#!/bin/zsh
# Installs the pet sidecar once per Mac: a private Python environment with
# PyTorch and Hugging Face transformers, the RT-DETRv2 dog detector and the
# DINOv2 identity model, warmed on the Metal device. Nothing is committed
# to the repository and nothing lands outside the app's own support folder.
# The face sidecar is separate and unaffected.
#
#   scripts/setup-pet-sidecar.sh            install or update
#   scripts/setup-pet-sidecar.sh --check    report status, change nothing
#
# Requires `uv` (brew install uv). It fetches an isolated Python 3.12 if the
# Mac has none, so the system or Homebrew Python is never touched. About
# 1.5 GB on disk once the models are downloaded.
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
sidecar_script="$repo_root/Sources/CameraToolkitCore/Resources/pet_sidecar.py"
root="${CAMERA_TOOLKIT_PET_SIDECAR_ROOT:-$HOME/Library/Application Support/CameraToolkit/pet-sidecar}"
venv="$root/venv"
python="$venv/bin/python"
ready_marker="$root/ready.json"
python_version="3.12"

# Pinned so every Mac runs the same reference code. The model revisions are
# pinned inside pet_sidecar.py. Bump deliberately, change the engine
# identifier, and re-run the pet tests (swift test --filter Pet).
requirements=(
  "torch==2.15.0"
  "transformers==5.22.2"
  "pillow>=10.4"
  "numpy>=1.26,<3"
)

check_only=false
if [[ "${1:-}" == "--check" ]]; then
  check_only=true
elif [[ $# -gt 0 ]]; then
  echo "usage: scripts/setup-pet-sidecar.sh [--check]" >&2
  exit 2
fi

if $check_only; then
  if [[ -x "$python" && -s "$ready_marker" ]]; then
    echo "Pet sidecar installed at $root"
    cat "$ready_marker"
    exit 0
  fi
  echo "Pet sidecar is not installed. Run scripts/setup-pet-sidecar.sh" >&2
  exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
  echo "uv is required: brew install uv" >&2
  exit 1
fi

mkdir -p "$root"
# A half-finished install must never look ready to the app.
rm -f "$ready_marker"
echo "Creating Python $python_version environment at $venv…"
uv venv --quiet --clear --python "$python_version" "$venv"
echo "Installing PyTorch and transformers…"
uv pip install --quiet --python "$python" "${requirements[@]}"

echo "Downloading the dog detector and identity model and warming the Metal device…"
"$python" "$sidecar_script" --root "$root" --prefetch > "$root/ready.json.partial"
mv "$root/ready.json.partial" "$ready_marker"

cat > "$root/setup.json" <<JSON
{
  "installedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "python": "$python_version",
  "requirements": [$(printf '"%s",' "${requirements[@]}" | sed 's/,$//')]
}
JSON

echo "Installed: $root"
echo "Turn on Settings › Organizing › Pets, then run Scan for Faces to look for dogs too."
