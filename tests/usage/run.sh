#!/usr/bin/env bash
# Tests for exact token usage (scripts/token_usage.py) and how the Stop and
# SessionEnd hooks send it, against a stub DevScope server.
#
#   bash tests/usage/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/config" XDG_CACHE_HOME="$TMP/cache"
unset DEVSCOPE_PRIVACY
# shellcheck disable=SC1091
. "$ROOT/tests/lib/stub.sh"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }

SID="11111111-2222-3333-4444-555555555555"
PROJ="$TMP/projects/-repo"; mkdir -p "$PROJ/$SID/subagents"
T="$PROJ/$SID.jsonl"

# call ID MODEL IN OUT W5 W1 READ [SESSION]: one assistant entry with usage.
call() {
  jq -cn --arg id "$1" --arg m "$2" --arg s "${8:-$SID}" \
    --argjson i "$3" --argjson o "$4" --argjson w5 "$5" --argjson w1 "$6" --argjson r "$7" \
    '{type: "assistant", sessionId: $s, requestId: ("req-" + $id),
      message: {id: $id, model: $m, content: [{type: "text", text: "x\ny"}],
        usage: {input_tokens: $i, output_tokens: $o, cache_read_input_tokens: $r,
                cache_creation_input_tokens: ($w5 + $w1),
                cache_creation: {ephemeral_5m_input_tokens: $w5, ephemeral_1h_input_tokens: $w1}}}}'
}
{
  echo '{"type":"user","sessionId":"'"$SID"'","message":{"role":"user","content":"hi"}}'
  call m1 claude-opus-5-5 2 100 0 1000 5000
  # The same call logged once per content block: counted once, last line wins.
  call m2 claude-opus-5-5 2 10 0 0 6000
  call m2 claude-opus-5-5 2 300 0 500 6000
  call m3 "<synthetic>" 0 0 0 0 0
  # An entry from another session (e.g. a resumed transcript) is ignored.
  call m4 claude-opus-5-5 9 9999 0 0 0 other-session
  echo 'not json'
} > "$T"
call s1 claude-haiku-4-5 1 50 20 0 700 > "$PROJ/$SID/subagents/agent-a1.jsonl"

snap() { python3 "$ROOT/scripts/token_usage.py" snapshot "$1"; }
out=$(snap "$T")
[ "$(jq -r .transcriptId <<<"$out")" = "$SID" ] && ok "transcript id is the Claude session id" || bad "id" "$out"
[ "$(jq -c '.byModel["claude-opus-5-5"]' <<<"$out")" = '{"input":4,"output":400,"cacheWrite5m":0,"cacheWrite1h":1500,"cacheRead":11000,"calls":2}' ] \
  && ok "sums every call once, splits 5m/1h writes, skips synthetic and foreign entries" || bad "opus totals" "$out"
[ "$(jq -c '.byModel["claude-haiku-4-5"]' <<<"$out")" = '{"input":1,"output":50,"cacheWrite5m":20,"cacheWrite1h":0,"cacheRead":700,"calls":1}' ] \
  && ok "includes subagent transcripts under their own model" || bad "subagent" "$out"

call m5 claude-opus-5-5 2 1000 0 0 7000 >> "$T"
printf '%s' '{"type":"assistant","sessionId":"'"$SID"'","message":{"id":"m6"' >> "$T"   # half-written line
out=$(snap "$T")
[ "$(jq '.byModel["claude-opus-5-5"].output' <<<"$out")" = 1400 ] && ok "incremental: picks up appended calls, waits for a complete line" || bad "incremental" "$out"
rm -rf "$XDG_CACHE_HOME"
[ "$(jq '.byModel["claude-opus-5-5"].output' <<<"$(snap "$T")")" = 1400 ] && ok "fresh parse agrees with the cached one" || bad "fresh" "$(snap "$T")"
[ "$(snap "$TMP/missing.jsonl")" = "{}" ] && ok "missing transcript gives {}" || bad "missing" "$(snap "$TMP/missing.jsonl")"

hook() {  # script event-name
  jq -cn --arg s "$SID" --arg t "$T" --arg cwd "$TMP" --arg e "$2" \
    '{session_id: $s, transcript_path: $t, cwd: $cwd, hook_event_name: $e, last_assistant_message: "done", reason: "other"}' \
    | "$ROOT/scripts/$1"
}
respond '{"ok": true}'; reset_hits
hook response-stop.sh Stop
[ "$(last .path)" = "/api/events" ] && [ "$(last .body.eventType)" = "response.complete" ] && ok "Stop posts response.complete" || bad "stop path" "$(last .)"
[ "$(last '.body.payload.usageSnapshot.byModel["claude-opus-5-5"].calls')" = 3 ] && ok "Stop carries the exact usageSnapshot" || bad "stop snapshot" "$(last .body.payload)"
[ "$(last '.body.payload.tokenUsage.outputTokens')" = 1000 ] && ok "Stop keeps the last-call tokenUsage for older servers" || bad "stop legacy" "$(last .body.payload)"
[ -f "$XDG_CACHE_HOME/devscope/usage/$SID.json" ] && ok "Stop leaves an incremental parse cache" || bad "cache" "missing"
hook session-end.sh SessionEnd
[ "$(last .body.eventType)" = "session.end" ] && [ "$(last '.body.payload.usageSnapshot.transcriptId')" = "$SID" ] \
  && ok "SessionEnd carries the usageSnapshot" || bad "end snapshot" "$(last .body.payload)"
[ ! -f "$XDG_CACHE_HOME/devscope/usage/$SID.json" ] && ok "SessionEnd removes the parse cache" || bad "cache cleanup" "still there"

# /devscope:backfill-usage upload
respond '{"applied": 1, "skipped": 0}'; reset_hits
out=$(python3 "$ROOT/scripts/token_usage.py" upload "$TMP/projects")
[ "$(jq -c . <<<"$out")" = '{"transcripts":1,"withUsage":1,"applied":1,"skipped":0}' ] && ok "upload reports totals" || bad "upload" "$out"
[ "$(last .path)" = "/api/sessions/usage/backfill" ] && [ "$(last .key)" = "test-key" ] && ok "upload posts to the backfill endpoint with the key" || bad "upload path" "$(last .)"
[ "$(last '.body.items[0].byModel["claude-opus-5-5"].output')" = 1400 ] && ok "upload sends exact totals" || bad "upload body" "$(last .body)"
respond '{"error": "nope"}' application/json 401
python3 "$ROOT/scripts/token_usage.py" upload "$TMP/projects" > "$TMP/o.json" && rc=0 || rc=$?
[ "$rc" = 1 ] && [ "$(jq -r .error "$TMP/o.json")" = "HTTP 401" ] && ok "upload reports an HTTP error and exits 1" || bad "upload error" "rc=$rc $(cat "$TMP/o.json")"

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
