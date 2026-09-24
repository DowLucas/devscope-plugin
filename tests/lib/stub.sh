# shellcheck shell=bash
# Start tests/lib/stub_server.py for a hook test. Source after setting TMP.
# Sets DEVSCOPE_URL/DEVSCOPE_API_KEY and defines respond/slow/hits/last.
STUB_DIR="$TMP/stub"; mkdir -p "$STUB_DIR"; : > "$STUB_DIR/resp"
_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
python3 "$(dirname "${BASH_SOURCE[0]}")/stub_server.py" "$_port" "$STUB_DIR" >"$TMP/server.log" 2>&1 &
STUB_PID=$!
trap 'kill $STUB_PID 2>/dev/null; rm -rf "$TMP"' EXIT
export DEVSCOPE_URL="http://127.0.0.1:$_port" DEVSCOPE_API_KEY="test-key"
for _ in $(seq 1 50); do curl -s -o /dev/null "$DEVSCOPE_URL" && break; sleep 0.1; done

respond() { printf '%s' "$1" > "$STUB_DIR/resp"; rm -f "$STUB_DIR/slow"; }
slow() { touch "$STUB_DIR/slow"; }
reset_hits() { : > "$STUB_DIR/hits"; }
hits() { [ -f "$STUB_DIR/hits" ] && wc -c < "$STUB_DIR/hits" | tr -d ' ' || echo 0; }
last() { jq -r "$1" "$STUB_DIR/last"; }
