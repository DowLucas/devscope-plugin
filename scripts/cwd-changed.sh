#!/usr/bin/env bash
# CwdChanged — the session's working directory moved (/cd or equivalent).
# Paths are hashed in `private` mode, matching the projectPath policy (DEV-67).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"

OLD_CWD=$(echo "$INPUT" | jq -r '.old_cwd // ""')
NEW_CWD=$(echo "$INPUT" | jq -r '.new_cwd // ""')

if [ "${DEVSCOPE_PRIVACY:-standard}" = "private" ]; then
  [ -n "$OLD_CWD" ] && OLD_CWD="hash:$(_ds_sha256 "$OLD_CWD" | cut -c1-12)"
  [ -n "$NEW_CWD" ] && NEW_CWD="hash:$(_ds_sha256 "$NEW_CWD" | cut -c1-12)"
fi

PAYLOAD=$(jq -n \
  --arg o "$OLD_CWD" \
  --arg n "$NEW_CWD" \
  '{oldCwd: $o, newCwd: $n}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "cwd.change" "$PAYLOAD" >/dev/null
