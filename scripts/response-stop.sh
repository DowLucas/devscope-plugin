#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)
RESPONSE_LENGTH=${#LAST_MSG}

if [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  PAYLOAD=$(jq -n \
    --argjson rl "$RESPONSE_LENGTH" \
    --arg rt "$LAST_MSG" \
    '{responseLength: $rl, responseText: $rt}')
else
  PAYLOAD=$(jq -n \
    --argjson rl "$RESPONSE_LENGTH" \
    '{responseLength: $rl}')
fi

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "response.complete" "$PAYLOAD"
