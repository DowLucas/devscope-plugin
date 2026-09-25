#!/usr/bin/env bash
# Tests for the voice announcer (scripts/voice/) driven through the real hook
# scripts against a stub DevScope server. Delays are shortened to 1 s and
# speech goes to a file instead of the speakers.
#
#   bash tests/voice/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/scripts"
TMP=$(mktemp -d)
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/config"
unset DEVSCOPE_PRIVACY
# shellcheck disable=SC1091
. "$ROOT/tests/lib/stub.sh"
export DS_VOICE_SPEAK_LOG="$TMP/spoken" DEVSCOPE_NO_DRAIN=1
CONF="$XDG_CONFIG_HOME/devscope/voice.json"
PENDING="$HOME/.cache/devscope/voice/pending"
mkdir -p "$(dirname "$CONF")"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }

configure() {  # extra jq
  jq -n "{enabled: true, delays: {permission: 1, question: 1, failed: 1, finished: 1},
          reminder_interval: 60, max_reminders: 0} ${1:+| $1}" > "$CONF"
}
# Kill leftover timers and let their in-flight requests land before the next case.
reset() { pkill -f "$S/voice/timer.sh" 2>/dev/null || true; sleep 0.5; rm -rf "$PENDING" "$DS_VOICE_SPEAK_LOG"; reset_hits; }
spoken() { cat "$DS_VOICE_SPEAK_LOG" 2>/dev/null || true; }
lines() { spoken | grep -c . || true; }
wait_spoken() {  # min-lines max-seconds
  for _ in $(seq 1 $(( ${2:-5} * 10 ))); do [ "$(lines)" -ge "$1" ] && return 0; sleep 0.1; done
  return 1
}
hook() {  # script session cwd extra-json
  jq -n --arg s "$2" --arg c "$3" "{session_id: \$s, cwd: \$c} + ${4:-{\}}" | "$S/$1" >/dev/null 2>&1
}
PERM='{hook_event_name: "PermissionRequest", tool_name: "Bash", tool_input: {command: "bun run migrate --force", description: "Run the migration"}}'
DONE_BASH='{hook_event_name: "PostToolUse", tool_name: "Bash", tool_input: {command: "bun run migrate"}, tool_response: {}}'
DONE_READ='{hook_event_name: "PostToolUse", tool_name: "Read", tool_input: {file_path: "/x/a.ts"}, tool_response: {}}'

# 1. Unanswered permission prompt: AI summary spoken after the delay.
configure; reset; respond '{"text": "cloud wants to run the migration."}'
hook permission-request.sh s1 /work/cloud "$PERM"
[ -f "$PENDING/s1.json" ] && ok "permission prompt arms a marker" || bad "arm" "no marker"
[ "$(lines)" = 0 ] && ok "silent during the grace delay" || bad "grace" "$(spoken)"
wait_spoken 1 5 && [ "$(spoken)" = "cloud wants to run the migration." ] && ok "speaks the AI summary" || bad "summary" "$(spoken)"
[ "$(last .path)" = "/api/ai/voice-summary" ] && ok "calls the voice-summary endpoint" || bad "path" "$(last .)"
[ "$(last .body.trigger)/$(last .body.project)/$(last .body.tool)" = "permission/cloud/Bash" ] && ok "sends trigger, project and tool" || bad "body" "$(last .body)"
[ "$(last .body.detail)" = "runs the bun command" ] && ok "standard mode: command name only" || bad "standard detail" "$(last .body.detail)"
last .body | grep -q migrate && bad "standard leak" "$(last .body)" || ok "standard mode: no command text sent"

# 2. Answered in time: the tool ran, nothing is said.
configure; reset
hook permission-request.sh s2 /work/cloud "$PERM"
hook tool-complete.sh s2 /work/cloud "$DONE_BASH"
[ ! -f "$PENDING/s2.json" ] && ok "tool completing clears the marker" || bad "clear" "marker left"
sleep 2; [ "$(lines)" = 0 ] && ok "answered in time: silent" || bad "silent" "$(spoken)"

# 3. Another tool finishing in parallel does not count as an answer.
configure; reset
hook permission-request.sh s3 /work/cloud "$PERM"
hook tool-complete.sh s3 /work/cloud "$DONE_READ"
[ -f "$PENDING/s3.json" ] && ok "unrelated tool keeps the marker" || bad "parallel" "cleared"
hook prompt-submit.sh s3 /work/cloud '{hook_event_name: "UserPromptSubmit", prompt: "no, do it differently"}'
[ ! -f "$PENDING/s3.json" ] && ok "a new prompt clears the marker" || bad "prompt clear" "marker left"

# 4. Private mode: no request, local template.
configure; reset
DEVSCOPE_PRIVACY=private hook permission-request.sh s4 /work/secret "$PERM"
wait_spoken 1 5 && [ "$(spoken)" = "secret needs permission to use Bash." ] && ok "private: template spoken" || bad "private" "$(spoken)"
paths | grep -q voice-summary && bad "private request" "$(paths | tr '\n' ' ') $(cat "$HOME/.cache/devscope/voice/voice.log")" || ok "private: no summary request"

# 5. Open mode sends the command description; server down falls back to the template.
configure; reset
DEVSCOPE_PRIVACY=open hook permission-request.sh s5 /work/cloud "$PERM"
wait_spoken 1 5; [ "$(last .body.detail)" = "Run the migration" ] && ok "open: sends the description" || bad "open detail" "$(last .body)"
configure; reset
DEVSCOPE_URL=http://127.0.0.1:9 hook response-failed.sh s6 /work/plugin '{hook_event_name: "StopFailure", error: "rate_limit"}'
wait_spoken 1 8 && [ "$(spoken)" = "plugin stopped with an error." ] && ok "server down: template" || bad "down" "$(spoken)"

