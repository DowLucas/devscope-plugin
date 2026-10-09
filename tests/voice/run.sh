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
export DS_VOICE_SERVER_RETRY_DELAY=0.3 DS_VOICE_LOCK_POLL=1
# Unlocked unless a test creates this file (the suite may run on a locked desktop).
LOCK="$TMP/locked"; export DS_VOICE_LOCKED_FILE="$LOCK"
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
[ "$(last .body.model)" = "null" ] && ok "server voice: no model sent by default (server's default voice)" || bad "server model default" "$(last .body)"
configure '.model = "kokoro"'; server_speak standard >/dev/null
[ "$(last .body.model)" = "kokoro" ] && ok "server voice: the chosen model is sent" || bad "server model" "$(last .body)"
configure; respond "RIFFfake" "audio/wav"
configure '.voice = "af_heart" | .speed = 1.2 | .volume = 2.5'
server_speak standard >/dev/null; [ "$(last .body.voice)/$(last .body.speed)/$(last .body.volume)" = "af_heart/1.2/2.5" ] && ok "server voice: voice, speed and volume from voice.json" || bad "server config" "$(last .body)"
# Local playback volume: passed to the player, so only DevScope's speech gets louder.
play_with() {  # player -> the arguments it was called with
  local bin="$TMP/playbin-$1" t
  rm -rf "$bin"; mkdir -p "$bin"
  for t in awk jq timeout perl; do command -v "$t" >/dev/null && ln -s "$(command -v "$t")" "$bin/$t"; done
  printf '#!/bin/sh\necho "$*" > "%s"\n' "$TMP/play-args" > "$bin/$1"; chmod +x "$bin/$1"
  rm -f "$TMP/play-args"
  ( PATH="$bin"; . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_play /x.wav )
  cat "$TMP/play-args" 2>/dev/null
}
configure
[ "$(play_with pw-play)" = "--volume 1 /x.wav" ] && ok "playback volume: 1 by default" || bad "playback default" "$(play_with pw-play)"
configure '.playback_volume = 1.5'
[ "$(play_with pw-play)" = "--volume 1.5 /x.wav" ] && ok "playback volume: pw-play gets it" || bad "playback pw-play" "$(play_with pw-play)"
[ "$(play_with paplay)" = "--volume=98304 /x.wav" ] && ok "playback volume: paplay gets it in its units" || bad "playback paplay" "$(play_with paplay)"
[ "$(play_with afplay)" = "-v 1.5 /x.wav" ] && ok "playback volume: afplay gets it" || bad "playback afplay" "$(play_with afplay)"
[ "$(play_with aplay)" = "/x.wav" ] && ok "playback volume: aplay plays as received" || bad "playback aplay" "$(play_with aplay)"
configure '.playback_volume = 9'
[ "$(play_with pw-play)" = "--volume 3 /x.wav" ] && ok "playback volume: clamped to 3" || bad "playback clamp" "$(play_with pw-play)"
configure '.playback_volume = "loud"'
[ "$(play_with pw-play)" = "--volume 1 /x.wav" ] && ok "playback volume: not a number means 1" || bad "playback bad" "$(play_with pw-play)"
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
one=$(printf 'A summary that fits one request. %.0s' $(seq 1 12))
[ "$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_chunks "$one" | wc -l | tr -d ' ')" = 1 ] && ok "text that fits one request is one piece (${#one} chars)" || bad "one piece" ""
runon="Intro. $(for i in $(seq 1 60); do printf 'clause %s, ' "$i"; done)end."
runon_pieces=$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_chunks "$runon")
[ "$(printf '%s\n' "$runon_pieces" | awk 'length > 400' | wc -l | tr -d ' ')" = 0 ] && \
  [ "$(printf '%s\n' "$runon_pieces" | sed -n '2,$p' | sed '$d' | grep -vc ',$')" = 0 ] && ok "a long sentence is split at commas" || bad "comma split" "$runon_pieces"
huge=$(for i in $(seq 1 800); do printf 'word%s. ' "$i"; done)
[ "$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_chunks "$huge" | wc -c | tr -d ' ')" -le 5500 ] && ok "long text is cut near 5000 characters" || bad "cap" ""

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

