#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

MCP_SERVER=$(echo "$INPUT" | jq -r '.mcp_server_name // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')

MESSAGE=""
if [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  MESSAGE=$(echo "$INPUT" | jq -r '.message // ""')
fi

# Write timing file for duration calculation in elicitation-result.sh
SESSION_ID_SAFE=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
MCP_SAFE=$(echo "$MCP_SERVER" | tr -cd 'a-zA-Z0-9_-')
TIMING_DIR="${HOME}/.cache/devscope/timings"
mkdir -p -m 0700 "$TIMING_DIR"
echo "$(_ds_now_ns)" > "${TIMING_DIR}/elicit_${SESSION_ID_SAFE}_${MCP_SAFE}"

PAYLOAD=$(jq -n \
  --arg ms "$MCP_SERVER" \
  --arg m "$MESSAGE" \
  '{mcpServerName: $ms}
   | if $m != "" then . + {message: $m} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "elicitation.request" "$PAYLOAD"
