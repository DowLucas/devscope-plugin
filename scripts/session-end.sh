#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

END_REASON=$(echo "$INPUT" | jq -r '.reason // "other"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Capture final git state (detect branch/commit drift during session)
GIT_BRANCH=""
GIT_COMMIT=""
if [ -n "$CWD" ]; then
  GIT_BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  GIT_COMMIT=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
fi

# Read accumulated file changes
FILES_CHANGED="[]"
_GC_HASH=""
if [ -n "$CWD" ]; then
  _GC_HASH=$(_ds_project_hash "$CWD")
  _GC_FILES="${HOME}/.cache/devscope/${_GC_HASH}.files"
  if [ -f "$_GC_FILES" ]; then
    if [ "$DEVSCOPE_PRIVACY" = "redacted" ]; then
      # Only send basenames in redacted mode
      FILES_CHANGED=$(sort -u "$_GC_FILES" | head -200 | while read -r fp; do basename "$fp"; done | jq -R . | jq -sc '.')
    else
      FILES_CHANGED=$(sort -u "$_GC_FILES" | head -200 | jq -R . | jq -sc '.')
    fi
    rm -f "$_GC_FILES"
  fi
fi

PAYLOAD=$(jq -n \
  --arg er "$END_REASON" \
  --argjson fc "$FILES_CHANGED" \
  --arg branch "$GIT_BRANCH" \
  --arg commit "$GIT_COMMIT" \
  '{endReason: $er}
   | if ($fc | length) > 0 then . + {filesChanged: $fc} else . end
   | if $branch != "" then . + {gitBranch: $branch} else . end
   | if $commit != "" then . + {gitCommit: $commit} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "session.end" "$PAYLOAD"

# Clean up all session state files
if [ -n "$_GC_HASH" ]; then
  rm -f "${HOME}/.cache/devscope/${_GC_HASH}.session"
  rm -f "${HOME}/.cache/devscope/${_GC_HASH}.files"
  rm -f "${HOME}/.cache/devscope/${_GC_HASH}.agents"
fi
