#!/usr/bin/env bash
# Tests for scripts/model-first-use.sh (first use of a model). Stub server, no backend.
#
#   bash tests/models/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/scripts/model-first-use.sh"
TMP=$(mktemp -d)
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/config"
unset DEVSCOPE_HINTS DEVSCOPE_PRIVACY
# shellcheck disable=SC1091
. "$ROOT/tests/lib/stub.sh"
SEEN="$HOME/.cache/devscope/models-seen"
pass=0; fail=0

start() {  # model [session]
  jq -n --arg m "$1" --arg s "${2:-s1}" \
    '{session_id: $s, hook_event_name: "SessionStart", source: "startup", cwd: "/nonexistent", model: $m}'
}
switch() {  # from to
  jq -n --arg f "$1" --arg t "$2" \
    '{session_id: "s1", hook_event_name: "PostModelSwitch", cwd: "/nonexistent",
      from_model: $f, to_model: $t, requested_model: null, source: "command",
      context_tokens: 1000, prompt_cache_warm: true}'
}
check() {  # name expected-substring-or-EMPTY actual
  if { [ "$2" = "EMPTY" ] && [ -z "$3" ]; } || { [ "$2" != "EMPTY" ] && printf '%s' "$3" | grep -Fq "$2"; }; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: expected '$2', got '$3'"
  fi
}
# The event is sent in the background: wait for a POST to /api/events.
wait_event() {
  for _ in $(seq 1 50); do paths | grep -q '/api/events' && return 0; sleep 0.1; done
  return 1
}
event() { last_at /api/events ".body$1"; }

respond '{"ok":true}'
reset_hits
check "first model ever is the silent baseline" EMPTY "$(start claude-opus-5-5 | "$HOOK")"
check "baseline is recorded" "claude-opus-5-5" "$(cat "$SEEN")"
sleep 0.5
check "baseline sends no event" EMPTY "$(paths)"
check "a seen model is silent" EMPTY "$(start claude-opus-5-5 s2 | "$HOOK")"
check "context-window suffix is the same model" EMPTY "$(start 'claude-opus-5-5[1m]' s3 | "$HOOK")"
check "case is ignored" EMPTY "$(start Claude-Opus-5-5 s4 | "$HOOK")"

out=$(start claude-fable-5-1 s5 | "$HOOK")
check "new model tells the user" "DevScope: first time on claude-fable-5-1." "$(printf '%s' "$out" | jq -r .systemMessage)"
ctx=$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)
check "new model asks Claude to offer the review" "ask the user" "$ctx"
check "it names CLAUDE.md and memory" "CLAUDE.md files and memory files" "$ctx"
check "it is about model selection and usage" "model selection or model usage" "$ctx"
check "it forbids doing it unasked" "unless the user agrees" "$ctx"
check "hook event name is SessionStart" "SessionStart" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)"
wait_event || true
check "event type" "model.first_use" "$(event .eventType)"
check "event model" "claude-fable-5-1" "$(event .payload.model)"
check "event trigger" "session_start" "$(event .payload.trigger)"
check "no previousModel on session start" "null" "$(event .payload.previousModel)"
check "new model is recorded" "claude-fable-5-1" "$(cat "$SEEN")"
check "second time is silent" EMPTY "$(start claude-fable-5-1 s6 | "$HOOK")"

reset_hits
out=$(switch claude-opus-5-5 'claude-sonnet-5-5[1m]' | "$HOOK")
check "switch to a new model tells Claude" "claude-sonnet-5-5" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)"
check "hook event name is PostModelSwitch" "PostModelSwitch" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)"
wait_event || true
check "switch event trigger" "model_switch" "$(event .payload.trigger)"
check "switch event previous model" "claude-opus-5-5" "$(event .payload.previousModel)"
check "switch to a seen model is silent" EMPTY "$(switch claude-sonnet-5-5 claude-opus-5-5 | "$HOOK")"

# No seen file yet and the first thing seen is a switch: the model switched
# from is the baseline, the one switched to is new.
rm -f "$SEEN"
out=$(switch claude-opus-5-5 claude-haiku-5-5 | "$HOOK")
check "switch with no baseline still announces the new model" "claude-haiku-5-5" "$(printf '%s' "$out" | jq -r .systemMessage)"
check "switch with no baseline records both" "claude-opus-5-5 claude-haiku-5-5" "$(tr '\n' ' ' < "$SEEN")"

reset_hits
out=$(start claude-new-1 s7 | DEVSCOPE_HINTS=off "$HOOK")
check "hints off is silent" EMPTY "$out"
wait_event || true
check "hints off still sends the event" "claude-new-1" "$(event .payload.model)"
check "hints off still records the model" "claude-new-1" "$(cat "$SEEN")"

check "missing model is silent" EMPTY "$(start '' s8 | "$HOOK")"
check "unsafe model id is ignored" EMPTY "$(start 'x"; rm -rf ~' s9 | "$HOOK")"
check "other hook events are ignored" EMPTY "$(jq -n '{hook_event_name: "Stop", model: "claude-z"}' | "$HOOK")"
check "garbage stdin is silent" EMPTY "$(printf 'not json' | "$HOOK")"
check "empty stdin is silent" EMPTY "$(printf '' | "$HOOK")"

# Runs synchronously at every session start: the seen path must be fast.
t0=$(date +%s%N); for _ in 1 2 3 4 5 6 7 8 9 10; do start claude-opus-5-5 | "$HOOK" >/dev/null; done; t1=$(date +%s%N)
avg_ms=$(( (t1 - t0) / 10000000 ))
if [ "$avg_ms" -lt 150 ]; then pass=$((pass + 1)); echo "ok   seen path averages ${avg_ms}ms (< 150ms)"; else fail=$((fail + 1)); echo "FAIL seen path averages ${avg_ms}ms"; fi

# A slow backend must not hold up the hook (the event is detached).
slow
t0=$(date +%s%N); start claude-slow-1 s10 | "$HOOK" >/dev/null; t1=$(date +%s%N)
ms=$(( (t1 - t0) / 1000000 ))
if [ "$ms" -lt 1000 ]; then pass=$((pass + 1)); echo "ok   slow backend does not block (${ms}ms)"; else fail=$((fail + 1)); echo "FAIL slow backend blocked for ${ms}ms"; fi

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
