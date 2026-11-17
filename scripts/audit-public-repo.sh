#!/bin/zsh
set -euo pipefail

# Fails when tracked files (or, with --history, any commit on any local
# branch, and commit messages) contain personal or machine-specific data.
#
# Besides the built-in patterns, it reads the owner's private deny-list —
# one case-insensitive term (an extended regex) per line, `#` comments
# allowed — from $CT_PRIVATE_TERMS_FILE (or the older
# $CAMERA_TOOLKIT_PRIVATE_TERMS), default
# ~/.config/camera-toolkit/private-terms.txt, and fails on any match in the
# tracked files or, with --history, in history. A missing list is skipped
# silently. That list names real people, events and places, so it lives
# outside the repository and must never be committed or printed.

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

mode="tree"
[[ "${1:-}" == "--history" ]] && mode="history"

files=("${(@f)$(git ls-files)}")
if (( ${#files} == 0 )); then
  echo "No tracked files to audit." >&2
  exit 1
fi

failed=false

report() {
  local description="$1"
  local matches="$2"
  if [[ -n "$matches" ]]; then
    echo "$description:" >&2
    echo "$matches" | head -40 >&2
    failed=true
  fi
}

check_pattern() {
  local description="$1"
  local pattern="$2"
  local flags="${3:-}"
  local allowed="${4:-}"
  local matches=""
  if [[ "$mode" == "tree" ]]; then
    matches="$(grep -In${flags}E "$pattern" "${files[@]}" 2>/dev/null || true)"
  else
    # Every added line in every commit reachable from a local branch, then
    # every commit message.
    matches="$(git log --branches -p --no-color --format='commit %h' \
      | awk '/^commit [0-9a-f]+$/ { c = $2; next } /^\+\+\+ / { f = $2; next } /^\+/ { print c " " f ": " $0 }' \
      | grep -${flags}E "$pattern" || true)"
    matches+="$(git log --branches --format='%h %s %b' | grep -${flags}E "$pattern" | sed 's/^/message /' || true)"
  fi
  # Placeholders that are plainly not anyone's data.
  if [[ -n "$allowed" && -n "$matches" ]]; then
    matches="$(echo "$matches" | grep -viE "$allowed" || true)"
  fi
  report "$description" "$matches"
}

check_pattern "Absolute user-home path" '/(Users|home)/[^[:space:]`"<>/]+' '' '/(Users|home)/(x|me|user|example|someone|you|USER|<[^>]*>|\$[A-Za-z_]+)(/|[^A-Za-z0-9_]|$)'
check_pattern "Private key material" 'BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY'
check_pattern "Likely GitHub token" 'gh[pousr]_[A-Za-z0-9]{30,}'
check_pattern "Likely AWS access key" 'AKIA[0-9A-Z]{16}'
check_pattern "Likely Supabase token" 'sbp_[0-9a-f]{20,}'
check_pattern "Private network address" '(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
check_pattern "Email address" '[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\.(com|net|org|io|dev|me|app|co)\b' 'i' '@example\.(com|org|net)|noreply@anthropic\.com'

private_terms="${CT_PRIVATE_TERMS_FILE:-${CAMERA_TOOLKIT_PRIVATE_TERMS:-$HOME/.config/camera-toolkit/private-terms.txt}}"
if [[ -f "$private_terms" ]]; then
  term_number=0
  while IFS= read -r term || [[ -n "$term" ]]; do
    term="${term%$'\r'}"
    [[ -z "${term//[[:space:]]/}" || "$term" == \#* ]] && continue
    term_number=$((term_number + 1))
    # Named by its line number, so a failing run does not echo the term
    # itself into a log (the matching lines still show where it is).
    check_pattern "Private term #$term_number of the deny-list" "$term" 'i'
  done < "$private_terms"
fi

if $failed; then
  exit 1
fi

echo "Public-content audit passed ($mode)."