# 10f. The bar is per session: progress.json names the session speaking.
PJ="$HOME/.cache/devscope/voice/progress.json"
progress_of() {  # wait for a speaking progress file, print a jq field
  for _ in $(seq 1 60); do [ -f "$PJ" ] && jq -e '.phase == "speaking"' "$PJ" >/dev/null 2>&1 && { jq -r "$1" "$PJ"; return; }; sleep 0.1; done
}
configure; reset; "$S/voice/cli.sh" auto-default on >/dev/null; respond '{"text": "Reply done."}'
DS_VOICE_TEST_SPEAK_SEC=1.5 hook response-stop.sh own-reply /work/api '{hook_event_name: "Stop", last_assistant_message: "Done."}'
[ "$(progress_of .sessionId)" = own-reply ] && ok "bar per session: a reply's progress names its session" || bad "progress reply session" "$(cat "$PJ" 2>/dev/null)"
wait_spoken 1 5; "$S/voice/cli.sh" auto-default off >/dev/null

# An explanation is started by a command, which is not told the session: the
# prompt hook recorded which session that Claude Code window runs.
configure; reset; sleep 60 & fakeclaude=$!
DS_VOICE_CLAUDE_PID=$fakeclaude hook prompt-submit.sh ex-session /work/api '{hook_event_name: "UserPromptSubmit", prompt: "explain it"}'
[ "$(cat "$HOME/.cache/devscope/voice/sessions/$fakeclaude" 2>/dev/null)" = ex-session ] && ok "bar per session: the prompt hook records the window's session" || bad "session record" "$(ls "$HOME/.cache/devscope/voice/sessions" 2>/dev/null)"
printf 'An explanation for one session.\n' | DS_VOICE_CLAUDE_PID=$fakeclaude DS_VOICE_TEST_SPEAK_SEC=1.5 "$S/voice/cli.sh" say >/dev/null
[ "$(progress_of .sessionId)" = ex-session ] && ok "bar per session: an explanation's progress names the session that asked" || bad "progress explain session" "$(cat "$PJ" 2>/dev/null)"
wait_spoken 1 5; kill "$fakeclaude" 2>/dev/null || true

# Someone who never set up voice pays no process lookups for it.
rm -f "$CONF"; rm -rf "$HOME/.cache/devscope/voice/sessions"
( unset CLAUDE_PID; DS_VOICE_CLAUDE_PID=12345 hook prompt-submit.sh nv-session /work/api '{hook_event_name: "UserPromptSubmit", prompt: "hi there"}' )
[ -z "$(ls "$HOME/.cache/devscope/voice/sessions" 2>/dev/null)" ] && ok "bar per session: nothing recorded without voice set up" || bad "session record gate" "$(ls "$HOME/.cache/devscope/voice/sessions")"
configure

# 11b. Screen lock: detection, then each kind of speech.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/loginctl" <<'EOF'
#!/bin/sh
case "$*" in
  *"show-user"*"Display"*) echo c7 ;;
  *"show-session c7"*"LockedHint"*) cat "$FAKE_LOCKED" 2>/dev/null || echo no ;;
esac
EOF
cat > "$TMP/bin/ioreg" <<'EOF'
#!/bin/sh
echo '    "IOConsoleUsers" = ({"CGSSessionScreenIsLocked"='"$(cat "$FAKE_LOCKED" 2>/dev/null || echo No)"',"kCGSSessionOnConsoleKey"=Yes})'
EOF
chmod +x "$TMP/bin/loginctl" "$TMP/bin/ioreg"
detect() {  # os locked-value -> 0 when locked
  ( unset DS_VOICE_LOCKED_FILE; export PATH="$TMP/bin:$PATH" FAKE_LOCKED="$TMP/fake-locked"
    printf '%s' "$2" > "$FAKE_LOCKED"
    . "$S/_helpers.sh"; . "$S/voice/lib.sh"
    FAKE_OS=$1; uname() { echo "$FAKE_OS"; }; pgrep() { return 1; }
    _ds_voice_screen_locked )
}
detect Linux yes && ok "linux: LockedHint=yes is locked" || bad "linux locked" ""
detect Linux no && bad "linux unlocked" "reads as locked" || ok "linux: LockedHint=no is unlocked"
detect Darwin Yes && ok "macOS: CGSSessionScreenIsLocked=Yes is locked" || bad "mac locked" ""
detect Darwin No && bad "mac unlocked" "reads as locked" || ok "macOS: unlocked when the key says No"
( unset DS_VOICE_LOCKED_FILE; export PATH="/usr/bin:/bin"; . "$S/_helpers.sh"; . "$S/voice/lib.sh"; uname() { echo Linux; }
  command() { [ "$2" = loginctl ] && return 1; builtin command "$@"; }; _ds_voice_screen_locked ) && bad "no logind" "locked" || ok "no logind (SSH, server): unlocked"

