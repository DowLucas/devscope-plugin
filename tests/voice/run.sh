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
# The suite may itself run under Claude Code, whose child shells would match.
export DS_VOICE_SERVER_RETRY_DELAY=0.3
export DS_VOICE_SPEAK_LOG="$TMP/spoken" DS_VOICE_PRIVACY_LOG="$TMP/privacy" DEVSCOPE_NO_DRAIN=1 DS_VOICE_CLAUDE_PID=none
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
reset() {
  pkill -f "$S/voice/timer.sh" 2>/dev/null || true; pkill -f "$S/voice/speak.sh" 2>/dev/null || true; sleep 0.5
  rm -rf "$PENDING" "$HOME/.cache/devscope/voice/replies" "$HOME/.cache/devscope/voice/spoke" "$DS_VOICE_SPEAK_LOG" "$DS_VOICE_PRIVACY_LOG"
  reset_hits
}
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

# 2. Answered in time: the tool ran, nothing is said. (3 s: the tool-complete
# hook itself can take over a second on a busy runner.)
configure '.delays.permission = 3'; reset
hook permission-request.sh s2 /work/cloud "$PERM"
hook tool-complete.sh s2 /work/cloud "$DONE_BASH"
[ ! -f "$PENDING/s2.json" ] && ok "tool completing clears the marker" || bad "clear" "marker left"
sleep 4; [ "$(lines)" = 0 ] && ok "answered in time: silent" || bad "silent" "$(spoken)"

# 2b. Approved and still running: the command shows up as a child of the
# session's claude process (here: this test shell), so nothing is said.
configure; reset
sh -c ': bun run migrate --force; sleep 4' &
RUNNING=$!
DS_VOICE_CLAUDE_PID=$$ hook permission-request.sh s15 /work/cloud "$PERM"
[ "$(jq -r .match "$PENDING/s15.json")" = "bun run migrate --force" ] && ok "records the command locally" || bad "match" "$(cat "$PENDING/s15.json")"
sleep 2.5
[ "$(lines)" = 0 ] && [ ! -f "$PENDING/s15.json" ] && ok "approved long-running command: silent" || bad "approved running" "$(spoken)"
kill "$RUNNING" 2>/dev/null; wait "$RUNNING" 2>/dev/null || true
configure; reset
DS_VOICE_CLAUDE_PID=$$ DEVSCOPE_PRIVACY=private hook permission-request.sh s16 /work/cloud "$PERM"
wait_spoken 1 5 && ok "not running yet: still announced" || bad "not running" "silent"

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
[ "$(cat "$DS_VOICE_PRIVACY_LOG")" = "private" ] && ok "private: spoken as private (no server voice)" || bad "private voice" "$(cat "$DS_VOICE_PRIVACY_LOG")"
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

# 7. Three sessions falling due within the batch window are one sentence,
# even when they blocked seconds apart.
configure '.delays.permission = 8'; reset
for p in alpha beta gamma; do DEVSCOPE_PRIVACY=private hook permission-request.sh "b-$p" "/work/$p" "$PERM"; sleep 1; done
wait_spoken 1 20; sleep 2
[ "$(lines)" = 1 ] && spoken | grep -q "^three sessions need you: alpha, beta and gamma.$" && ok "staggered sessions batch into one sentence" || bad "batch" "$(spoken)"
[ "$(cat "$DS_VOICE_PRIVACY_LOG")" = "private" ] && ok "batch with a private session is spoken as private" || bad "batch privacy" "$(cat "$DS_VOICE_PRIVACY_LOG")"

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

