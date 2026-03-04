#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

# Extract fields safely — no eval
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
HOOK_EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "PostToolUse"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
ERROR_MSG_SHORT=$(echo "$INPUT" | jq -r '.error // "" | tostring | .[:100]')
ERROR_MSG_FULL=$(echo "$INPUT" | jq -r '.error // "" | tostring | .[:500]')
IS_INTERRUPT=$(echo "$INPUT" | jq -r '.is_interrupt // false')

# Privacy-aware tool input
if [ "$DEVSCOPE_PRIVACY" = "full" ]; then
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // null')
else
  TOOL_INPUT=$(_ds_sanitize_tool_input "$TOOL_NAME" "$(echo "$INPUT" | jq -c '.tool_input // {}')")
fi

# Sanitize for safe temp file paths
SESSION_ID_SAFE=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
TOOL_NAME_SAFE=$(echo "$TOOL_NAME" | tr -cd 'a-zA-Z0-9_-')

# Calculate duration from start timestamp
DURATION_MS=0
TIMING_DIR="${HOME}/.cache/devscope/timings"
TIMING_FILE="${TIMING_DIR}/${SESSION_ID_SAFE}_${TOOL_NAME_SAFE}"
if [ -f "$TIMING_FILE" ]; then
  START_NS=$(cat "$TIMING_FILE")
  NOW_NS=$(_ds_now_ns)
  DURATION_MS=$(( (NOW_NS - START_NS) / 1000000 ))
  rm -f "$TIMING_FILE"
fi

if [ "$HOOK_EVENT" = "PostToolUseFailure" ]; then
  SUCCESS=false
  EVENT_TYPE="tool.fail"
  # Use full error in standard/full mode, short in redacted mode
  if [ "$DEVSCOPE_PRIVACY" = "redacted" ]; then
    ERROR_MSG="$ERROR_MSG_SHORT"
  else
    ERROR_MSG="$ERROR_MSG_FULL"
  fi
else
  SUCCESS=true
  EVENT_TYPE="tool.complete"
  ERROR_MSG=""
  IS_INTERRUPT="false"
fi

# Track file changes for Write/Edit tools
if [ "$SUCCESS" = "true" ] && { [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; }; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  if [ -n "$FILE_PATH" ] && [ -n "$CWD" ]; then
    _FC_HASH=$(_ds_project_hash "$CWD")
    mkdir -p "${HOME}/.cache/devscope"
    if [ "$DEVSCOPE_PRIVACY" = "redacted" ]; then
      echo "[redacted]" >> "${HOME}/.cache/devscope/${_FC_HASH}.files"
    else
      echo "$FILE_PATH" >> "${HOME}/.cache/devscope/${_FC_HASH}.files"
    fi
  fi
fi

PAYLOAD=$(jq -n \
  --arg tn "$TOOL_NAME" \
  --argjson s "$SUCCESS" \
  --argjson d "$DURATION_MS" \
  --arg em "$ERROR_MSG" \
  --arg ai "$AGENT_ID" \
  --argjson ti "${TOOL_INPUT:-null}" \
  --argjson intr "$IS_INTERRUPT" \
  '{toolName: $tn, success: $s, duration: $d}
   | if $em != "" then . + {errorMessage: $em} else . end
   | if $ai != "" then . + {agentId: $ai} else . end
   | if $ti != null then . + {toolInput: $ti} else . end
   | if $intr == true then . + {isInterrupt: true} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "$EVENT_TYPE" "$PAYLOAD"
