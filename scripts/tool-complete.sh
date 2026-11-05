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
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Privacy-aware tool input
if [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // null')
else
  # CWD is passed through so private-mode hashing can compute repo-relative
  # paths against the session's repo root (DEV-74).
  TOOL_INPUT=$(_ds_sanitize_tool_input "$TOOL_NAME" "$(echo "$INPUT" | jq -c '.tool_input // {}')" "$CWD")
fi

# Privacy-aware tool result (same gating as tool_input)
if [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  # Open mode: full result, truncated to 5KB
  _TR_RAW=$(echo "$INPUT" | jq -c 'if .tool_result == null then null else (.tool_result | tostring | .[:5000]) end' 2>/dev/null || echo "null")
  if [ "$_TR_RAW" = "null" ]; then
    TOOL_RESULT="null"
  else
    TOOL_RESULT=$(jq -n --arg r "$_TR_RAW" '$r')
  fi
elif [ "$DEVSCOPE_PRIVACY" = "standard" ]; then
  # Standard mode: sanitize result same as tool_input
  _TR_RAW=$(echo "$INPUT" | jq -c '.tool_result // null' 2>/dev/null || echo "null")
  if [ "$_TR_RAW" = "null" ]; then
    TOOL_RESULT="null"
  else
    TOOL_RESULT=$(_ds_sanitize_tool_result "$TOOL_NAME" "$_TR_RAW")
  fi
else
  # Private mode: no tool result
  TOOL_RESULT="null"
fi

# Sanitize for safe temp file paths
SESSION_ID_SAFE=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
TOOL_NAME_SAFE=$(echo "$TOOL_NAME" | tr -cd 'a-zA-Z0-9_-')

# Duration: Claude Code's own `duration_ms` (2.1.318+) when present, else the
# start timestamp tool-use.sh wrote (keyed by tool_use_id, see there). The file
# is removed either way so it does not pile up.
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // ""')
TOOL_USE_ID_SAFE=$(printf '%s' "$TOOL_USE_ID" | tr -cd 'a-zA-Z0-9_-')
DURATION_MS=0
TIMING_DIR="${HOME}/.cache/devscope/timings"
TIMING_FILE="${TIMING_DIR}/${TOOL_USE_ID_SAFE:-${SESSION_ID_SAFE}_${TOOL_NAME_SAFE}}"
if [ -f "$TIMING_FILE" ]; then
  START_NS=$(cat "$TIMING_FILE")
  NOW_NS=$(_ds_now_ns)
  DURATION_MS=$(( (NOW_NS - START_NS) / 1000000 ))
  rm -f "$TIMING_FILE"
fi
CC_DURATION_MS=$(echo "$INPUT" | jq -r '.duration_ms // empty | numbers | floor' 2>/dev/null || true)
[ -n "$CC_DURATION_MS" ] && DURATION_MS="$CC_DURATION_MS"

# Bash command timing (command_runs on the server): a signature instead of the
# command, and whether it went to the background. A backgrounded command's
# PostToolUse fires when it is backgrounded, so its total time is only known
# when it settles; bg_commands.py finds that in the transcript at Stop and
# SessionEnd, and the marker below tells it this session has some to look for.
COMMAND_SIGNATURE=""
BG_TASK_ID=""
RUN_IN_BG=false
if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND_SIGNATURE=$(_ds_command_signature "$(echo "$INPUT" | jq -c '.tool_input // {}')")
  RUN_IN_BG=$(echo "$INPUT" | jq -r '.tool_input.run_in_background == true')
  BG_TASK_ID=$(echo "$INPUT" | jq -r '(.tool_response // .tool_result // {}) | objects | .backgroundTaskId // ""' 2>/dev/null || true)
  if [ -n "$BG_TASK_ID" ] && [ -n "$SESSION_ID_SAFE" ]; then
    _DS_BG_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/devscope/bg"
    mkdir -p -m 0700 "$_DS_BG_DIR" 2>/dev/null && touch "$_DS_BG_DIR/${SESSION_ID_SAFE}.active" 2>/dev/null || true
  fi
fi

if [ "$HOOK_EVENT" = "PostToolUseFailure" ]; then
  SUCCESS=false
  EVENT_TYPE="tool.fail"
  # Use full error in standard/open mode, short in private mode
  if [ "$DEVSCOPE_PRIVACY" = "private" ]; then
    ERROR_MSG="$ERROR_MSG_SHORT"
  else
    ERROR_MSG="$ERROR_MSG_FULL"
  fi
else
  SUCCESS=true
  EVENT_TYPE="tool.complete"
  ERROR_MSG=""
fi

# Track file changes for Write/Edit tools
if [ "$SUCCESS" = "true" ] && { [ "$TOOL_NAME" = "Write" ] || [ "$TOOL_NAME" = "Edit" ]; }; then
  FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
  CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
  if [ -n "$FILE_PATH" ] && [ -n "$CWD" ]; then
    _FC_HASH=$(_ds_project_hash "$CWD")
    mkdir -p "${HOME}/.cache/devscope"
    if [ "$DEVSCOPE_PRIVACY" = "private" ]; then
      _FILE_HASH=$(_ds_sha256 "$FILE_PATH")
      echo "[redacted:${_FILE_HASH:0:12}]" >> "${HOME}/.cache/devscope/${_FC_HASH}.files"
    else
      echo "$FILE_PATH" >> "${HOME}/.cache/devscope/${_FC_HASH}.files"
    fi
  fi
fi

# Extract privacy-safe subcommand from raw input (before sanitization)
RAW_INPUT_JSON=$(echo "$INPUT" | jq -c '.tool_input // {}')
TOOL_SUBCOMMAND=$(_ds_extract_subcommand "$TOOL_NAME" "$RAW_INPUT_JSON")

# Stable input hash so PreToolUse and PostToolUse agree on identity.
# Hashing the raw (pre-sanitization) input keeps PreToolUse fast — it doesn't
# need to sanitize before checking.
TOOL_INPUT_HASH=$(_ds_tool_input_hash "$TOOL_NAME" "$RAW_INPUT_JSON")

PAYLOAD=$(jq -n \
  --arg tn "$TOOL_NAME" \
  --argjson s "$SUCCESS" \
  --argjson d "$DURATION_MS" \
  --arg em "$ERROR_MSG" \
  --arg ai "$AGENT_ID" \
  --argjson ti "${TOOL_INPUT:-null}" \
  --argjson tr "${TOOL_RESULT:-null}" \
  --argjson intr "$IS_INTERRUPT" \
  --arg ts "$TOOL_SUBCOMMAND" \
  --arg tih "$TOOL_INPUT_HASH" \
  --arg tuid "$TOOL_USE_ID" \
  --arg cs "$COMMAND_SIGNATURE" \
  --arg bg "$BG_TASK_ID" \
  --argjson rib "$RUN_IN_BG" \
  '{toolName: $tn, success: $s, duration: $d}
   | if $em != "" then . + {errorMessage: $em} else . end
   | if $ai != "" then . + {agentId: $ai} else . end
   | if $ti != null then . + {toolInput: $ti} else . end
   | if $tr != null then . + {toolResult: $tr} else . end
   | . + {isInterrupt: $intr}
   | if $ts != "" then . + {toolSubcommand: $ts} else . end
   | . + {toolInputHash: $tih}
   | if $tuid != "" then . + {toolUseId: $tuid} else . end
   | if $cs != "" then . + {commandSignature: $cs} else . end
   | if $bg != "" then . + {backgroundTaskId: $bg, runInBackground: $rib} else . end')

# Send the event and capture the backend's response body so we can surface
# soft nudges back into Claude's session via stderr (exit 2 → system message).
RESP=$(echo "$INPUT" | DS_AWAIT_BODY=1 DS_TIMEOUT_SEC=3 "$SCRIPT_DIR/send-event.sh" "$EVENT_TYPE" "$PAYLOAD" 2>/dev/null || true)

if [ "$DEVSCOPE_NUDGE_MODE" != "off" ] && [ -n "$RESP" ]; then
  NUDGE_TYPE=$(printf '%s' "$RESP" | jq -r '.nudge.type // empty' 2>/dev/null || echo "")
  if [ "$NUDGE_TYPE" = "soft" ]; then
    NUDGE_MSG=$(printf '%s' "$RESP" | jq -r '.nudge.message // empty' 2>/dev/null || echo "")
    if [ -n "$NUDGE_MSG" ]; then
      # PostToolUse: exit 2 with stderr message → Claude Code surfaces this
      # back to the AI as a system message.
      printf '%s\n' "$NUDGE_MSG" >&2
      exit 2
    fi
  fi
fi

exit 0
