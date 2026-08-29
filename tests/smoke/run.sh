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
  # Better-auth's apiKey plugin rate-limits at 15 verifyApiKey calls per
  # 1s window per key. A tight burst tips over and the backend returns 401
  # with "Rate limit exceeded".
  #
  # This was 100ms, which was sized for 7 fixtures. Plugin 0.15.0 added nine
  # more (16 total), and at 100ms the burst crossed the 15/s ceiling — the
  # run failed with 401s on the tail of the list rather than on any one
  # fixture. 250ms holds us near 4 req/s, which leaves headroom for the
  # health probe and further fixtures without re-tuning.
  sleep 0.25
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

# 5. Positive direct probe — POST one synthetic event straight to /api/events
# and assert a 2xx response. This is the authoritative smoke signal: the
# /api/events/recent feed is auth-gated, but POST /api/events is open (and is
# the exact endpoint every hook script targets via send-event.sh).
# Mirror send-event.sh's privacy redaction so the probe payload matches what
# real hooks would emit in the active privacy mode. In `private`, projectPath
# becomes `hash:<sha256(CWD)[:12]>` and projectName is `redacted` (DEV-67).
if [ "${DEVSCOPE_PRIVACY:-standard}" = "private" ]; then
  if command -v sha256sum >/dev/null 2>&1; then
    probe_path_hash=$(printf '%s' "/tmp/smoke" | sha256sum | cut -d' ' -f1 | cut -c1-12)
  else
    probe_path_hash=$(printf '%s' "/tmp/smoke" | shasum -a 256 | cut -d' ' -f1 | cut -c1-12)
  fi
  probe_project_path="hash:${probe_path_hash}"
  probe_project_name="redacted"
else
  probe_project_path="/tmp/smoke"
  probe_project_name="smoke"
fi

probe_event=$(jq -n \
  --arg id "smoke-probe-$(date +%s%N)" \
  --arg ts "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" \
  --arg ppath "$probe_project_path" \
  --arg pname "$probe_project_name" \
  '{
    id: $id,
    timestamp: $ts,
    sessionId: "smoke-session-probe",
    developerId: "smoke-dev",
    developerName: "Smoke Probe",
    projectPath: $ppath,
    projectName: $pname,
    eventType: "session.start",
    payload: {source: "smoke"}
  }')

# Pause to clear better-auth apiKey rate window (15/s) before the probe.
sleep 1
probe_args=(-s -o /dev/null -w '%{http_code}' --max-time 5
  -X POST "$DEVSCOPE_URL/api/events"
  -H 'Content-Type: application/json'
  -d "$probe_event")
if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
  probe_args+=(-H "x-api-key: $DEVSCOPE_API_KEY")
fi
probe_status=$(curl "${probe_args[@]}")

if [ "$probe_status" != "200" ]; then
  log "ERROR: direct POST /api/events probe returned HTTP $probe_status (expected 200)"
  exit 1
fi
log "Direct POST probe to /api/events returned 200"

log "Smoke OK: $count hook fixtures replayed and 1 direct probe — all accepted with 2xx"