# Announcements wait while locked and are said after unlock, reminders untouched.
configure; reset; touch "$LOCK"
DEVSCOPE_PRIVACY=private hook permission-request.sh l1 /work/cloud "$PERM"
sleep 3; [ "$(lines)" = 0 ] && ok "locked: announcement held" || bad "held" "$(spoken)"
[ "$(jq -r .spoken "$PENDING/l1.json")" = 0 ] && ok "locked: no reminder used up" || bad "held count" "$(cat "$PENDING/l1.json")"
rm -f "$LOCK"
wait_spoken 1 5 && [ "$(spoken)" = "cloud needs permission to use Bash." ] && ok "unlocked: the announcement is said" || bad "after unlock" "$(spoken)"

# Auto voice skips a reply finished while locked.
reset; "$S/voice/cli.sh" auto-default on >/dev/null; respond '{"text": "summary"}'; touch "$LOCK"
hook response-stop.sh l2 /work/plugin '{hook_event_name: "Stop", last_assistant_message: "Done."}'
sleep 1.5; [ "$(lines)" = 0 ] && [ -z "$(paths | grep voice-summary)" ] && ok "locked: auto voice skipped, nothing sent" || bad "auto locked" "$(spoken)"
rm -f "$LOCK"; "$S/voice/cli.sh" auto-default off >/dev/null

# An explanation stops at the next piece once the screen locks.
reset
stopped=$( export DS_VOICE_SPEAK_LOG="$TMP/spoken"; . "$S/_helpers.sh"; . "$S/voice/lib.sh"
  _ds_voice_speak() { printf '%s\n' "$1" >> "$DS_VOICE_SPEAK_LOG"; touch "$LOCK"; }
  _ds_voice_speak_long "$LONG" standard; grep -c . "$DS_VOICE_SPEAK_LOG")
[ "$stopped" = 1 ] && ok "locked mid-explanation: stops after the current piece" || bad "explain stop" "$stopped pieces"
rm -f "$LOCK"

