#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

# Sync vs async is decided here, at runtime, and it matters.
#
# PreToolUse is the only hook this plugin registers that can return a *decision*
# (`permissionDecision: "deny"`), and a decision is only honored on a synchronous
# response: an async hook is backgrounded and its late output is validated
# against a reduced schema (systemMessage / metrics /
# hookSpecificOutput.additionalContext), so a deny is silently discarded. That is
# why `async: true` is NOT set for PreToolUse in hooks.json.
#
# Staying synchronous on every tool call would put jq parsing and an HTTP POST in
# front of every tool, so unless hard-block mode is actually on we announce async
# on the first line of stdout. Claude Code sees it, backgrounds this process and
# stops waiting — everything below then runs detached, at no cost to the session.
# In hard mode we stay synchronous so the deny below can be honored.
if [ "${DEVSCOPE_NUDGE_MODE:-soft}" != "hard" ]; then
  printf '{"async": true}\n'
fi

# Extract fields safely — no eval
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

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

# Write start timestamp for duration calculation
TIMING_DIR="${HOME}/.cache/devscope/timings"
mkdir -p -m 0700 "$TIMING_DIR"
echo "$(_ds_now_ns)" > "${TIMING_DIR}/${SESSION_ID_SAFE}_${TOOL_NAME_SAFE}"

# Extract privacy-safe subcommand from raw input (before sanitization)
RAW_INPUT_JSON=$(echo "$INPUT" | jq -c '.tool_input // {}')
TOOL_SUBCOMMAND=$(_ds_extract_subcommand "$TOOL_NAME" "$RAW_INPUT_JSON")

# Stable input hash — must match the one tool-complete.sh emits.
TOOL_INPUT_HASH=$(_ds_tool_input_hash "$TOOL_NAME" "$RAW_INPUT_JSON")

# Hard-block check: ask the backend whether this exact (tool, input) has
# already failed enough times to deny. Fail-open on any error or in soft mode.
if [ "$DEVSCOPE_NUDGE_MODE" = "hard" ] && [ -n "$SESSION_ID" ]; then
  CHECK_BODY=$(jq -n \
    --arg sid "$SESSION_ID" \
    --arg tn "$TOOL_NAME" \
    --arg tih "$TOOL_INPUT_HASH" \
    '{session_id: $sid, tool_name: $tn, tool_input_hash: $tih}')

  CURL_CONFIG=""
  if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
    CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
  fi
  CHECK_RESP=$(echo "$CURL_CONFIG" | curl --config - -s -X POST "${DEVSCOPE_URL}/api/nudges/check" \
    -H "Content-Type: application/json" \
    -d "$CHECK_BODY" \
    --max-time 2 \
    2>/dev/null || true)

  if [ -n "$CHECK_RESP" ]; then
    BLOCK=$(printf '%s' "$CHECK_RESP" | jq -r '.block // false' 2>/dev/null || echo "false")
    if [ "$BLOCK" = "true" ]; then
      REASON=$(printf '%s' "$CHECK_RESP" | jq -r '.reason // "DevScope: this call has failed repeatedly. Try a different approach."' 2>/dev/null)
      # PreToolUse decision JSON. Only reachable in hard mode, where we did not
      # announce async above and Claude Code is still waiting on us — so this is
      # honored: the call is denied and `permissionDecisionReason` reaches the
      # model.
      jq -n --arg r "$REASON" '{
        hookSpecificOutput: {
          hookEventName: "PreToolUse",
          permissionDecision: "deny",
          permissionDecisionReason: $r
        }
      }'
      exit 0
    fi
  fi
fi

PAYLOAD=$(jq -n \
  --arg tn "$TOOL_NAME" \
  --arg ai "$AGENT_ID" \
  --argjson ti "${TOOL_INPUT:-null}" \
  --arg ts "$TOOL_SUBCOMMAND" \
  --arg tih "$TOOL_INPUT_HASH" \
  '{toolName: $tn}
   | if $ai != "" then . + {agentId: $ai} else . end
   | if $ti != null then . + {toolInput: $ti} else . end
   | if $ts != "" then . + {toolSubcommand: $ts} else . end
   | . + {toolInputHash: $tih}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "tool.start" "$PAYLOAD" >/dev/null
exit 0
