#!/usr/bin/env bash
# Smoke test: replay recorded hook stdin payloads through the real hook scripts
# and assert the backend accepts them with 2xx.
#
# Required env:
#   DEVSCOPE_URL   — base URL of a backend ALREADY running and migrated.
#                    Default: http://localhost:6767
#
# How it works:
#   1. Wait for the backend to report healthy on /api/health.
#   2. Set up a tmp git repo and use it as `cwd` for every fixture (hook scripts
#      shell out to `git -C "$CWD" config user.email`, so an empty/missing repo
#      pollutes stderr and produces a fallback developerId).
#   3. For each fixture in fixtures/<hook-name>.json, pipe it into the matching
#      scripts/<hook-name>.sh, with all stderr captured.
#   4. After all hooks fire, fail if stderr contains any
#      "Event delivery failed" log line emitted by send-event.sh on non-2xx.
#   5. As a positive check, GET /api/events/recent and require >= N events
#      (where N is the fixture count).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPTS_DIR="$ROOT/scripts"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
DEVSCOPE_URL="${DEVSCOPE_URL:-http://localhost:6767}"
export DEVSCOPE_URL
# Force private-mode payloads so smoke results don't depend on prompt/tool text
# (the schema accepts them either way; just keeps payloads minimal).
export DEVSCOPE_PRIVACY="${DEVSCOPE_PRIVACY:-private}"

log() { printf '[smoke] %s\n' "$*"; }

# 1. Wait for backend.
log "Waiting for backend at $DEVSCOPE_URL/api/health..."
for i in $(seq 1 60); do
  if curl -fsS --max-time 2 "$DEVSCOPE_URL/api/health" >/dev/null 2>&1; then
    log "Backend healthy (after ${i}s)"
    break
  fi
  if [ "$i" -eq 60 ]; then
    log "ERROR: backend did not become healthy within 60s"
    exit 1
  fi
  sleep 1
done

# 2. Tmp git repo for CWD.
TMP_REPO="$(mktemp -d)"
trap 'rm -rf "$TMP_REPO"' EXIT
git -C "$TMP_REPO" init -q
git -C "$TMP_REPO" config user.email "smoke@devscope.test"
git -C "$TMP_REPO" config user.name "Smoke Tester"
git -C "$TMP_REPO" commit --allow-empty -q -m "smoke init"
log "Tmp CWD: $TMP_REPO"

# 3. Replay fixtures.
STDERR_LOG="$(mktemp)"
trap 'rm -rf "$TMP_REPO" "$STDERR_LOG"' EXIT

shopt -s nullglob
fixtures=("$FIXTURES_DIR"/*.json)
shopt -u nullglob

if [ "${#fixtures[@]}" -eq 0 ]; then
  log "ERROR: no fixtures in $FIXTURES_DIR"
  exit 1
fi

before_count=$(curl -fsS --max-time 5 "$DEVSCOPE_URL/api/events/recent?limit=500" | jq 'length')
log "Backend recent-events count before replay: $before_count"

count=0
for fixture in "${fixtures[@]}"; do
  name=$(basename "$fixture" .json)
  script="$SCRIPTS_DIR/${name}.sh"
  if [ ! -x "$script" ] && [ ! -f "$script" ]; then
    log "ERROR: fixture $name has no matching scripts/${name}.sh"
    exit 1
  fi
  # Substitute placeholder for CWD so fixture files stay portable.
  payload=$(sed "s|__SMOKE_CWD__|$TMP_REPO|g" "$fixture")
  log "Replaying $name..."
  if ! printf '%s' "$payload" | bash "$script" 2>>"$STDERR_LOG"; then
    log "ERROR: hook $name exited non-zero"
    cat "$STDERR_LOG" >&2
    exit 1
  fi
  count=$((count + 1))
done

# 4. Inspect stderr for delivery failures.
if grep -q "Event delivery failed" "$STDERR_LOG"; then
  log "ERROR: send-event.sh reported delivery failures:"
  grep "Event delivery failed" "$STDERR_LOG" >&2
  exit 1
fi

# Surface any other stderr noise non-fatally.
if [ -s "$STDERR_LOG" ]; then
  log "Hook stderr (informational):"
  sed 's/^/  /' "$STDERR_LOG" >&2 || true
fi

# 5. Positive check on the backend.
sleep 1  # async hooks may still be flushing
after_count=$(curl -fsS --max-time 5 "$DEVSCOPE_URL/api/events/recent?limit=500" | jq 'length')
log "Backend recent-events count after replay: $after_count (expected >= $((before_count + count)))"

if [ "$after_count" -lt "$((before_count + count))" ]; then
  log "ERROR: backend stored fewer events than fixtures replayed"
  exit 1
fi

log "Smoke OK: $count fixtures replayed, all accepted with 2xx"
