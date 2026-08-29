#!/usr/bin/env bash
# TaskCreated — pairs with task.completed for task lifecycle timing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT=$(cat)

TASK_ID=$(echo "$INPUT" | jq -r '.task_id // ""')
TASK_SUBJECT=$(echo "$INPUT" | jq -r '.task_subject // ""')
TASK_DESCRIPTION=$(echo "$INPUT" | jq -r '.task_description // ""')
TEAMMATE_NAME=$(echo "$INPUT" | jq -r '.teammate_name // ""')

PAYLOAD=$(jq -n \
  --arg tid "$TASK_ID" \
  --arg ts "$TASK_SUBJECT" \
  --arg td "$TASK_DESCRIPTION" \
  --arg tn "$TEAMMATE_NAME" \
  '{taskId: $tid, taskSubject: $ts, taskDescription: $td, teammateName: $tn}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "task.created" "$PAYLOAD" >/dev/null