# 10b. Server voice: /api/ai/voice-audio, played locally; never for private.
reset
server_speak() {  # privacy -> prints "rc <played bytes>"
  ( unset DS_VOICE_SPEAK_LOG
    . "$S/_helpers.sh"; . "$S/voice/lib.sh"
    _ds_voice_play() { cp "$1" "$TMP/played.wav"; }
    rm -f "$TMP/played.wav"
    _ds_voice_server "cloud needs you" "$1"; echo "$? $(cat "$TMP/played.wav" 2>/dev/null)" )
}
configure; respond "RIFFfake" "audio/wav"; reset_hits
[ "$(server_speak standard)" = "0 RIFFfake" ] && ok "server voice: plays the returned audio" || bad "server play" "$(server_speak standard)"
[ "$(last .path)" = "/api/ai/voice-audio" ] && [ "$(last .key)" = "test-key" ] && ok "server voice: calls voice-audio with the API key" || bad "server path" "$(last .)"
[ "$(last .body.text)/$(last .body.voice)/$(last .body.speed)" = "cloud needs you/am_michael/1.2" ] && ok "server voice: default am_michael at 1.2x" || bad "server body" "$(last .body)"
[ "$(last .body.volume)" = "null" ] && ok "server voice: volume left to the server by default" || bad "server volume default" "$(last .body)"
configure '.voice = "af_heart" | .speed = 1.2 | .volume = 2.5'
server_speak standard >/dev/null; [ "$(last .body.voice)/$(last .body.speed)/$(last .body.volume)" = "af_heart/1.2/2.5" ] && ok "server voice: voice, speed and volume from voice.json" || bad "server config" "$(last .body)"
configure; reset_hits
[ "$(server_speak private)" = "1 " ] && [ "$(hits)" = 0 ] && ok "server voice: never for private sessions" || bad "server private" "hits=$(hits)"
respond '{"error":"Server voice unavailable"}' "application/json" 503
[ "$(server_speak standard)" = "1 " ] && ok "server voice: 503 falls back (fails)" || bad "server 503" "$(server_speak standard)"
respond '{"ok":true}'
[ "$(DEVSCOPE_API_KEY='' server_speak standard)" = "1 " ] && ok "server voice: needs an API key" || bad "server no key" ""
# A passing failure (rate limit, restart) is tried again before the local voice speaks.
for status in 429 401 502; do
  respond '{"error":"Too many requests"}' "application/json" "$status"; reset_hits
  ( sleep 0.15; respond "RIFFagain" "audio/wav" ) & FLIP=$!
  out=$(server_speak standard); wait "$FLIP"
  [ "$out" = "0 RIFFagain" ] && [ "$(paths | grep -c voice-audio)" = 2 ] && ok "server voice: $status is retried, then plays" || bad "retry $status" "$out $(paths | tr '\n' ' ')"
done
respond '{"error":"bad text"}' "application/json" 400; reset_hits
[ "$(server_speak standard)" = "1 " ] && [ "$(paths | grep -c voice-audio)" = 1 ] && ok "server voice: a 400 is not retried" || bad "no retry 400" "$(paths | tr '\n' ' ')"
respond '{"error":"down"}' "application/json" 503; reset_hits
out=$(server_speak standard)
[ "$(paths | grep -c voice-audio)" = 2 ] && ok "server voice: gives up after one retry" || bad "retry cap" "$(paths | tr '\n' ' ')"

# 10c. Server voice for long speech: pieces fetched ahead, played in order.
long_speak() {  # text privacy -> prints the played pieces, one per line
  ( unset DS_VOICE_SPEAK_LOG
    . "$S/_helpers.sh"; . "$S/voice/lib.sh"
    _ds_voice_play() { cat "$1"; echo; }
    _ds_voice_speak_long "$1" "$2" )
}
LONG=$(for i in $(seq 1 30); do printf 'Sentence number %s is here to make this explanation long enough. ' "$i"; done)
configure; respond "RIFFpiece" "audio/wav"; reset_hits
out=$(long_speak "$LONG" standard)
n=$(printf '%s\n' "$out" | grep -c RIFFpiece)
[ "$n" -ge 5 ] && [ "$(paths | grep -c voice-audio)" = "$n" ] && ok "long speech: one voice-audio request per piece, all played ($n)" || bad "long server" "n=$n paths=$(paths | tr '\n' ' ')"
[ "$(DEVSCOPE_PRIVACY=private long_speak "$LONG" private | grep -c RIFF)" = 0 ] && ok "long speech: never the server voice for private" || bad "long private" ""