# when-locked play ignores the lock.
reset; "$S/voice/cli.sh" when-locked play >/dev/null; touch "$LOCK"
( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_can_play ) && ok "when-locked play: speaks while locked" || bad "play override" ""
"$S/voice/cli.sh" when-locked quiet >/dev/null
( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_can_play ) && bad "quiet" "plays while locked" || ok "when-locked quiet: silent while locked"
[[ "$("$S/voice/cli.sh" status)" == *"Screen: locked; when locked: quiet"* ]] && ok "status shows the screen and the setting" || bad "status screen" "$("$S/voice/cli.sh" status | grep Screen)"
"$S/voice/cli.sh" when-locked loud >/dev/null && bad "bad when-locked" "accepted" || ok "when-locked rejects an unknown value"
respond '{"models": ["chatterbox", "kokoro"]}'
[[ "$("$S/voice/cli.sh" model)" == *"Choices: chatterbox kokoro (server voices, the first is its default), or local"* ]] && [ "$(last .path)" = /api/ai/voice-models ] && ok "model lists the server's voices" || bad "model list" "$("$S/voice/cli.sh" model)"
"$S/voice/cli.sh" model kokoro >/dev/null; [ "$(jq -r .model "$CONF")" = kokoro ] && ok "model kokoro is stored" || bad "model set" "$(cat "$CONF")"
"$S/voice/cli.sh" model piper >/dev/null && bad "unknown model" "accepted" || ok "model rejects a voice the server does not offer"
"$S/voice/cli.sh" model "../x" >/dev/null && bad "bad model" "accepted" || ok "model rejects a malformed name"
"$S/voice/cli.sh" model default >/dev/null; [ "$(jq -r '.model // "unset"' "$CONF")" = unset ] && ok "model default clears the choice" || bad "model default" "$(cat "$CONF")"
# model local: this computer's own voice (macOS say, the System voice, Siri included).
[[ "$("$S/voice/cli.sh" model local)" == *"Spoken Content"* ]] && [ "$(jq -r .engine "$CONF")" = system ] && ok "model local switches to the computer's voice" || bad "model local" "$(cat "$CONF")"
[[ "$("$S/voice/cli.sh" status)" == *"Voice: local (this computer's own voice)"* ]] && ok "status shows local" || bad "status local" "$("$S/voice/cli.sh" status | grep -i voice:)"
mkdir -p "$TMP/saybin"; printf '#!/bin/sh\necho "$*" >> "%s"\n' "$TMP/said" > "$TMP/saybin/say"; chmod +x "$TMP/saybin/say"
reset; rm -f "$TMP/said" "$LOCK"
( unset DS_VOICE_SPEAK_LOG; export PATH="$TMP/saybin:$PATH"; . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_speak_long "Devscope: tests pass. Shall I open the PR?" standard )
[ "$(cat "$TMP/said" 2>/dev/null)" = "-r 210 Devscope: tests pass. Shall I open the PR?" ] && [ "$(hits)" = 0 ] && ok "local: say speaks at the set speed, no server request" || bad "local say" "$(cat "$TMP/said" 2>/dev/null) hits=$(hits)"
respond '{"models": ["chatterbox", "kokoro"]}'
"$S/voice/cli.sh" model chatterbox >/dev/null; [ "$(jq -r '.engine + "/" + .model' "$CONF")" = auto/chatterbox ] && ok "a server voice after local turns the server back on" || bad "back to server" "$(cat "$CONF")"
"$S/voice/cli.sh" model local >/dev/null; "$S/voice/cli.sh" model default >/dev/null
[ "$(jq -r '.engine + "/" + (.model // "unset")' "$CONF")" = auto/unset ] && ok "model default leaves local too" || bad "default after local" "$(cat "$CONF")"
rm -f "$LOCK"

# 12. Auto voice: reply summaries, independent of the announcer, on every finished turn.
STOP='{hook_event_name: "Stop", last_assistant_message: "I fixed the reminder timer. All 30 tests pass. Want me to open a PR?"}'
jq -n '{enabled: false}' > "$CONF"; reset
"$S/voice/cli.sh" auto-default on >/dev/null; [ "$(jq -r .speak_replies "$CONF")" = true ] && ok "auto-default on sets the default" || bad "auto-default" "$(cat "$CONF")"
"$S/voice/cli.sh" auto >/dev/null && bad "auto without a session" "accepted" || ok "auto needs to know the session"
respond '{"text": "plugin: the reminder timer is fixed and tests pass. It asks whether to open a PR."}'
hook response-stop.sh r1 /work/plugin "$STOP"
wait_spoken 1 5 && [ "$(spoken)" = "plugin: the reminder timer is fixed and tests pass. It asks whether to open a PR." ] && ok "reply summary spoken (announcer off)" || bad "reply" "$(spoken) $(cat "$HOME/.cache/devscope/voice/voice.log" 2>/dev/null)"
S_AT=/api/ai/voice-summary
[ "$(last_at $S_AT .body.trigger)/$(last_at $S_AT .body.project)/$(last_at $S_AT .body.length)" = "reply/plugin/normal" ] && ok "asks for a reply summary, normal length" || bad "reply body" "$(last_at $S_AT .)"
[[ "$(last_at $S_AT .body.last_message)" == *"All 30 tests pass"* ]] && ok "sends the reply to summarize" || bad "reply text" "$(last_at $S_AT .body)"
reset; "$S/voice/cli.sh" verbosity auto short >/dev/null
hook response-stop.sh r1b /work/plugin "$STOP"
wait_spoken 1 5; [ "$(last_at $S_AT .body.length)" = short ] && ok "auto voice sends its verbosity as length" || bad "reply length" "$(last_at $S_AT .body)"
jq 'del(.verbosity)' "$CONF" > "$TMP/c" && mv "$TMP/c" "$CONF"
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
"$S/voice/cli.sh" auto-default off >/dev/null; reset
hook response-stop.sh r6 /work/plugin "$STOP"; sleep 1.5
[ "$(lines)" = 0 ] && [ "$(hits)" = 0 ] || [ -z "$(paths | grep voice)" ] && ok "auto off: silent" || bad "auto off" "$(spoken)"

