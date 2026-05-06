#!/usr/bin/env bash
# DevScope retry queue — cross-platform on-disk FIFO buffer.
# Sourced by send-event.sh and drain-queue.sh; not executed directly.
#
# Layout:
#   $DS_QUEUE_DIR/                 # default ${XDG_CACHE_HOME:-$HOME/.cache}/devscope/queue
#     q_<unix_ms>_<event_id>.json  # one file per pending event
#     .lock/                       # mkdir-based lock (atomic on POSIX)
#     .backoff                     # one number: unix_ms before which drains skip
#
# Tunables (env vars):
#   DEVSCOPE_QUEUE_MAX     — cap entries (default 1000). Oldest pruned first.
#   DEVSCOPE_QUEUE_TTL_SEC — drop entries older than this (default 86400 = 24h).
#   DEVSCOPE_QUEUE_DIR     — override queue path (mainly for tests).

# Resolve queue directory, creating it on demand.
_ds_queue_dir() {
  local dir="${DEVSCOPE_QUEUE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/devscope/queue}"
  mkdir -p "$dir" 2>/dev/null || true
  echo "$dir"
}

# Cross-platform unix milliseconds.
_ds_queue_now_ms() {
  local ms
  ms=$(date +%s%3N 2>/dev/null)
  case "$ms" in
    *[!0-9]*|"")
      ms=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null) || \
      ms=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1000' 2>/dev/null) || \
      ms="$(date +%s)000"
      ;;
  esac
  echo "$ms"
}

# Acquire the queue lock. Returns 0 on success, 1 if already held.
# The lock is a directory — mkdir is atomic everywhere POSIX.
# Stale locks (older than 60s) are reclaimed automatically.
_ds_queue_lock() {
  local dir lock now mtime age
  dir=$(_ds_queue_dir)
  lock="$dir/.lock"
  if mkdir "$lock" 2>/dev/null; then
    echo $$ >"$lock/pid" 2>/dev/null || true
    return 0
  fi
  # Stale-lock recovery.
  now=$(date +%s 2>/dev/null || echo 0)
  mtime=$(stat -c %Y "$lock" 2>/dev/null || stat -f %m "$lock" 2>/dev/null || echo "$now")
  age=$((now - mtime))
  if [ "$age" -gt 60 ]; then
    rm -rf "$lock" 2>/dev/null
    if mkdir "$lock" 2>/dev/null; then
      echo $$ >"$lock/pid" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

_ds_queue_unlock() {
  local dir
  dir=$(_ds_queue_dir)
  rm -rf "$dir/.lock" 2>/dev/null || true
}

# Enqueue one event JSON. Caller passes event JSON on stdin.
# Locking: caller must NOT hold the lock — this function takes it briefly.
# Always returns 0 (best-effort; we never want to fail the hook).
_ds_queue_enqueue() {
  local event_id="$1"
  local dir ms tmp final
  dir=$(_ds_queue_dir)
  ms=$(_ds_queue_now_ms)
  tmp="$dir/.in.$$.$ms"
  # Sanitize event_id for filenames (safe charset only).
  event_id=$(printf '%s' "$event_id" | tr -cd 'A-Za-z0-9._-' | cut -c1-64)
  [ -z "$event_id" ] && event_id="noid"
  final="$dir/q_${ms}_${event_id}.json"
  cat >"$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  # Atomic publish — readers only see the entry once it's fully written.
  mv "$tmp" "$final" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  # Best-effort prune; ignore failure.
  _ds_queue_prune || true
  return 0
}

# Drop expired and over-cap entries. Caller may or may not hold the lock;
# we do a non-blocking attempt and silently skip if another drain is active.
_ds_queue_prune() {
  local dir max ttl now_s cutoff_s files count keep
  dir=$(_ds_queue_dir)
  max="${DEVSCOPE_QUEUE_MAX:-1000}"
  ttl="${DEVSCOPE_QUEUE_TTL_SEC:-86400}"
  now_s=$(date +%s 2>/dev/null || echo 0)
  cutoff_s=$((now_s - ttl))

  # TTL prune by filename timestamp (ms → s).
  # find always succeeds with no matches (unlike `ls glob` which fails);
  # important because callers run with `set -e + pipefail`.
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local base ts_ms ts_s
    base=$(basename "$f")
    ts_ms="${base#q_}"
    ts_ms="${ts_ms%%_*}"
    case "$ts_ms" in
      *[!0-9]*|"") continue ;;
    esac
    ts_s=$((ts_ms / 1000))
    if [ "$ts_s" -lt "$cutoff_s" ]; then
      rm -f "$f" 2>/dev/null
    fi
  done < <(find "$dir" -maxdepth 1 -name 'q_*.json' 2>/dev/null)

  # Cap prune (oldest first by lexicographic ms-prefixed filename).
  files=$(find "$dir" -maxdepth 1 -name 'q_*.json' 2>/dev/null | sort)
  count=$(printf '%s' "$files" | grep -c . 2>/dev/null || true)
  : "${count:=0}"
  if [ "$count" -gt "$max" ]; then
    keep=$((count - max))
    printf '%s\n' "$files" | head -n "$keep" | while IFS= read -r f; do
      [ -n "$f" ] && rm -f "$f" 2>/dev/null
    done
  fi
}

# Print queue files oldest-first, one per line.
_ds_queue_list() {
  local dir
  dir=$(_ds_queue_dir)
  find "$dir" -maxdepth 1 -name 'q_*.json' 2>/dev/null | sort
}

# Backoff helpers: gate drains during outage windows.
_ds_queue_backoff_path() { echo "$(_ds_queue_dir)/.backoff"; }

# Return 0 if drain is allowed now, 1 if still backing off.
_ds_queue_backoff_ready() {
  local f now next
  f=$(_ds_queue_backoff_path)
  [ ! -f "$f" ] && return 0
  next=$(cat "$f" 2>/dev/null)
  case "$next" in
    *[!0-9]*|"") return 0 ;;
  esac
  now=$(_ds_queue_now_ms)
  [ "$now" -ge "$next" ]
}

# Bump backoff. Argument: previous delay ms (or 0). Doubles up to 5 min.
_ds_queue_backoff_bump() {
  local prev="$1"
  local next_delay max=300000 now resume
  [ -z "$prev" ] && prev=0
  if [ "$prev" -le 0 ]; then
    next_delay=5000
  else
    next_delay=$((prev * 2))
    [ "$next_delay" -gt "$max" ] && next_delay="$max"
  fi
  now=$(_ds_queue_now_ms)
  resume=$((now + next_delay))
  echo "$resume" >"$(_ds_queue_backoff_path)" 2>/dev/null || true
  echo "$next_delay" >"$(_ds_queue_dir)/.backoff_delay" 2>/dev/null || true
}

# Read current backoff delay (for next bump). 0 if absent.
_ds_queue_backoff_delay() {
  local f delay
  f="$(_ds_queue_dir)/.backoff_delay"
  [ ! -f "$f" ] && { echo 0; return; }
  delay=$(cat "$f" 2>/dev/null)
  case "$delay" in
    *[!0-9]*|"") echo 0 ;;
    *) echo "$delay" ;;
  esac
}

_ds_queue_backoff_clear() {
  rm -f "$(_ds_queue_backoff_path)" "$(_ds_queue_dir)/.backoff_delay" 2>/dev/null || true
}
