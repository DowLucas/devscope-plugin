#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

SUMMARY=""
if [ "$DEVSCOPE_PRIVACY" != "private" ]; then
  SUMMARY=$(echo "$INPUT" | jq -r '.summary // ""')
fi

TOKENS_BEFORE=$(echo "$INPUT" | jq -r '.stats.tokens_before // .tokens_before // 0')
TOKENS_AFTER=$(echo "$INPUT" | jq -r '.stats.tokens_after // .tokens_after // 0')

# Compute reduction percentage
REDUCTION=0
if [ "$TOKENS_BEFORE" -gt 0 ] 2>/dev/null; then
  REDUCTION=$(( (TOKENS_BEFORE - TOKENS_AFTER) * 100 / TOKENS_BEFORE ))
fi

PAYLOAD=$(jq -n \
  --arg s "$SUMMARY" \
  --argjson tb "$TOKENS_BEFORE" \
  --argjson ta "$TOKENS_AFTER" \
  --argjson rp "$REDUCTION" \
  '{tokensBefore: $tb, tokensAfter: $ta, reductionPercent: $rp}
   | if $s != "" then . + {summary: $s} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "compact.complete" "$PAYLOAD"