# 12b. Auto voice per session (Claude Code window = its claude process).
AUTO_DIR="$HOME/.cache/devscope/voice/auto"
sleep 300 & OTHER=$!   # stands in for a second Claude Code window
"$S/voice/cli.sh" auto-default off >/dev/null; reset; respond '{"text": "per session summary"}'
DS_VOICE_CLAUDE_PID=$$ "$S/voice/cli.sh" auto on >/dev/null
[ "$(cat "$AUTO_DIR/$$")" = on ] && ok "auto on is stored for this session only" || bad "auto session" "$(ls "$AUTO_DIR")"
[ "$(jq -r .speak_replies "$CONF")" = false ] && ok "auto leaves the default alone" || bad "auto default untouched" "$(cat "$CONF")"
DS_VOICE_CLAUDE_PID=$$ hook response-stop.sh p1 /work/plugin "$STOP"
wait_spoken 1 5 && ok "this session: reply summarized" || bad "session on" "$(spoken)"
reset
DS_VOICE_CLAUDE_PID=$OTHER hook response-stop.sh p2 /work/plugin "$STOP"; sleep 1.5
[ "$(lines)" = 0 ] && ok "another session (default off): silent" || bad "other session" "$(spoken)"
"$S/voice/cli.sh" auto-default on >/dev/null; reset
DS_VOICE_CLAUDE_PID=$OTHER "$S/voice/cli.sh" auto off >/dev/null
DS_VOICE_CLAUDE_PID=$OTHER hook response-stop.sh p3 /work/plugin "$STOP"; sleep 1.5
[ "$(lines)" = 0 ] && ok "auto off in a session wins over default on" || bad "session off" "$(spoken)"
[[ "$(DS_VOICE_CLAUDE_PID=$OTHER "$S/voice/cli.sh" status)" == *"Auto voice: off in this session (set here); new sessions: on"* ]] && ok "status shows this session and the default" || bad "status session" "$(DS_VOICE_CLAUDE_PID=$OTHER "$S/voice/cli.sh" status | grep Auto)"
DS_VOICE_CLAUDE_PID=$$ "$S/voice/cli.sh" auto >/dev/null; [ "$(cat "$AUTO_DIR/$$")" = off ] && ok "auto alone toggles this session" || bad "auto toggle" "$(cat "$AUTO_DIR/$$")"
kill "$OTHER" 2>/dev/null; wait "$OTHER" 2>/dev/null || true
DS_VOICE_CLAUDE_PID=$$ "$S/voice/cli.sh" auto on >/dev/null
[ ! -f "$AUTO_DIR/$OTHER" ] && ok "closed sessions are forgotten" || bad "prune" "$(ls "$AUTO_DIR")"
( unset DS_VOICE_CLAUDE_PID; export CLAUDE_PID=$$; . "$S/_helpers.sh"; . "$S/voice/lib.sh"; [ "$(_ds_voice_claude_pid)" = $$ ] ) && ok "uses CLAUDE_PID from Claude Code" || bad "CLAUDE_PID" ""
DS_VOICE_CLAUDE_PID=$$ "$S/voice/cli.sh" replies off >/dev/null; [ "$(cat "$AUTO_DIR/$$")" = off ] && ok "replies is still an alias for auto" || bad "replies alias" ""
rm -rf "$AUTO_DIR"; "$S/voice/cli.sh" auto-default off >/dev/null

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
[[ "$("$S/voice/cli.sh" status)" == *"Auto voice: off in this session; new sessions: off"* ]] && ok "status shows auto voice" || bad "status auto" "$("$S/voice/cli.sh" status | grep Auto)"
[[ "$("$S/voice/cli.sh" status)" == *"Verbosity: explain normal, auto normal"* ]] && ok "status shows verbosity" || bad "status verbosity" ""
"$S/voice/cli.sh" verbosity short >/dev/null
[ "$(jq -c .verbosity "$CONF")" = '{"explain":"short","auto":"short"}' ] && ok "verbosity short sets both" || bad "verbosity both" "$(cat "$CONF")"
"$S/voice/cli.sh" verbosity auto long >/dev/null
[ "$(jq -c .verbosity "$CONF")" = '{"explain":"short","auto":"long"}' ] && ok "verbosity auto long sets only auto" || bad "verbosity auto" "$(cat "$CONF")"
[ "$("$S/voice/cli.sh" verbosity explain)" = "Verbosity (explain): short" ] && ok "verbosity explain reads one mode (for the explain command)" || bad "verbosity read" "$("$S/voice/cli.sh" verbosity explain)"
"$S/voice/cli.sh" verbosity auto chatty >/dev/null && bad "bad verbosity" "accepted" || ok "verbosity rejects an unknown level"
jq '.verbosity.auto = "huge"' "$CONF" > "$TMP/c" && mv "$TMP/c" "$CONF"
[ "$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; _ds_voice_verbosity auto)" = normal ] && ok "a hand-edited unknown level reads as normal" || bad "verbosity fallback" ""
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

