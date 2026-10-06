#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

LAST_MSG=$(echo "$INPUT" | jq -r '.last_assistant_message // ""' 2>/dev/null)
RESPONSE_LENGTH=${#LAST_MSG}

# Extract token usage from transcript JSONL
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
TOKEN_USAGE=$(_ds_extract_token_usage "$TRANSCRIPT_PATH")
USAGE_SNAPSHOT=$(_ds_usage_snapshot "$TRANSCRIPT_PATH")

if [ "$DEVSCOPE_PRIVACY" = "open" ]; then
  PAYLOAD=$(jq -n \
    --argjson rl "$RESPONSE_LENGTH" \
    --arg rt "$LAST_MSG" \
    --argjson tu "$TOKEN_USAGE" \
    --argjson us "$USAGE_SNAPSHOT" \
    '{responseLength: $rl, responseText: $rt}
     | if ($tu | length) > 0 then . + {tokenUsage: $tu} else . end
     | if ($us | length) > 0 then . + {usageSnapshot: $us} else . end')
else
  PAYLOAD=$(jq -n \
    --argjson rl "$RESPONSE_LENGTH" \
    --argjson tu "$TOKEN_USAGE" \
    --argjson us "$USAGE_SNAPSHOT" \
    '{responseLength: $rl}
     | if ($tu | length) > 0 then . + {tokenUsage: $tu} else . end
     | if ($us | length) > 0 then . + {usageSnapshot: $us} else . end')
fi

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "response.complete" "$PAYLOAD"
