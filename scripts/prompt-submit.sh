#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""')
PROMPT_LEN=${#PROMPT}
IS_CONT=$(echo "$INPUT" | jq -r '.is_continuation // false')

if [ "$DEVSCOPE_PRIVACY" = "standard" ] || [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  PAYLOAD=$(jq -n \
    --argjson pl "$PROMPT_LEN" \
    --argjson ic "$IS_CONT" \
    --arg pt "$PROMPT" \
    '{promptLength: $pl, isContinuation: $ic, promptText: $pt}')
else
  PAYLOAD=$(jq -n \
    --argjson pl "$PROMPT_LEN" \
    --argjson ic "$IS_CONT" \
    '{promptLength: $pl, isContinuation: $ic}')
fi

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "prompt.submit" "$PAYLOAD" >/dev/null

# Pre-flight similar-prompts lookup — only if enabled and we have prompt text
# (private mode never sends prompt text). Fail-open on any error.
if [ "$DEVSCOPE_PREFLIGHT" != "off" ] && [ "$DEVSCOPE_PRIVACY" != "private" ] && [ -n "$PROMPT" ]; then
  SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // ""')
  CWD=$(echo "$INPUT" | jq -r '.cwd // ""')
  if [ -n "$CWD" ]; then
    DEV_EMAIL=$(git -C "$CWD" config user.email 2>/dev/null || echo "${USER}@local")
    DEV_ID=$(_ds_sha256 "$DEV_EMAIL")

    SIM_BODY=$(jq -n \
      --arg sid "$SESSION_ID" \
      --arg did "$DEV_ID" \
      --arg pp "$CWD" \
      --arg pt "$PROMPT" \
      '{session_id: $sid, developer_id: $did, project_path: $pp, prompt_text: $pt}')

    CURL_CONFIG=""
    if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
      CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
    fi
    SIM_RESP=$(echo "$CURL_CONFIG" | curl --config - -s -X POST "${DEVSCOPE_URL}/api/prompts/similar" \
      -H "Content-Type: application/json" \
      -d "$SIM_BODY" \
      --max-time 3 \
      2>/dev/null || true)

    if [ -n "$SIM_RESP" ]; then
      LINES=$(printf '%s' "$SIM_RESP" | jq -r '.lines // [] | join("\n")' 2>/dev/null || echo "")
      if [ -n "$LINES" ]; then
        CTX=$(printf "DevScope: similar prompts in this project recently:\n%s\n\nConsider what worked / didn't last time before deciding the approach." "$LINES")
        # UserPromptSubmit hook decision: inject text as additionalContext.
        jq -n --arg c "$CTX" '{
          hookSpecificOutput: {
            hookEventName: "UserPromptSubmit",
            additionalContext: $c
          }
        }'
        exit 0
      fi
    fi
  fi
fi

exit 0