# 15. Session labels: every text starts with which session it is about.
LABELS="$HOME/.cache/devscope/voice/labels"
SA=/api/ai/voice-summary
configure; reset; rm -rf "$LABELS"
respond '{"text": "api, rate limiter fix. It wants to run the migration.", "label": "api, rate limiter fix"}'
hook permission-request.sh lab1 /work/api "$PERM"
wait_spoken 1 5 && [ "$(spoken)" = "api, rate limiter fix. It wants to run the migration." ] && ok "labels: the server's labelled text is spoken" || bad "label spoken" "$(spoken)"
[ "$(last_at $SA .body.session_id)" = lab1 ] && ok "labels: sends the session id" || bad "label sid" "$(last_at $SA .body)"
[ "$(last_at $SA .body.label)" = null ] && ok "labels: no label on the first call" || bad "label first" "$(last_at $SA .body)"
[ "$(cat "$LABELS/lab1" 2>/dev/null)" = "api, rate limiter fix" ] && ok "labels: keeps the label it got back" || bad "label kept" "$(ls "$LABELS" 2>/dev/null)"

reset; respond '{"text": "api, a newer title. Done.", "label": "api, a newer title"}'
hook permission-request.sh lab1 /work/api "$PERM"
wait_spoken 1 5; [ "$(last_at $SA .body.label)" = "api, rate limiter fix" ] && ok "labels: sends the kept label back" || bad "label resent" "$(last_at $SA .body)"
[ "$(cat "$LABELS/lab1")" = "api, rate limiter fix" ] && ok "labels: the first label stays, so the name never changes" || bad "label stable" "$(cat "$LABELS/lab1")"

configure; reset
DEVSCOPE_URL=http://127.0.0.1:9 hook response-failed.sh lab1 /work/api '{hook_event_name: "StopFailure", error: "x"}'
wait_spoken 1 8 && [ "$(spoken)" = "api, rate limiter fix. It stopped with an error." ] && ok "labels: server down, the template starts with the kept label" || bad "label template" "$(spoken)"

# After /clear Claude Code starts a new session id, but DevScope keeps its own
# (the session-state file send-event.sh reads); voice must name that one.
configure; reset; rm -rf "$LABELS"; respond '{"text": "x", "label": "api, kept"}'
STATE_EMAIL=$( . "$S/_helpers.sh"; _ds_normalize_email "${USER}@local")
STATE="$HOME/.cache/devscope/$( . "$S/_helpers.sh"; _ds_sha256 "${STATE_EMAIL}:/work/api:$$").session"
mkdir -p "$(dirname "$STATE")"; printf 'ds-session-1' > "$STATE"
# Called directly, so its parent (part of the state file name) is this shell.
jq -n '{session_id: "claude-new-id", cwd: "/work/api"} + '"$PERM" | "$S/send-event.sh" permission.request '{"toolName": "Bash"}' >/dev/null 2>&1
wait_spoken 1 5; [ "$(last_at $SA .body.session_id)" = ds-session-1 ] && ok "labels: sends the DevScope session id, which outlives /clear" || bad "label dsid" "$(last_at $SA .body)"
[ -f "$LABELS/ds-session-1" ] && ok "labels: the label is kept under the DevScope session" || bad "label dsid file" "$(ls "$LABELS")"
rm -f "$STATE"