# 10d. Pieces: short first, at most 400 characters, sentence ends, nothing lost.
pieces=$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_chunks "$LONG")
[ "$(printf '%s\n' "$pieces" | head -1 | wc -c)" -le 201 ] && ok "first piece is short" || bad "first piece" "$(printf '%s\n' "$pieces" | head -1)"
[ "$(printf '%s\n' "$pieces" | awk 'length > 400' | wc -l | tr -d ' ')" = 0 ] && ok "no piece over 400 characters" || bad "piece size" ""
[ "$(printf '%s\n' "$pieces" | grep -vc '\.$')" = 0 ] && ok "pieces end at sentence ends" || bad "sentence ends" "$pieces"
[ "$(printf '%s\n' "$pieces" | tr '\n' ' ' | tr -s ' ' | sed 's/ $//')" = "$(printf '%s' "$LONG" | sed 's/ $//')" ] && ok "pieces add up to the text" || bad "lossless" ""
huge=$(for i in $(seq 1 400); do printf 'word%s. ' "$i"; done)
[ "$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_chunks "$huge" | wc -c | tr -d ' ')" -le 3500 ] && ok "long text is cut near 3000 characters" || bad "cap" ""

# 10e. Progress for the devscope-live bar: phase per piece, with its length.
python3 -c 'import wave,sys; w=wave.open(sys.argv[1],"wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000); w.writeframes(b"\0\0"*24000); w.close()' "$TMP/one-second.wav"
[ "$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_wav_ms "$TMP/one-second.wav")" = 1000 ] && ok "reads a WAV's length from its header" || bad "wav ms" ""
respond "" "audio/wav"; cp "$TMP/one-second.wav" "$STUB_DIR/resp"
snapshots=$( unset DS_VOICE_SPEAK_LOG
  export DS_VOICE_PROGRESS_KIND=explain DS_VOICE_PROGRESS_PROJECT=plugin
  . "$S/_helpers.sh"; . "$S/voice/lib.sh"
  _ds_voice_play() { jq -c '[.kind, .project, .phase, .piece, .pieces, (.pieceMs > 0), (.pid > 1)]' "$DS_VOICE_PROGRESS"; }
  _ds_voice_speak_long "$LONG" standard )
first=$(printf '%s\n' "$snapshots" | head -1); n=$(printf '%s\n' "$snapshots" | grep -c .)
[ "$first" = "[\"explain\",\"plugin\",\"speaking\",0,$n,true,true]" ] && ok "progress: speaking piece 0 of $n with its length" || bad "progress" "$first"
[ "$(printf '%s\n' "$snapshots" | tail -1 | jq '.[3]')" = $((n - 1)) ] && ok "progress: advances to the last piece" || bad "progress last" "$snapshots"
( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_progress speaking 0 1 ) ; [ ! -f "$HOME/.cache/devscope/voice/progress.json" ] || jq -e '.pid' "$HOME/.cache/devscope/voice/progress.json" >/dev/null && ok "no progress outside the speaker" || bad "progress leak" ""
rm -f "$HOME/.cache/devscope/voice/progress.json"
configure; reset
printf 'One short explanation.\n' | "$S/voice/cli.sh" say >/dev/null
wait_spoken 1 5; sleep 0.5
[ ! -f "$HOME/.cache/devscope/voice/progress.json" ] && ok "progress file removed when speech ends" || bad "progress cleanup" "$(cat "$HOME/.cache/devscope/voice/progress.json")"

