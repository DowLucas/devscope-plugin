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
MODE="$TMP/mode"; HITS="$TMP/hits"; LAST="$TMP/last"
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 - "$PORT" "$MODE" "$HITS" "$LAST" >"$TMP/server.log" 2>&1 <<'PY' &
import json, sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
port, mode_f, hits_f, last_f = int(sys.argv[1]), *sys.argv[2:]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        if self.headers.get("x-requested-with") != "devscope-cli":
            # Same as the backend's CSRF middleware for API-key POSTs.
            self.send_response(403); self.send_header("content-type", "application/json"); self.end_headers()
            self.wfile.write(b'{"error":"Missing x-requested-with header"}'); return
        open(hits_f, "a").write("x")
        open(last_f, "w").write(json.dumps({"path": self.path, "key": self.headers.get("x-api-key"), "body": json.loads(body)}))
        mode = open(mode_f).read().strip()
        if mode == "slow": time.sleep(5)
        payload = {
            "match": json.dumps({"matches": [{"day": "2026-09-12"}, {"day": "2026-09-03"}], "repeat_days": 2,
                                 "context": "DevScope: the user has asked something very similar before:\n- 2026-09-12 ..."}),
            "none": json.dumps({"matches": [], "repeat_days": 0, "context": None}),
            "garbage": "<html>oops</html>",
            "slow": json.dumps({"context": "late"}),
        }[mode]
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers()
        self.wfile.write(payload.encode())
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
SERVER=$!
trap 'kill $SERVER 2>/dev/null; rm -rf "$TMP"' EXIT
export DEVSCOPE_URL="http://127.0.0.1:$PORT" DEVSCOPE_API_KEY="test-key"
for _ in $(seq 1 50); do curl -s -o /dev/null "$DEVSCOPE_URL" && break; sleep 0.1; done

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
input() { jq -n --arg p "$1" '{session_id: "sess-1", hook_event_name: "UserPromptSubmit", prompt: $p}'; }
hits() { [ -f "$HITS" ] && wc -c < "$HITS" | tr -d ' ' || echo 0; }
LONG="deploy the android build to the play store internal track"

echo match > "$MODE"; : > "$HITS"
out=$(input "$LONG" | "$HOOK")
[ "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)" = "UserPromptSubmit" ] && ok "match: event name" || bad "match: event name" "$out"
printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext | grep -q "asked something very similar" && ok "match: note reaches Claude" || bad "match: note" "$out"
printf '%s' "$out" | jq -r .systemMessage | grep -q "2026-09-12, 2026-09-03" && ok "match: user notice lists the days" || bad "match: notice" "$out"
[ "$(jq -r .path "$LAST")" = "/api/similar/preflight" ] && ok "calls the preflight endpoint" || bad "path" "$(cat "$LAST")"
[ "$(jq -r .key "$LAST")" = "test-key" ] && ok "sends the API key" || bad "api key" "$(cat "$LAST")"
[ "$(jq -r .body.prompt "$LAST")" = "$LONG" ] && [ "$(jq -r .body.session_id "$LAST")" = "sess-1" ] && ok "sends prompt and session" || bad "body" "$(cat "$LAST")"

echo none > "$MODE"
[ -z "$(input "$LONG" | "$HOOK")" ] && ok "no match is silent" || bad "no match" "output"
echo garbage > "$MODE"
[ -z "$(input "$LONG" | "$HOOK")" ] && ok "garbage response is silent" || bad "garbage" "output"

echo match > "$MODE"; : > "$HITS"
[ -z "$(input "yes continue" | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "short prompt: silent, no request" || bad "short prompt" "hits=$(hits)"
[ -z "$(input "$LONG" | DEVSCOPE_PREFLIGHT=off "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "off: silent, no request" || bad "off" "hits=$(hits)"
[ -z "$(input "$LONG" | DEVSCOPE_PRIVACY=private "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "private mode: silent, no request" || bad "private" "hits=$(hits)"
mkdir -p "$XDG_CONFIG_HOME/devscope"; printf 'DEVSCOPE_PREFLIGHT=off\n' > "$XDG_CONFIG_HOME/devscope/config"
[ -z "$(input "$LONG" | "$HOOK")" ] && [ "$(hits)" = 0 ] && ok "off via config file" || bad "config off" "hits=$(hits)"
rm "$XDG_CONFIG_HOME/devscope/config"

[ -z "$(input "$LONG" | DEVSCOPE_URL=http://127.0.0.1:9 "$HOOK")" ] && ok "server down is silent" || bad "down" "output"
echo slow > "$MODE"
start=$(date +%s%N); out=$(input "$LONG" | "$HOOK"); ms=$(( ($(date +%s%N) - start) / 1000000 ))
[ -z "$out" ] && [ "$ms" -lt 3000 ] && ok "slow server gives up in ${ms}ms (< 3000)" || bad "slow" "${ms}ms out=$out"
[ -z "$(printf 'not json' | "$HOOK")" ] && ok "garbage stdin is silent" || bad "stdin" "output"

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
