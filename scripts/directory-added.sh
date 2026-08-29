#!/usr/bin/env bash
# DirectoryAdded — an extra working directory was registered (/add-dir or SDK).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"

DIRECTORY=$(echo "$INPUT" | jq -r '.directory // ""')
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')

if [ "${DEVSCOPE_PRIVACY:-standard}" = "private" ] && [ -n "$DIRECTORY" ]; then
  DIRECTORY="hash:$(_ds_sha256 "$DIRECTORY" | cut -c1-12)"
fi

PAYLOAD=$(jq -n \
  --arg d "$DIRECTORY" \
  --arg s "$SOURCE" \
  '{directory: $d, source: $s}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "directory.added" "$PAYLOAD" >/dev/null
