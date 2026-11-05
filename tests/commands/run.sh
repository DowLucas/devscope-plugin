#!/usr/bin/env bash
# Tests for Bash command timing: the command signature, what tool-complete.sh
# sends (Claude Code's duration_ms, toolUseId, background), and how Stop and
# SessionEnd report background commands that settled (scripts/bg_commands.py),
# against a stub DevScope server.
#
#   bash tests/commands/run.sh
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

# --- signature -------------------------------------------------------------
sig() {  # command [privacy]
  DEVSCOPE_PRIVACY="${2:-standard}" timeout 5 bash -c '. "$1/scripts/_helpers.sh" 2>/dev/null; _ds_command_signature "$2"' \
    _ "$ROOT" "$(jq -nc --arg c "$1" '{command: $c}')"
}
check_sig() {  # command expected [privacy]
  local got; got=$(sig "$1" "${3:-standard}")
  [ "$got" = "$2" ] && ok "signature: $1 -> $2" || bad "signature: $1" "got '$got', want '$2'"
}
check_sig 'bun test' 'bun test'
check_sig 'cd packages/backend && bun run build' 'bun run build'
check_sig '(cd packages/backend && bun test)' 'bun test'
check_sig 'sudo docker compose up -d' 'docker compose up'
check_sig 'FOO=1 BAR=2 timeout --foreground 5m npm run test:unit -- --watch' 'npm run test:unit'
check_sig 'git commit -m "fix: the thing"' 'git commit'
check_sig 'git checkout feature/secret-branch' 'git checkout'
check_sig 'git checkout my-branch' 'git checkout'
check_sig 'docker logs devscope-backend 2>&1 | tail -20' 'docker logs'
check_sig 'gh pr view 93' 'gh pr view'
check_sig 'echo ===; cargo test --release' 'cargo test'
check_sig 'python3 - <<PY
import os
PY' 'python3'
check_sig '/usr/local/bin/RG -n foo' 'rg'
check_sig 'cd /tmp' 'cd'
check_sig '' ''
check_sig 'cd app && bun run build' 'bun' private
check_sig 'docker compose up' 'docker' private

# --- tool-complete.sh --------------------------------------------------------
SID="aaaaaaaa-1111-2222-3333-444444444444"
PROJ="$TMP/projects/-repo"; mkdir -p "$PROJ"
T="$PROJ/$SID.jsonl"; : > "$T"
BG="$XDG_CACHE_HOME/devscope/bg"

post() {  # json -> run tool-complete.sh, print the payload it sent
  reset_hits
  printf '%s' "$1" | "$ROOT/scripts/tool-complete.sh" >/dev/null 2>&1 || true
  events_of tool.complete | tail -1 | jq -c .payload
}
base() {  # command extra-jq
  jq -cn --arg s "$SID" --arg t "$T" --arg cwd "$TMP" --arg c "$1" \
    "{session_id: \$s, transcript_path: \$t, cwd: \$cwd, hook_event_name: \"PostToolUse\",
      tool_name: \"Bash\", tool_input: {command: \$c}, tool_use_id: \"toolu_fg1\"} ${2:-}"
}
respond '{"ok": true}'

p=$(post "$(base 'cd app && bun test' '+ {duration_ms: 4321}')")
[ "$(jq -r .duration <<<"$p")" = 4321 ] && ok "uses Claude Code's duration_ms" || bad "duration_ms" "$p"
[ "$(jq -r .toolUseId <<<"$p")" = toolu_fg1 ] && ok "sends toolUseId" || bad "toolUseId" "$p"
[ "$(jq -r .commandSignature <<<"$p")" = "bun test" ] && ok "sends the command signature" || bad "signature" "$p"
[ "$(jq -r .toolSubcommand <<<"$p")" = "cd" ] && ok "toolSubcommand is unchanged (first word)" || bad "toolSubcommand" "$p"
[ "$(jq 'has("backgroundTaskId")' <<<"$p")" = false ] && [ ! -e "$BG/$SID.active" ] \
  && ok "a foreground command is not marked as background" || bad "fg bg" "$p"

# Fallback timer for Claude Code versions without duration_ms: keyed by
# tool_use_id, so a parallel call of the same tool does not overwrite it.
pre() { jq -cn --arg s "$SID" --arg cwd "$TMP" --arg id "$1" \
  '{session_id: $s, cwd: $cwd, tool_name: "Bash", tool_input: {command: "sleep 1"}, tool_use_id: $id}' \
  | "$ROOT/scripts/tool-use.sh" >/dev/null 2>&1; }
pre toolu_p1; sleep 0.3; pre toolu_p2
p=$(post "$(base 'sleep 1' '| .tool_use_id = "toolu_p1"')")
d=$(jq -r .duration <<<"$p")
[ "$d" -ge 250 ] 2>/dev/null && ok "fallback timer survives a parallel call of the same tool (${d} ms)" || bad "parallel timer" "$p"
[ -f "$HOME/.cache/devscope/timings/toolu_p2" ] && [ ! -f "$HOME/.cache/devscope/timings/toolu_p1" ] \
  && ok "each call's start file is its own" || bad "timing files" "$(ls "$HOME/.cache/devscope/timings")"

