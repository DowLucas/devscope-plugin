#!/usr/bin/env bash
# PostToolBatch — fires once after every tool call in a batch has resolved,
# before the next model request. PostToolUse fires per-tool (and concurrently
# for parallel calls); this gives us the batch as a unit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

BATCH_SIZE=$(echo "$INPUT" | jq -r '(.tool_calls // []) | length')
TOOL_NAMES=$(echo "$INPUT" | jq -c '[(.tool_calls // [])[] | .tool_name // empty]')

PAYLOAD=$(jq -n \
  --argjson bs "${BATCH_SIZE:-0}" \
  --argjson tn "${TOOL_NAMES:-[]}" \
  '{batchSize: $bs, toolNames: $tn}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "tool.batch" "$PAYLOAD" >/dev/null