# 12. Auto voice: reply summaries, independent of the announcer, on every finished turn.
STOP='{hook_event_name: "Stop", last_assistant_message: "I fixed the reminder timer. All 30 tests pass. Want me to open a PR?"}'
jq -n '{enabled: false}' > "$CONF"; reset
"$S/voice/cli.sh" auto >/dev/null; [ "$(jq -r .speak_replies "$CONF")" = true ] && ok "cli auto toggles on" || bad "auto toggle" "$(cat "$CONF")"
"$S/voice/cli.sh" replies off >/dev/null; [ "$(jq -r .speak_replies "$CONF")" = false ] && ok "replies is an alias for auto" || bad "replies alias" "$(cat "$CONF")"
"$S/voice/cli.sh" auto on >/dev/null
respond '{"text": "plugin: the reminder timer is fixed and tests pass. It asks whether to open a PR."}'
hook response-stop.sh r1 /work/plugin "$STOP"
wait_spoken 1 5 && [ "$(spoken)" = "plugin: the reminder timer is fixed and tests pass. It asks whether to open a PR." ] && ok "reply summary spoken (announcer off)" || bad "reply" "$(spoken) $(cat "$HOME/.cache/devscope/voice/voice.log" 2>/dev/null)"
S_AT=/api/ai/voice-summary
[ "$(last_at $S_AT .body.trigger)/$(last_at $S_AT .body.project)" = "reply/plugin" ] && ok "asks for a reply summary" || bad "reply body" "$(last_at $S_AT .)"
[[ "$(last_at $S_AT .body.last_message)" == *"All 30 tests pass"* ]] && ok "sends the reply to summarize" || bad "reply text" "$(last_at $S_AT .body)"
[ "$(lines)" = 1 ] && [ ! -d "$PENDING" ] || [ -z "$(ls "$PENDING" 2>/dev/null)" ] && ok "no announcer marker when the announcer is off" || bad "announcer" "$(ls "$PENDING")"

reset
DEVSCOPE_PRIVACY=private hook response-stop.sh r2 /work/secret "$STOP"
wait_spoken 1 5 && [ "$(spoken)" = "secret is done and waiting for you." ] && ok "private: template only" || bad "reply private" "$(spoken)"
paths | grep -q voice-summary && bad "reply private request" "$(paths)" || ok "private: reply never sent"

reset; respond '{"text": "x"}' "application/json" 500
DEVSCOPE_URL=http://127.0.0.1:9 hook response-stop.sh r3 /work/plugin "$STOP"
wait_spoken 1 8 && [ "$(spoken)" = "plugin is done and waiting for you." ] && ok "server down: template" || bad "reply down" "$(spoken)"

# A turn that spoke an explanation is not summarized on top of it.
reset; respond '{"text": "summary"}'
printf 'So, the question is why reminders come twice.\n' | DS_VOICE_CLAUDE_PID=$$ "$S/voice/cli.sh" say >/dev/null
DS_VOICE_CLAUDE_PID=$$ hook response-stop.sh r4 /work/plugin "$STOP"
sleep 2; [ "$(spoken)" = "So, the question is why reminders come twice." ] && ok "say speaks; that turn's reply is not summarized" || bad "say/suppress" "$(spoken)"
DS_VOICE_CLAUDE_PID=$$ hook response-stop.sh r4 /work/plugin "$STOP"
wait_spoken 2 5 && spoken | sed -n 2p | grep -q summary && ok "the next turn is summarized again" || bad "suppress once" "$(spoken)"

reset
"$S/voice/cli.sh" mute 1h >/dev/null
hook response-stop.sh r5 /work/plugin "$STOP"; sleep 1.5
[ "$(lines)" = 0 ] && ok "muted: no reply summary" || bad "reply mute" "$(spoken)"
"$S/voice/cli.sh" unmute >/dev/null
"$S/voice/cli.sh" auto off >/dev/null; reset
hook response-stop.sh r6 /work/plugin "$STOP"; sleep 1.5
[ "$(lines)" = 0 ] && [ "$(hits)" = 0 ] || [ -z "$(paths | grep voice)" ] && ok "auto off: silent" || bad "auto off" "$(spoken)"

