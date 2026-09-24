#!/usr/bin/env bash
# Tests for scripts/error-recall.sh against a stub DevScope server.
#
#   bash tests/errors/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/scripts/error-recall.sh"
TMP=$(mktemp -d)
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/config"
unset DEVSCOPE_ERROR_RECALL DEVSCOPE_PRIVACY
# shellcheck disable=SC1091
. "$ROOT/tests/lib/stub.sh"
MATCH='{"matches": [{"day": "2026-07-01", "resolved": true}, {"day": "2026-06-02", "resolved": false}], "context": "DevScope: the user has hit a very similar error before:\n- 2026-07-01 ..."}'

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
input() {  # error [session] [interrupt]
  jq -n --arg e "$1" --arg s "${2:-sess-1}" --argjson i "${3:-false}" \
    '{session_id: $s, hook_event_name: "PostToolUseFailure", tool_name: "Bash",
      tool_input: {command: "bun run build"}, error: $e, is_interrupt: $i}'
}
ERR="bun: command not found: tsc (exit code 127)"

respond "$MATCH"; reset_hits
out=$(input "$ERR" | "$HOOK")
[ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = "PostToolUseFailure" ] && ok "match: event name" || bad "event name" "$out"
printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext | grep -q "very similar error before" && ok "match: note reaches Claude" || bad "note" "$out"
printf '%s' "$out" | jq -r .systemMessage | grep -q "(2x, 1 resolved)" && ok "match: user notice counts resolved" || bad "notice" "$out"
[ "$(last .path)" = "/api/similar/error" ] && ok "calls the error endpoint" || bad "path" "$(last .)"
[ "$(last .key)" = "test-key" ] && ok "sends the API key" || bad "api key" "$(last .)"
[ "$(last .body.tool)" = "Bash" ] && [ "$(last .body.error)" = "$ERR" ] && [ "$(last .body.session_id)" = "sess-1" ] \
  && ok "sends tool, error and session" || bad "body" "$(last .)"

reset_hits
[ -z "$(input "$ERR" | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "same error again in the session: silent, no request" || bad "dedupe" "hits=$(hits)"
[ -n "$(input "$ERR" sess-2 | "$HOOK")" ] && ok "same error in another session asks again" || bad "other session" "silent"
[ -n "$(input "$ERR (again, differently)" | "$HOOK")" ] && ok "a different error in the session asks" || bad "different error" "silent"

reset_hits
[ -z "$(input "Exit code 1" s3 | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "short error: silent, no request" || bad "short" "hits=$(hits)"
[ -z "$(input "$ERR" s4 true | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "interrupt: silent, no request" || bad "interrupt" "hits=$(hits)"
[ -z "$(input "$ERR" s5 | DEVSCOPE_ERROR_RECALL=off "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "off: silent, no request" || bad "off" "hits=$(hits)"
[ -z "$(input "$ERR" s6 | DEVSCOPE_PRIVACY=private "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "private mode: silent, no request" || bad "private" "hits=$(hits)"
mkdir -p "$XDG_CONFIG_HOME/devscope"; printf 'DEVSCOPE_ERROR_RECALL=off\n' > "$XDG_CONFIG_HOME/devscope/config"
[ -z "$(input "$ERR" s7 | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "off via config file" || bad "config off" "hits=$(hits)"
rm "$XDG_CONFIG_HOME/devscope/config"

respond '{"matches": [], "context": null}'
[ -z "$(input "$ERR" s8 | "$HOOK")" ] && ok "no match is silent" || bad "no match" "output"
respond "<html>oops</html>"
[ -z "$(input "$ERR" s9 | "$HOOK")" ] && ok "garbage response is silent" || bad "garbage" "output"
[ -z "$(input "$ERR" s10 | DEVSCOPE_URL=http://127.0.0.1:9 "$HOOK")" ] && ok "server down is silent" || bad "down" "output"
respond '{"context": "late"}'; slow
start=$(date +%s%N); out=$(input "$ERR" s11 | "$HOOK"); ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ -z "$out" ] && [ "$ms" -lt 3000 ] && ok "slow server gives up in ${ms}ms (< 3000)" || bad "slow" "${ms}ms out=$out"
[ -z "$(printf 'not json' | "$HOOK")" ] && ok "garbage stdin is silent" || bad "stdin" "output"

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
