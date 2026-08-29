#!/usr/bin/env bash
# Setup — plugin init / maintenance pass. Named setup-hook.sh to stay distinct
# from setup.sh, the interactive installer run by install.sh and /devscope:setup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

TRIGGER=$(echo "$INPUT" | jq -r '.trigger // ""')

PAYLOAD=$(jq -n --arg t "$TRIGGER" '{trigger: $t}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "plugin.setup" "$PAYLOAD" >/dev/null
