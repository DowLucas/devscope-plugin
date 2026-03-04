#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Detect parent agent via agent stack
PARENT_AGENT_ID=""
if [ -n "$CWD" ] && [ -n "$AGENT_ID" ]; then
  HASH=$(_ds_project_hash "$CWD")
  STACK_FILE="${HOME}/.cache/devscope/${HASH}.agents"
  # Current top of stack is the parent
  if [ -f "$STACK_FILE" ]; then
    PARENT_AGENT_ID=$(tail -1 "$STACK_FILE" 2>/dev/null || echo "")
  fi
  # Push this agent onto the stack
  echo "$AGENT_ID" >> "$STACK_FILE"
fi

PAYLOAD=$(jq -n --arg at "$AGENT_TYPE" --arg ai "$AGENT_ID" --arg pai "$PARENT_AGENT_ID" \
  '{agentType: $at, agentId: $ai}
   | if $pai != "" then . + {parentAgentId: $pai} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "agent.start" "$PAYLOAD"
