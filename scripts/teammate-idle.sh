#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

PAYLOAD=$(echo "$INPUT" | jq -c '{raw: .}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "teammate.idle" "$PAYLOAD"