# 13. stop ends speech in progress.
mkdir -p "$HOME/.cache/devscope/voice/speakers"
setsid sleep 30 & SPK=$!
: > "$HOME/.cache/devscope/voice/speakers/$SPK"
[[ "$("$S/voice/cli.sh" stop)" == *"Stopped (1 speaking)"* ]] && sleep 0.3 && ! kill -0 "$SPK" 2>/dev/null && ok "stop kills the speaker" || bad "stop" "still running"
wait "$SPK" 2>/dev/null || true

# 11. CLI.
"$S/voice/cli.sh" off >/dev/null; [ "$(jq -r .enabled "$CONF")" = false ] && ok "cli off" || bad "cli off" "$(cat "$CONF")"
out=$("$S/voice/cli.sh" on); printf '%s' "$out" | grep -q "Voice announcer: on" && ok "cli on prints status" || bad "cli on" ""
"$S/voice/cli.sh" mute 15m >/dev/null; [ "$(jq -r .mute_until "$CONF")" -gt $(( $(date +%s) + 890 )) ] && ok "cli mute 15m" || bad "mute" "$(cat "$CONF")"
"$S/voice/cli.sh" mute soon >/dev/null && bad "bad duration" "accepted" || ok "cli rejects a bad duration"
[[ "$("$S/voice/cli.sh" status)" == *"Auto voice: off"* ]] && ok "status shows auto voice" || bad "status auto" ""
"$S/voice/cli.sh" speed slow >/dev/null; [ "$(jq -r .speed "$CONF")" = 1.0 ] && ok "cli speed slow = 1.0x" || bad "speed slow" "$(cat "$CONF")"
"$S/voice/cli.sh" speed fast >/dev/null; [ "$(jq -r .speed "$CONF")" = 1.5 ] && ok "cli speed fast = 1.5x" || bad "speed fast" "$(cat "$CONF")"
[[ "$("$S/voice/cli.sh" speed)" == *"Speed: fast (1.5x)"* ]] && ok "cli speed shows the preset" || bad "speed show" "$("$S/voice/cli.sh" speed)"
"$S/voice/cli.sh" speed warp >/dev/null && bad "bad speed" "accepted" || ok "cli rejects an unknown speed"
"$S/voice/cli.sh" speed 1.35 >/dev/null; [ "$(jq -r .speed "$CONF")" = 1.35 ] && ok "cli speed takes a number" || bad "speed number" "$(cat "$CONF")"
[[ "$("$S/voice/cli.sh" speed)" == *"Speed: 1.35x."* ]] && ok "a number shows as itself" || bad "speed number show" "$("$S/voice/cli.sh" speed)"
"$S/voice/cli.sh" speed 1,25x >/dev/null; [ "$(jq -r .speed "$CONF")" = 1.25 ] && ok "cli speed takes 1,25x" || bad "speed comma" "$(cat "$CONF")"
"$S/voice/cli.sh" speed .8 >/dev/null; [ "$(jq -r .speed "$CONF")" = 0.8 ] && ok "cli speed takes .8" || bad "speed .8" "$(cat "$CONF")"
for v in 0.4 2.5 -1 1.2.3 1e1; do "$S/voice/cli.sh" speed "$v" >/dev/null && bad "speed $v" "accepted"; done
[ "$(jq -r .speed "$CONF")" = 0.8 ] && ok "cli rejects out-of-range and malformed numbers" || bad "speed range" "$(cat "$CONF")"
"$S/voice/cli.sh" speed normal >/dev/null; [ "$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_speed_name)" = normal ] && ok "cli speed normal" || bad "speed normal" "$(cat "$CONF")"
jq '.speed = 9' "$CONF" > "$TMP/c" && mv "$TMP/c" "$CONF"
[ "$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_speed)" = 2 ] && ok "a hand-edited speed is clamped to 2x" || bad "clamp" ""
printf '  \n' | "$S/voice/cli.sh" say >/dev/null && bad "empty say" "accepted" || ok "say rejects empty text"

reset
echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
