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
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
# DEV-94: per-invocation correlation id from PreToolUse hook. Used both as a
# payload field (for backend/dashboard pairing) and as part of the timing
# file path so concurrent same-tool calls don't overwrite each other's start
# timestamps. Empty string when the host Claude Code doesn't supply it.
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // ""')

# Privacy-aware tool input
if [ "$DEVSCOPE_PRIVACY" = "standard" ] || [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // null')
else
  # CWD is passed through so private-mode hashing can compute repo-relative
  # paths against the session's repo root (DEV-74).
  TOOL_INPUT=$(_ds_sanitize_tool_input "$TOOL_NAME" "$(echo "$INPUT" | jq -c '.tool_input // {}')" "$CWD")
fi

# Sanitize for safe temp file paths
SESSION_ID_SAFE=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
TOOL_NAME_SAFE=$(echo "$TOOL_NAME" | tr -cd 'a-zA-Z0-9_-')
TOOL_USE_ID_SAFE=$(echo "$TOOL_USE_ID" | tr -cd 'a-zA-Z0-9_-')

# Write start timestamp for duration calculation. DEV-94: prefer a
# tool_use_id-scoped path so concurrent same-tool calls each get their own
# timing file. Fall back to the legacy session+toolName path when the host
# doesn't supply tool_use_id (older Claude Code builds).
TIMING_DIR="${HOME}/.cache/devscope/timings"
mkdir -p -m 0700 "$TIMING_DIR"
if [ -n "$TOOL_USE_ID_SAFE" ]; then
  TIMING_FILE="${TIMING_DIR}/${SESSION_ID_SAFE}_${TOOL_USE_ID_SAFE}"
else
  TIMING_FILE="${TIMING_DIR}/${SESSION_ID_SAFE}_${TOOL_NAME_SAFE}"
fi
echo "$(_ds_now_ns)" > "$TIMING_FILE"

# Extract privacy-safe subcommand from raw input (before sanitization)
TOOL_SUBCOMMAND=$(_ds_extract_subcommand "$TOOL_NAME" "$(echo "$INPUT" | jq -c '.tool_input // {}')")

PAYLOAD=$(jq -n \
  --arg tn "$TOOL_NAME" \
  --arg ai "$AGENT_ID" \
  --argjson ti "${TOOL_INPUT:-null}" \
  --arg ts "$TOOL_SUBCOMMAND" \
  --arg tu "$TOOL_USE_ID" \
  '{toolName: $tn}
   | if $ai != "" then . + {agentId: $ai} else . end
   | if $ti != null then . + {toolInput: $ti} else . end
   | if $ts != "" then . + {toolSubcommand: $ts} else . end
   | if $tu != "" then . + {toolUseId: $tu} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "tool.start" "$PAYLOAD"
