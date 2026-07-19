#!/bin/zsh
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

files=("${(@f)$(git ls-files)}")
if (( ${#files} == 0 )); then
  echo "No tracked files to audit." >&2
  exit 1
fi

failed=false

check_pattern() {
  local description="$1"
  local pattern="$2"
  local matches
  matches="$(grep -InE "$pattern" "${files[@]}" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    echo "$description:" >&2
    echo "$matches" >&2
    failed=true
  fi
}

check_pattern "Absolute user-home path" '/(Users|home)/[^[:space:]`"<>]+'
check_pattern "Private key material" 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY'
check_pattern "Likely GitHub token" 'gh[pousr]_[A-Za-z0-9]{30,}'
check_pattern "Likely AWS access key" 'AKIA[0-9A-Z]{16}'

if $failed; then
  exit 1
fi

echo "Public-content audit passed."
