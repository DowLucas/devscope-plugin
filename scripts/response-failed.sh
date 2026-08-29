#!/usr/bin/env bash
# StopFailure — the turn ended in an error rather than a normal stop.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

ERROR=$(echo "$INPUT" | jq -r '.error // "" | tostring | .[:300]')
ERROR_DETAILS=$(echo "$INPUT" | jq -r '.error_details // "" | .[:500]')

PAYLOAD=$(jq -n \
  --arg e "$ERROR" \
  --arg ed "$ERROR_DETAILS" \
  '{error: $e} | if $ed != "" then . + {errorDetails: $ed} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "response.failed" "$PAYLOAD" >/dev/null
