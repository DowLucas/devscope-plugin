#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Pop agent from stack and find parent
PARENT_AGENT_ID=""
if [ -n "$CWD" ] && [ -n "$AGENT_ID" ]; then
  HASH=$(_ds_project_hash "$CWD")
  STACK_FILE="${HOME}/.cache/devscope/${HASH}.agents"
  if [ -f "$STACK_FILE" ]; then
    # Remove only the last (most recent) occurrence of this agent (LIFO pop)
    TEMP=$(mktemp)
    LAST_LINE=$(grep -n "^${AGENT_ID}$" "$STACK_FILE" | tail -1 | cut -d: -f1 || true)
    if [ -n "$LAST_LINE" ]; then
      sed "${LAST_LINE}d" "$STACK_FILE" > "$TEMP"
      mv "$TEMP" "$STACK_FILE"
    else
      rm -f "$TEMP"
    fi
    # New top of stack is the parent (the agent we're returning to)
    PARENT_AGENT_ID=$(tail -1 "$STACK_FILE" 2>/dev/null || echo "")
    # Clean up empty stack file
    [ ! -s "$STACK_FILE" ] && rm -f "$STACK_FILE"
  fi
fi

PAYLOAD=$(jq -n --arg at "$AGENT_TYPE" --arg ai "$AGENT_ID" --arg pai "$PARENT_AGENT_ID" \
  '{agentType: $at, agentId: $ai}
   | if $pai != "" then . + {parentAgentId: $pai} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "agent.stop" "$PAYLOAD"