p=$(post "$(base 'bun run dev' '| .tool_use_id = "toolu_bg1" | .tool_input.run_in_background = true
  | .tool_response = {stdout: "", backgroundTaskId: "b1"} | .duration_ms = 12')")
[ "$(jq -c '[.backgroundTaskId, .runInBackground, .duration]' <<<"$p")" = '["b1",true,12]' ] \
  && ok "a background command carries its task id" || bad "bg payload" "$p"
[ -e "$BG/$SID.active" ] && ok "and marks the session for the background scan" || bad "bg marker" "missing"
p=$(post "$(base 'bun test' '| .tool_use_id = "toolu_bg2" | .tool_response = {backgroundTaskId: "b2", timedOutAfterMs: 120000}')")
[ "$(jq -c '[.backgroundTaskId, .runInBackground]' <<<"$p")" = '["b2",false]' ] \
  && ok "a command moved to the background after its timeout is told apart" || bad "moved bg" "$p"

# --- background completions --------------------------------------------------
note() {  # tool-use-id status summary-tail [ts] [operation]
  local body
  body=$(printf '<task-notification>\n<task-id>t-%s</task-id>\n<tool-use-id>%s</tool-use-id>\n<output-file>/tmp/claude-1000/x/tasks/t.output</output-file>\n<status>%s</status>\n<summary>%s</summary>\n</task-notification>' "$1" "$1" "$2" "$3")
  jq -cn --arg b "$body" --arg ts "${4:-2026-11-05T10:00:00.000Z}" --arg op "${5:-enqueue}" --arg s "$SID" \
    '{type: "queue-operation", operation: $op, timestamp: $ts, sessionId: $s, content: $b}'
}
{
  note toolu_bg1 completed 'Background command "Run dev server" completed (exit code 0)' 2026-11-05T10:01:00.000Z
  note toolu_bg2 failed 'Background command "Tests" failed with exit code 1' 2026-11-05T10:02:00.000Z
  note toolu_bg1 completed 'Background command "Run dev server" completed (exit code 0)' 2026-11-05T10:03:00.000Z remove
  note toolu_ag completed 'Agent "Explore" finished' 2026-11-05T10:04:00.000Z
  note toolu_bg3 killed 'Background command "Wait for it" was stopped' 2026-11-05T10:05:00.000Z
  echo '{"type":"user","message":{"role":"user","content":"<task-notification> in a prompt, not a queue op"}}'
  printf '%s' '{"type":"queue-operation","operation":"enqueue"'   # half-written line
} > "$T"

stop() {  # hook script event
  reset_hits
  jq -cn --arg s "$SID" --arg t "$T" --arg cwd "$TMP" --arg e "$2" \
    '{session_id: $s, transcript_path: $t, cwd: $cwd, hook_event_name: $e, last_assistant_message: "done", reason: "other"}' \
    | "$ROOT/scripts/$1" >/dev/null 2>&1 || true
}
stop response-stop.sh Stop
c=$(events_of command.background_complete | jq -c '.payload.commands')
[ "$(jq -c '[.[] | [.toolUseId, .status, .exitCode, .finishedAt]]' <<<"$c")" = \
  '[["toolu_bg1","completed",0,"2026-11-05T10:01:00.000Z"],["toolu_bg2","failed",1,"2026-11-05T10:02:00.000Z"],["toolu_bg3","killed",null,"2026-11-05T10:05:00.000Z"]]' ] \
  && ok "Stop reports settled shells once each, not agents or removals" || bad "bg report" "$c"
[ "$(jq -r '.[0].taskId' <<<"$c")" = "t-toolu_bg1" ] && ok "with the task id" || bad "task id" "$c"
[ "$(jq -c '[.[] | keys] | add | unique' <<<"$c")" = '["exitCode","finishedAt","status","taskId","toolUseId"]' ] \
  && ok "and nothing else (no description, no output path)" || bad "fields" "$c"
[ "$(events_of response.complete | wc -l | tr -d ' ')" = 1 ] && ok "Stop still sends response.complete" || bad "response" "$(paths)"

stop response-stop.sh Stop
[ -z "$(events_of command.background_complete)" ] && ok "a second Stop sends nothing already reported" || bad "dedupe" "$(events_of command.background_complete)"

echo ',"timestamp":"2026-11-05T10:06:00.000Z","content":"no notification"}' >> "$T"   # completes the half line
note toolu_bg4 completed 'Background command "Build" completed (exit code 2: No matches found)' 2026-11-05T10:07:00.000Z >> "$T"
stop response-stop.sh Stop
c=$(events_of command.background_complete | jq -c '[.payload.commands[] | [.toolUseId, .exitCode]]')
[ "$c" = '[["toolu_bg4",2]]' ] && ok "incremental: only what was appended, after the half-written line" || bad "incremental" "$c"

stop session-end.sh SessionEnd
[ ! -e "$BG/$SID.active" ] && [ ! -e "$BG/$SID.offset" ] && ok "SessionEnd drops the marker and offset" || bad "cleanup" "$(ls "$BG")"
[ "$(events_of session.end | wc -l | tr -d ' ')" = 1 ] && ok "SessionEnd still sends session.end" || bad "end" "$(paths)"

note toolu_bg5 completed 'Background command "x" completed (exit code 0)' >> "$T"
stop response-stop.sh Stop
[ -z "$(events_of command.background_complete)" ] && ok "sessions without a background command never scan" || bad "unmarked" "$(events_of command.background_complete)"

[ "$(python3 "$ROOT/scripts/bg_commands.py" scan "$TMP/missing.jsonl")" = "[]" ] && ok "missing transcript gives []" || bad "missing" "x"

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