# A private session is named from the local branch; nothing is sent.
configure; reset
REPO="$TMP/work/secret"; mkdir -p "$REPO"; git -C "$REPO" init -q -b feat/oauth-login 2>/dev/null || { git -C "$REPO" init -q; git -C "$REPO" checkout -q -b feat/oauth-login; }
DEVSCOPE_PRIVACY=private hook permission-request.sh lab2 "$REPO" "$PERM"
wait_spoken 1 5 && [ "$(spoken)" = "secret, oauth login. It needs permission to use Bash." ] && ok "labels: private session named from the local branch" || bad "label private" "$(spoken)"
paths | grep -q voice-summary && bad "label private request" "$(paths | tr '\n' ' ')" || ok "labels: private branch never sent"
git -C "$REPO" checkout -q -b main 2>/dev/null; reset
DEVSCOPE_PRIVACY=private hook permission-request.sh lab3 "$REPO" "$PERM"
wait_spoken 1 5 && [ "$(spoken)" = "secret needs permission to use Bash." ] && ok "labels: main says nothing, just the project" || bad "label main" "$(spoken)"

# The batch sentence says "topic in project" so labels' commas do not run together.
configure '.delays.permission = 3'; reset; rm -rf "$LABELS"; mkdir -p "$LABELS"
printf 'alpha, oauth login' > "$LABELS/bl-alpha"; printf 'beta, rate limit' > "$LABELS/bl-beta"
for p in alpha beta gamma; do DEVSCOPE_PRIVACY=private hook permission-request.sh "bl-$p" "/work/$p" "$PERM"; done
wait_spoken 1 10; sleep 1
[ "$(spoken)" = "three sessions need you: oauth login in alpha, rate limit in beta and gamma." ] && ok "labels: batch names topic in project" || bad "label batch" "$(spoken)"

# 16. Several sessions finishing at once: every reply is spoken, one at a time,
# first come first served (speech takes 1.5 s each here).
TL="$TMP/timeline"
queue_case() {  # label [env...]
  local label="$1"; shift
  reset; rm -f "$TL"; "$S/voice/cli.sh" auto-default on >/dev/null
  respond '{"text": "summary"}'
  for n in 1 2 3 4; do
    respond "{\"text\": \"session $n done.\"}"
    env "$@" DS_VOICE_TIMELINE="$TL" DS_VOICE_TEST_SPEAK_SEC=1.5 \
      bash -c 'jq -n --arg s "q'"$n"'" "{session_id: \$s, cwd: \"/work/p'"$n"'\", hook_event_name: \"Stop\", last_assistant_message: \"Done.\"}" | "$0/response-stop.sh" >/dev/null 2>&1' "$S"
    sleep 0.3
  done
  wait_spoken 4 20
  local starts ends overlap order
  starts=$(grep -c "^start" "$TL" 2>/dev/null || true); ends=$(grep -c "^end" "$TL" 2>/dev/null || true)
  # No speech starts before the previous one ended.
  overlap=$(awk '$1 == "start" { if (busy) bad = 1; busy = 1 } $1 == "end" { busy = 0 } END { print bad + 0 }' "$TL" 2>/dev/null || true)
  order=$(grep "^start" "$TL" 2>/dev/null | grep -o "session [0-9]" | tr -d "session " | tr -d "\n" || true)
  [ "$starts" = 4 ] && [ "$ends" = 4 ] && ok "queue ($label): all four replies spoken" || bad "queue $label count" "$(cat "$TL")"
  [ "$overlap" = 0 ] && ok "queue ($label): never two voices at once" || bad "queue $label overlap" "$(cat "$TL")"
  [ "$order" = 1234 ] && ok "queue ($label): spoken in the order the sessions finished" || bad "queue $label order" "$order"
  "$S/voice/cli.sh" auto-default off >/dev/null
}
queue_case flock
queue_case "macOS lock" DS_VOICE_NO_FLOCK=1

