#!/usr/bin/env bash
# Tests for scripts/prompt-recall.sh against a stub DevScope server.
#
#   bash tests/recall/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/scripts/prompt-recall.sh"
TMP=$(mktemp -d)
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/config"
unset DEVSCOPE_PREFLIGHT DEVSCOPE_PRIVACY
# shellcheck disable=SC1091
. "$ROOT/tests/lib/stub.sh"
MATCH='{"matches": [{"day": "2026-09-12"}, {"day": "2026-09-03"}], "repeat_days": 2, "context": "DevScope: the user has asked something very similar before:\n- 2026-09-12 ..."}'

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
input() { jq -n --arg p "$1" '{session_id: "sess-1", hook_event_name: "UserPromptSubmit", prompt: $p}'; }
LONG="deploy the android build to the play store internal track"

respond "$MATCH"; reset_hits
out=$(input "$LONG" | "$HOOK")
[ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = "UserPromptSubmit" ] && ok "match: event name" || bad "match: event name" "$out"
printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext | grep -q "asked something very similar" && ok "match: note reaches Claude" || bad "match: note" "$out"
printf '%s' "$out" | jq -r .systemMessage | grep -q "2026-09-12, 2026-09-03" && ok "match: user notice lists the days" || bad "match: notice" "$out"
[ "$(last .path)" = "/api/similar/preflight" ] && ok "calls the preflight endpoint" || bad "path" "$(last .)"
[ "$(last .key)" = "test-key" ] && ok "sends the API key" || bad "api key" "$(last .)"
[ "$(last .body.prompt)" = "$LONG" ] && [ "$(last .body.session_id)" = "sess-1" ] && ok "sends prompt and session" || bad "body" "$(last .)"

respond '{"matches": [], "repeat_days": 0, "context": null}'
[ -z "$(input "$LONG" | "$HOOK")" ] && ok "no match is silent" || bad "no match" "output"
respond "<html>oops</html>"
[ -z "$(input "$LONG" | "$HOOK")" ] && ok "garbage response is silent" || bad "garbage" "output"

respond "$MATCH"; reset_hits
[ -z "$(input "yes continue" | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "short prompt: silent, no request" || bad "short prompt" "hits=$(hits)"
[ -z "$(input "$LONG" | DEVSCOPE_PREFLIGHT=off "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "off: silent, no request" || bad "off" "hits=$(hits)"
[ -z "$(input "$LONG" | DEVSCOPE_PRIVACY=private "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "private mode: silent, no request" || bad "private" "hits=$(hits)"
mkdir -p "$XDG_CONFIG_HOME/devscope"; printf 'DEVSCOPE_PREFLIGHT=off\n' > "$XDG_CONFIG_HOME/devscope/config"
[ -z "$(input "$LONG" | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "off via config file" || bad "config off" "hits=$(hits)"
rm "$XDG_CONFIG_HOME/devscope/config"

[ -z "$(input "$LONG" | DEVSCOPE_URL=http://127.0.0.1:9 "$HOOK")" ] && ok "server down is silent" || bad "down" "output"
respond '{"context": "late"}'; slow
start=$(date +%s%N); out=$(input "$LONG" | "$HOOK"); ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ -z "$out" ] && [ "$ms" -lt 3000 ] && ok "slow server gives up in ${ms}ms (< 3000)" || bad "slow" "${ms}ms out=$out"
[ -z "$(printf 'not json' | "$HOOK")" ] && ok "garbage stdin is silent" || bad "stdin" "output"

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
