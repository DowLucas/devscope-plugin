#!/usr/bin/env bash
# Integration test for the plugin retry buffer (DEV-23).
#
# Boots a tiny python toggleable HTTP server, then exercises:
#   1. Backend down (503)  → send-event.sh enqueues; queue depth = N.
#   2. Backend up   (200)  → drain-queue.sh empties the queue.
#   3. Same event id replayed N times → backend sees it N times,
#      and our drain still completes (idempotency is the backend's job;
#      we only assert the plugin re-tries until 2xx).
#   4. Backend dropped mid-flight → some events queued, drain on recovery.
#
# Exits non-zero on any assertion failure. Cleans up child server on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS="$ROOT/scripts"

log() { printf '[queue-test] %s\n' "$*"; }
fail() { printf '[queue-test] FAIL: %s\n' "$*" >&2; exit 1; }

# Isolate filesystem state.
WORK="$(mktemp -d)"
QUEUE_DIR="$WORK/queue"
SERVER_LOG="$WORK/server.log"
SERVER_STATE="$WORK/state"   # contents: "down" | "up"
SERVER_HITS="$WORK/hits"     # one line per accepted POST
echo "down" >"$SERVER_STATE"
: >"$SERVER_HITS"

cleanup() {
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# --- Toggleable server ---------------------------------------------------
PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')

python3 - "$PORT" "$SERVER_STATE" "$SERVER_HITS" >"$SERVER_LOG" 2>&1 <<'PY' &
import sys, json
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
STATE_PATH = sys.argv[2]
HITS_PATH = sys.argv[3]

class H(BaseHTTPRequestHandler):
    def log_message(self, *a, **k): pass
    def _state(self):
        with open(STATE_PATH) as f: return f.read().strip()
    def do_POST(self):
        n = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(n) if n else b""
        if self._state() == "up":
            try:
                evt = json.loads(body.decode("utf-8"))
                with open(HITS_PATH, "a") as f:
                    f.write(evt.get("id", "?") + "\n")
            except Exception:
                pass
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        else:
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b'down')

HTTPServer(("127.0.0.1", PORT), H).serve_forever()
PY
SERVER_PID=$!

# Wait until listening.
for i in $(seq 1 50); do
  if curl -fsS --max-time 1 -X POST "http://127.0.0.1:$PORT" -d '' >/dev/null 2>&1; then
    break
  fi
  sleep 0.1
done

# --- Tmp git repo (send-event.sh expects a real git ctx) -----------------
TMP_REPO="$(mktemp -d)"
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email "queue@devscope.test"
git -C "$TMP_REPO" config user.name "Queue Test"
git -C "$TMP_REPO" commit --allow-empty -q -m "init"

export DEVSCOPE_URL="http://127.0.0.1:$PORT"
export DEVSCOPE_QUEUE_DIR="$QUEUE_DIR"
export DEVSCOPE_PRIVACY="private"
# Don't auto-drain on the success path — we drive the drain explicitly so
# assertions don't race with a backgrounded child.
export DEVSCOPE_NO_DRAIN=1

mk_input() {
  local sid="$1"
  jq -n --arg sid "$sid" --arg cwd "$TMP_REPO" \
    '{session_id:$sid, cwd:$cwd}'
}

queue_count() { find "$QUEUE_DIR" -maxdepth 1 -name 'q_*.json' 2>/dev/null | wc -l | tr -d ' '; }

# --- Phase 1: backend down → events accumulate in queue ------------------
log "Phase 1: backend down, sending 5 events"
for i in 1 2 3 4 5; do
  printf '%s' "$(mk_input "sess-$i")" | "$SCRIPTS/send-event.sh" "test.event" '{"i":'$i'}' \
    >/dev/null 2>>"$SERVER_LOG" || true
done
got=$(queue_count)
[ "$got" = "5" ] || fail "expected 5 queued, got $got"
log "Phase 1 OK: $got events queued"