# 6. Questions via AskUserQuestion.
configure; reset; respond '{"text": "docs has a question about the layout."}'
hook tool-use.sh s7 /work/docs '{hook_event_name: "PreToolUse", tool_name: "AskUserQuestion", tool_input: {questions: [{question: "Which layout?"}]}}'
wait_spoken 1 5 && [ "$(last .body.trigger)" = "question" ] && ok "AskUserQuestion arms a question" || bad "question" "$(last .body)"

# 6b. Standard mode never sends elicitation text (its events don't either).
configure; reset
hook elicitation.sh s12 /work/cloud '{hook_event_name: "Elicitation", mcp_server_name: "db", message: "Enter the prod password"}'
wait_spoken 1 5; last .body | grep -q password && bad "elicitation leak" "$(last .body)" || ok "standard: no elicitation text sent"
[ "$(last .body.trigger)" = "question" ] && ok "elicitation arms a question" || bad "elicitation" "$(last .body)"

# 6c. idle_prompt settles a permission prompt (a rejected tool leaves no other trace).
configure '.delays.permission = 3'; reset
hook permission-request.sh s13 /work/cloud "$PERM"
hook notification.sh s13 /work/cloud '{hook_event_name: "Notification", notification_type: "idle_prompt", message: "waiting"}'
[ ! -f "$PENDING/s13.json" ] && ok "idle_prompt clears a permission marker" || bad "idle" "marker left"

# 6d. Text never starts with an option dash; state is owner-only.
configure; reset
DEVSCOPE_PRIVACY=private hook permission-request.sh s14 "/work/-o x" "$PERM"
wait_spoken 1 5 && [ "$(spoken)" = "o x needs permission to use Bash." ] && ok "leading dash stripped" || bad "dash" "$(spoken)"
[ "$(stat -c %a "$HOME/.cache/devscope/voice" 2>/dev/null || stat -f %Lp "$HOME/.cache/devscope/voice")" = 700 ] && ok "voice dir is 0700" || bad "perms" "$(ls -ld "$HOME/.cache/devscope/voice")"

# 7. Three sessions due together are one sentence.
configure '.delays.permission = 3'; reset
for p in alpha beta gamma; do DEVSCOPE_PRIVACY=private hook permission-request.sh "b-$p" "/work/$p" "$PERM"; done
wait_spoken 1 8; sleep 1.5
[ "$(lines)" = 1 ] && spoken | grep -q "^three sessions need you: " && ok "three due sessions batch into one sentence" || bad "batch" "$(spoken)"

# 8. Reminders repeat with a prefix, up to the maximum.
configure '.reminder_interval = 0 | .max_reminders = 1'; reset
DEVSCOPE_PRIVACY=private hook permission-request.sh s8 /work/cloud "$PERM"
sleep 3; [ "$(lines)" = 1 ] && ok "reminder interval is floored (no back-to-back repeat)" || bad "floor" "$(spoken)"
wait_spoken 2 8; sleep 1.5
[ "$(lines)" = 2 ] && [ "$(spoken | sed -n 2p)" = "Still waiting. cloud needs permission to use Bash." ] && ok "one reminder, then stops" || bad "reminder" "$(spoken)"

# 9. Muted: nothing until the mute ends.
configure ".mute_until = $(( $(date +%s) + 3 ))"; reset
DEVSCOPE_PRIVACY=private hook permission-request.sh s9 /work/cloud "$PERM"
sleep 2; [ "$(lines)" = 0 ] && ok "muted: silent" || bad "mute" "$(spoken)"
wait_spoken 1 5 && ok "announced when the mute ends" || bad "after mute" "nothing"

# 10. Disabled: no markers at all; stale markers are dropped.
jq -n '{enabled: false}' > "$CONF"; reset
hook permission-request.sh s10 /work/cloud "$PERM"
[ ! -d "$PENDING" ] || [ -z "$(ls "$PENDING")" ] && ok "disabled: nothing armed" || bad "disabled" "$(ls "$PENDING")"
configure; reset
hook permission-request.sh s11 /work/cloud "$PERM"
jq '.armedAt -= 4000' "$PENDING/s11.json" > "$TMP/m" && mv "$TMP/m" "$PENDING/s11.json"
sleep 2.5; [ ! -f "$PENDING/s11.json" ] && [ "$(lines)" = 0 ] && ok "stale marker dropped silently" || bad "stale" "$(spoken)"

# 11. CLI.
"$S/voice/cli.sh" off >/dev/null; [ "$(jq -r .enabled "$CONF")" = false ] && ok "cli off" || bad "cli off" "$(cat "$CONF")"
out=$("$S/voice/cli.sh" on); printf '%s' "$out" | grep -q "Voice announcer: on" && ok "cli on prints status" || bad "cli on" ""
"$S/voice/cli.sh" mute 15m >/dev/null; [ "$(jq -r .mute_until "$CONF")" -gt $(( $(date +%s) + 890 )) ] && ok "cli mute 15m" || bad "mute" "$(cat "$CONF")"
"$S/voice/cli.sh" mute soon >/dev/null && bad "bad duration" "accepted" || ok "cli rejects a bad duration"

reset
echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
