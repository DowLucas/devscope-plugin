#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

# Privacy-aware tool input. Mirrors tool-use.sh: in standard/open we keep the
# full tool_input; in private we run it through the existing redaction helper
# so paths/patterns are hashed and Bash command / Write content / Edit args
# are dropped (only whitelisted metadata keys survive). Skip permission_suggestions
# per the upstream issue's guidance — low signal vs. payload size.
if [ "$DEVSCOPE_PRIVACY" = "standard" ] || [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // null')
else
  TOOL_INPUT=$(_ds_sanitize_tool_input "$TOOL_NAME" "$(echo "$INPUT" | jq -c '.tool_input // {}')" "$CWD")
fi

PAYLOAD=$(jq -n \
  --arg tn "$TOOL_NAME" \
  --argjson ti "${TOOL_INPUT:-null}" \
  '{toolName: $tn} | if $ti != null then . + {toolInput: $ti} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "permission.request" "$PAYLOAD"
