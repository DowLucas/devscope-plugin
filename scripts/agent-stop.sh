#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

AGENT_TYPE=$(echo "$INPUT" | jq -r '.agent_type // "unknown"')
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // ""')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# SubagentStop rich fields (DEV-95 / DowLucas/devscope#4).
# We capture only the LENGTH of the last assistant message — never the raw
# body — so subagent verbosity/output-volume can be analyzed without
# surfacing message content to other developers. The transcript path is a
# local-fs reference and is safe to store as metadata.
LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)
LAST_MSG_LENGTH=${#LAST_MSG}
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // ""' 2>/dev/null)

# Pop agent from stack and find parent
PARENT_AGENT_ID=""
if [ -n "$CWD" ] && [ -n "$AGENT_ID" ]; then
  HASH=$(_ds_project_hash "$CWD")
  STACK_FILE="${HOME}/.cache/devscope/${HASH}.agents"
  if [ -f "$STACK_FILE" ]; then
    # Remove only the last (most recent) occurrence of this agent (LIFO pop)
    TEMP=$(mktemp)
    LAST_LINE=$(grep -n -F -x -- "${AGENT_ID}" "$STACK_FILE" | tail -1 | cut -d: -f1 || true)
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

PAYLOAD=$(jq -n \
  --arg at "$AGENT_TYPE" \
  --arg ai "$AGENT_ID" \
  --arg pai "$PARENT_AGENT_ID" \
  --argjson lml "$LAST_MSG_LENGTH" \
  --arg tp "$TRANSCRIPT_PATH" \
  '{agentType: $at, agentId: $ai}
   | if $pai != "" then . + {parentAgentId: $pai} else . end
   | if $lml > 0 then . + {lastMessageLength: $lml} else . end
   | if $tp != "" then . + {transcriptPath: $tp} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "agent.stop" "$PAYLOAD"
