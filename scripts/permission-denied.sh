#!/usr/bin/env bash
# PermissionDenied — a tool call was denied. Complements permission.request.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
TOOL_USE_ID=$(echo "$INPUT" | jq -r '.tool_use_id // ""')
REASON=$(echo "$INPUT" | jq -r '.reason // "" | .[:300]')
TOOL_SUBCOMMAND=$(_ds_extract_subcommand "$TOOL_NAME" "$(echo "$INPUT" | jq -c '.tool_input // {}')")

PAYLOAD=$(jq -n \
  --arg tn "$TOOL_NAME" \
  --arg tui "$TOOL_USE_ID" \
  --arg r "$REASON" \
  --arg ts "$TOOL_SUBCOMMAND" \
  '{toolName: $tn, toolUseId: $tui, reason: $r}
   | if $ts != "" then . + {toolSubcommand: $ts} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "permission.denied" "$PAYLOAD" >/dev/null
