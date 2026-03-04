#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

# Extract fields safely — no eval
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')

# Privacy-aware tool input
if [ "$DEVSCOPE_PRIVACY" = "standard" ] || [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // null')
else
  TOOL_INPUT=$(_ds_sanitize_tool_input "$TOOL_NAME" "$(echo "$INPUT" | jq -c '.tool_input // {}')")
fi

# Sanitize for safe temp file paths
SESSION_ID_SAFE=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
TOOL_NAME_SAFE=$(echo "$TOOL_NAME" | tr -cd 'a-zA-Z0-9_-')

# Write start timestamp for duration calculation
TIMING_DIR="${HOME}/.cache/devscope/timings"
mkdir -p -m 0700 "$TIMING_DIR"
echo "$(_ds_now_ns)" > "${TIMING_DIR}/${SESSION_ID_SAFE}_${TOOL_NAME_SAFE}"

PAYLOAD=$(jq -n \
  --arg tn "$TOOL_NAME" \
  --arg ai "$AGENT_ID" \
  --argjson ti "${TOOL_INPUT:-null}" \
  '{toolName: $tn} | if $ai != "" then . + {agentId: $ai} else . end | if $ti != null then . + {toolInput: $ti} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "tool.start" "$PAYLOAD"
