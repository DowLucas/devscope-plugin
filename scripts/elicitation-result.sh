#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

MCP_SERVER=$(echo "$INPUT" | jq -r '.mcp_server_name // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
RESPONDED=$(echo "$INPUT" | jq -r 'if .response != null then true else false end')

RESPONSE=""
if [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  RESPONSE=$(echo "$INPUT" | jq -r '.response // ""')
fi

# Compute duration from timing file
DURATION=0
SESSION_ID_SAFE=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
MCP_SAFE=$(echo "$MCP_SERVER" | tr -cd 'a-zA-Z0-9_-')
TIMING_FILE="${HOME}/.cache/devscope/timings/elicit_${SESSION_ID_SAFE}_${MCP_SAFE}"
if [ -f "$TIMING_FILE" ]; then
  START_NS=$(cat "$TIMING_FILE")
  END_NS=$(_ds_now_ns)
  if [ -n "$START_NS" ] && [ -n "$END_NS" ]; then
    DURATION=$(( (END_NS - START_NS) / 1000000 ))  # nanoseconds to milliseconds
  fi
  rm -f "$TIMING_FILE"
fi

PAYLOAD=$(jq -n \
  --arg ms "$MCP_SERVER" \
  --argjson dur "$DURATION" \
  --argjson resp "$RESPONDED" \
  --arg r "$RESPONSE" \
  '{mcpServerName: $ms, duration: $dur, responded: $resp}
   | if $r != "" then . + {response: $r} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "elicitation.response" "$PAYLOAD"