# A ticket left by a process that died does not block the queue.
reset; Q="$HOME/.cache/devscope/voice/queue"; mkdir -p "$Q"
sleep 0.01 & deadpid=$!; wait "$deadpid"
: > "$Q/0000000000000000001-$deadpid"
out=$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; DS_VOICE_QUEUE_MAX_WAIT=5; _ds_voice_with_lock echo ran )
[ "$out" = ran ] && [ ! -e "$Q/0000000000000000001-$deadpid" ] && ok "queue: a dead process's ticket is skipped and removed" || bad "dead ticket" "$out $(ls "$Q")"

# macOS lock: a live holder is waited for however long it speaks; a dead one is taken over.
LD="$HOME/.cache/devscope/voice/speak.lock.d"
sleep 3 & holder=$!
rm -rf "$LD"; mkdir -p "$LD"; printf '%s' "$holder" > "$LD/pid"; touch -d '10 minutes ago' "$LD" 2>/dev/null || true
t0=$(date +%s)
out=$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; DS_VOICE_NO_FLOCK=1; _ds_voice_with_lock echo ran )
waited=$(( $(date +%s) - t0 ))
[ "$out" = ran ] && [ "$waited" -ge 2 ] && ok "macOS lock: an old but live holder is not talked over" || bad "mkdir live" "out=$out waited=${waited}s"
rm -rf "$LD"; mkdir -p "$LD"; printf '%s' "$deadpid" > "$LD/pid"
out=$( . "$S/_helpers.sh"; . "$S/voice/lib.sh"; DS_VOICE_NO_FLOCK=1; _ds_voice_with_lock echo ran )
[ "$out" = ran ] && ok "macOS lock: a dead holder's lock is taken over" || bad "mkdir dead" "$out"
rm -rf "$LD"

# 17. Endings. A fake curl logs each request and plays back a status.
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
cat > "$FAKE/curl" <<'EOF'
#!/usr/bin/env bash
out=""; body=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -d) body="$2"; shift ;; esac; shift
done
printf '%s\n' "$body" >> "$FAKE_CURL_LOG"
[ -n "$out" ] && printf 'RIFFxxxxWAVE' > "$out"
printf '200 audio/wav'
exit "${FAKE_CURL_EXIT:-0}"
EOF
chmod +x "$FAKE/curl"
fetch() { ( export PATH="$FAKE:$PATH" FAKE_CURL_LOG="$TMP/curl.log" FAKE_CURL_EXIT="$1"
  . "$S/_helpers.sh"; . "$S/voice/lib.sh"; DS_VOICE_SERVER_RETRY_DELAY=0
  _ds_voice_server_fetch "hello" standard "$TMP/out.wav" 1 ); }
rm -f "$TMP/curl.log"
fetch 0 && ok "endings: a complete download plays" || bad "fetch ok" "$(cat "$TMP/curl.log")"
fetch 28 && bad "endings: partial download" "a 200 cut short by a timeout was accepted" || ok "endings: a 200 cut short (curl timeout) is not played"

# Long speech: only the last piece is padded with silence.
rm -f "$TMP/curl.log"
( export PATH="$FAKE:$PATH" FAKE_CURL_LOG="$TMP/curl.log"; unset DS_VOICE_SPEAK_LOG
  . "$S/_helpers.sh"; . "$S/voice/lib.sh"
  _ds_voice_play() { :; }
  _ds_voice_speak_long "$LONG" standard )
pieces=$(grep -c . "$TMP/curl.log")
pads=$(jq -r '.pad_ms // "default"' "$TMP/curl.log" | tr '\n' ' ')
expected="$(printf '0 %.0s' $(seq 2 "$pieces"))default "
[ "$pieces" -ge 2 ] && [ "$pads" = "$expected" ] && ok "endings: pieces run on, only the last gets trailing silence ($pieces pieces)" || bad "pad" "$pads"

reset
echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
