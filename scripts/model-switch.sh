#!/usr/bin/env bash
# PostModelSwitch — the session's model changed. Observed after the fact.
# PreModelSwitch is deliberately NOT registered: it gates the switch and waits
# for an answer, so a telemetry hook there can block or fail a model change.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

FROM_MODEL=$(echo "$INPUT" | jq -r '.from_model // ""')
TO_MODEL=$(echo "$INPUT" | jq -r '.to_model // ""')
REQUESTED_MODEL=$(echo "$INPUT" | jq -r '.requested_model // ""')
SOURCE=$(echo "$INPUT" | jq -r '.source // ""')
CONTEXT_TOKENS=$(echo "$INPUT" | jq -r '.context_tokens // 0')
CACHE_WARM=$(echo "$INPUT" | jq -r '.prompt_cache_warm // false')

PAYLOAD=$(jq -n \
  --arg fm "$FROM_MODEL" \
  --arg tm "$TO_MODEL" \
  --arg rm "$REQUESTED_MODEL" \
  --arg s "$SOURCE" \
  --argjson ct "${CONTEXT_TOKENS:-0}" \
  --argjson cw "${CACHE_WARM:-false}" \
  '{fromModel: $fm, toModel: $tm, source: $s, contextTokens: $ct, promptCacheWarm: $cw}
   | if $rm != "" then . + {requestedModel: $rm} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "model.switch" "$PAYLOAD" >/dev/null
