#!/usr/bin/env bash
# UserPromptExpansion — a slash command or MCP prompt is being expanded.
# The prompt body itself is deliberately not sent; only which command ran.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

EXPANSION_TYPE=$(echo "$INPUT" | jq -r '.expansion_type // ""')
COMMAND_NAME=$(echo "$INPUT" | jq -r '.command_name // ""')
COMMAND_SOURCE=$(echo "$INPUT" | jq -r '.command_source // ""')
ARGS_LENGTH=$(echo "$INPUT" | jq -r '(.command_args // "") | length')

PAYLOAD=$(jq -n \
  --arg et "$EXPANSION_TYPE" \
  --arg cn "$COMMAND_NAME" \
  --arg cs "$COMMAND_SOURCE" \
  --argjson al "${ARGS_LENGTH:-0}" \
  '{expansionType: $et, commandName: $cn, commandSource: $cs, argsLength: $al}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "prompt.expansion" "$PAYLOAD" >/dev/null
