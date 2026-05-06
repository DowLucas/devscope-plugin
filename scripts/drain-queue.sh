#!/usr/bin/env bash
# DevScope queue drain — replay queued events to the backend.
#
# Designed to be called opportunistically (e.g. backgrounded from
# send-event.sh after a successful 2xx). Safe to invoke repeatedly:
# a non-blocking lock guarantees only one drain runs at a time.
#
# Behavior per file:
#   2xx (incl. {ok:true,duplicate:true})  → delete (backend has it)
#   4xx                                    → delete (malformed; not retryable)
#   5xx / 000 / timeout                    → set exponential backoff, stop
#
# Exits 0 always — this is a best-effort background process.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/queue.sh"

# Per-invocation cap so a single drain can't run forever during a long outage.
MAX_PER_RUN="${DEVSCOPE_DRAIN_BATCH:-50}"

# Try to take the queue lock; if another drain is running, just exit.
_ds_queue_lock || exit 0
trap '_ds_queue_unlock' EXIT INT TERM

# Skip if we're inside a backoff window.
if ! _ds_queue_backoff_ready; then
  exit 0
fi

sent=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ ! -f "$f" ] && continue
  [ "$sent" -ge "$MAX_PER_RUN" ] && break

  body=$(cat "$f" 2>/dev/null)
  [ -z "$body" ] && { rm -f "$f" 2>/dev/null; continue; }

  CURL_ARGS=(-s -X POST "${DEVSCOPE_URL}/api/events"
    -H "Content-Type: application/json"
    -d "$body"
    --max-time 5
    -w '%{http_code}'
    -o /dev/null)

  CURL_CONFIG=""
  if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
    CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
  fi

  http=$(echo "$CURL_CONFIG" | curl --config - "${CURL_ARGS[@]}" 2>/dev/null) || http="000"
  [ -z "$http" ] && http="000"

  case "$http" in
    2*)
      rm -f "$f" 2>/dev/null
      sent=$((sent + 1))
      ;;
    4*)
      # Malformed / rejected — retrying won't help. Drop with a warning.
      echo "[devscope] Dropping queued event after HTTP $http: $(basename "$f")" >&2
      rm -f "$f" 2>/dev/null
      ;;
    *)
      # 5xx, 000, or anything else transient — back off and stop the batch.
      prev=$(_ds_queue_backoff_delay)
      _ds_queue_backoff_bump "$prev"
      exit 0
      ;;
  esac
done < <(_ds_queue_list)

# Made it through without a transient failure → clear any prior backoff.
_ds_queue_backoff_clear
exit 0