# --- Phase 2: bring backend up, drain replays ----------------------------
echo "up" >"$SERVER_STATE"
# Clear backoff so the drain runs immediately (Phase 1 set it).
rm -f "$QUEUE_DIR/.backoff" "$QUEUE_DIR/.backoff_delay"
log "Phase 2: backend up, draining"
"$SCRIPTS/drain-queue.sh"
got=$(queue_count)
[ "$got" = "0" ] || fail "expected 0 queued after drain, got $got"
hits=$(wc -l <"$SERVER_HITS" | tr -d ' ')
[ "$hits" = "5" ] || fail "expected 5 backend hits, got $hits"
log "Phase 2 OK: queue empty, backend received $hits"

# --- Phase 3: replay-the-same-id is the backend's idempotency contract.
# We just confirm the plugin re-POSTs until 2xx, then the file is gone.
log "Phase 3: replay same event 3x while backend down → up"
echo "down" >"$SERVER_STATE"
: >"$SERVER_HITS"
for i in 1 2 3; do
  printf '%s' "$(mk_input "sess-dup")" | "$SCRIPTS/send-event.sh" "test.dup" '{"k":"v"}' \
    >/dev/null 2>>"$SERVER_LOG" || true
done
[ "$(queue_count)" = "3" ] || fail "expected 3 queued"
echo "up" >"$SERVER_STATE"
rm -f "$QUEUE_DIR/.backoff" "$QUEUE_DIR/.backoff_delay"
"$SCRIPTS/drain-queue.sh"
[ "$(queue_count)" = "0" ] || fail "queue not empty after replay"
hits=$(wc -l <"$SERVER_HITS" | tr -d ' ')
[ "$hits" = "3" ] || fail "expected 3 hits on replay, got $hits"
log "Phase 3 OK: plugin replays until backend accepts"

# --- Phase 4: drop backend mid-flight, then recover ----------------------
log "Phase 4: mid-flight drop"
: >"$SERVER_HITS"
echo "up" >"$SERVER_STATE"
# 2 events while up
printf '%s' "$(mk_input "mf-1")" | "$SCRIPTS/send-event.sh" "test.mf" '{"i":1}' >/dev/null 2>>"$SERVER_LOG" || true
printf '%s' "$(mk_input "mf-2")" | "$SCRIPTS/send-event.sh" "test.mf" '{"i":2}' >/dev/null 2>>"$SERVER_LOG" || true
# Drop
echo "down" >"$SERVER_STATE"
# 3 events while down
for i in 3 4 5; do
  printf '%s' "$(mk_input "mf-$i")" | "$SCRIPTS/send-event.sh" "test.mf" '{"i":'$i'}' \
    >/dev/null 2>>"$SERVER_LOG" || true
done
[ "$(queue_count)" = "3" ] || fail "expected 3 queued mid-flight, got $(queue_count)"
# Recover
echo "up" >"$SERVER_STATE"
rm -f "$QUEUE_DIR/.backoff" "$QUEUE_DIR/.backoff_delay"
"$SCRIPTS/drain-queue.sh"
[ "$(queue_count)" = "0" ] || fail "queue not empty after recovery, got $(queue_count)"
hits=$(wc -l <"$SERVER_HITS" | tr -d ' ')
# 2 direct + 3 drained = 5
[ "$hits" = "5" ] || fail "expected 5 total backend hits across mid-flight, got $hits"
log "Phase 4 OK: $hits events delivered across the outage"

# --- Phase 5: cap enforcement --------------------------------------------
log "Phase 5: cap enforcement"
echo "down" >"$SERVER_STATE"
export DEVSCOPE_QUEUE_MAX=4
for i in 1 2 3 4 5 6 7; do
  printf '%s' "$(mk_input "cap-$i")" | "$SCRIPTS/send-event.sh" "test.cap" '{"i":'$i'}' \
    >/dev/null 2>>"$SERVER_LOG" || true
done
got=$(queue_count)
[ "$got" = "4" ] || fail "cap=4 expected 4 queued, got $got"
log "Phase 5 OK: queue capped at $got"

log "ALL PHASES PASSED"
