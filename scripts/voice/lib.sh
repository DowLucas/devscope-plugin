# shellcheck shell=bash
# Voice: the announcer, which speaks when a Claude Code session has been
# waiting on the user past a grace delay; auto voice, a spoken summary of every
# finished turn; and long speech for /devscope:voice explain. Sourced (after
# _helpers.sh) by send-event.sh, which arms and clears on every hook event, by
# timer.sh, which waits and announces, by speak.sh, which speaks replies and
# explanations, and by cli.sh (/devscope:voice). Opt-in: the announcer stays
# silent until voice.json says enabled, auto voice until speak_replies.
#
# State under ~/.cache/devscope/voice/:
#   pending/<session>.json  one marker per blocked session. Later activity from
#                           that session deletes it, which is how answering in
#                           time keeps the announcer silent.
#   replies/<session>.json  the latest finished turn to summarize, per session.
#   say/<id>.json           an explanation waiting to be spoken.
#   spoke/<claude-pid>      this turn already spoke an explanation, so its
#                           reply is not summarized on top of it.
#   speakers/<pid>          running speak.sh processes, for /devscope:voice stop.
#   progress.json           what the speaking speak.sh is doing, for the
#                           devscope-live mod's progress bar.
#   speak.lock              serializes speech across all sessions.
#   voice.log               errors and announcements.

DS_VOICE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DS_VOICE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/devscope/voice.json"
DS_VOICE_DIR="${HOME}/.cache/devscope/voice"
DS_VOICE_PENDING="$DS_VOICE_DIR/pending"
DS_VOICE_LOG="$DS_VOICE_DIR/voice.log"
DS_VOICE_PROGRESS="$DS_VOICE_DIR/progress.json"
DS_VOICE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/devscope/piper"
DS_VOICE_DEFAULT_MODEL="$DS_VOICE_DATA/en_US-lessac-medium.onnx"
# A marker this old belongs to a session that most likely died without
# SessionEnd (closed terminal): drop it rather than keep reminding.
DS_VOICE_STALE_SEC=1800
# This many announcements falling due within DS_VOICE_BATCH_WINDOW seconds of
# each other are read as one sentence (sessions rarely block the same second).
DS_VOICE_BATCH_MIN=3
DS_VOICE_BATCH_WINDOW=15
DS_VOICE_REMINDER_INTERVAL=300
DS_VOICE_MAX_REMINDERS=3
# Floor for reminder_interval, so a 0 cannot loop speech back to back.
DS_VOICE_MIN_REMINDER_INTERVAL=5
# Longest single sleep in timer.sh, so off/unmute/re-arm are noticed promptly.
DS_VOICE_MAX_SLEEP=30
# A speech engine or player that hangs longer than this is killed.
DS_VOICE_SPEAK_TIMEOUT=30
# Server voice (Kokoro): default for voice.json `voice`.
DS_VOICE_SERVER_VOICE=am_michael
# Speech rate for every engine, 1 = the voice's natural pace. voice.json
# `speed` holds a number; /devscope:voice speed takes one (0.5-2) or a preset.
DS_VOICE_SPEED_SLOW=1.0
DS_VOICE_SPEED_NORMAL=1.2
DS_VOICE_SPEED_FAST=1.5
DS_VOICE_SERVER_TIMEOUT=20
# A failed server-voice request is tried again after this many seconds when the
# failure is passing: a rate limit (429, or 401 from backends before the fix
# that reported their key limiter that way), the backend restarting (502/503/
# 504) or no response. Otherwise the local fallback voice, a different voice,
# would speak.
DS_VOICE_SERVER_RETRY_DELAY="${DS_VOICE_SERVER_RETRY_DELAY:-1.5}"
# Gemini takes ~3 s warm for a summary; this runs in the background timer, so
# waiting longer costs the user nothing and avoids falling back to the template.
DS_VOICE_SUMMARY_TIMEOUT=10
# Long speech is voiced in pieces: /api/ai/voice-audio takes at most 440
# characters. The first piece is short so speech starts quickly; the next one
# is fetched while the current one plays.
DS_VOICE_CHUNK_FIRST=200
DS_VOICE_CHUNK_MAX=400
# Longest text spoken at once (~3 minutes at 1.2x); the rest is cut.
DS_VOICE_LONG_MAX=3000
# How much of Claude's reply is sent for a summary (the server takes 4000).
DS_VOICE_REPLY_HEAD=2800
DS_VOICE_REPLY_TAIL=1100

# State and log can hold summaries of the user's work: keep them owner-only.
_ds_voice_mkdirs() {
  ( umask 077; mkdir -p "$DS_VOICE_PENDING" "$DS_VOICE_DIR/replies" "$DS_VOICE_DIR/say" \
      "$DS_VOICE_DIR/spoke" "$DS_VOICE_DIR/speakers" ) 2>/dev/null
}

_ds_voice_log() {
  _ds_voice_mkdirs
  ( umask 077; printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$DS_VOICE_LOG" ) 2>/dev/null
}

# --- Settings (voice.json) ---

# Print a setting by jq path, or the default when unset. `false` is a value.
_ds_voice_conf() {
  local v
  v=$(jq -r "($1) as \$v | if \$v == null then empty else \$v end" "$DS_VOICE_CONFIG" 2>/dev/null)
  printf '%s' "${v:-$2}"
}

_ds_voice_int() {
  local v
  v=$(_ds_voice_conf "$1" "$2")
  case "$v" in ''|*[!0-9]*) v="$2" ;; esac
  printf '%s' "$v"
}

_ds_voice_enabled() {
  [ -f "$DS_VOICE_CONFIG" ] && [ "$(_ds_voice_conf .enabled false)" = "true" ]
}

_ds_voice_replies_on() {
  [ -f "$DS_VOICE_CONFIG" ] && [ "$(_ds_voice_conf .speak_replies false)" = "true" ]
}

# How detailed spoken output is, per mode (explain, auto): short | normal | long.
# voice.json `verbosity: {explain, auto}`; anything else reads as normal.
_ds_voice_verbosity() {  # explain|auto
  local v
  v=$(_ds_voice_conf ".verbosity.$1" normal)
  case "$v" in short|normal|long) printf '%s' "$v" ;; *) printf normal ;; esac
}

_ds_voice_muted() {
  [ "$(_ds_voice_int .mute_until 0)" -gt "$(date +%s)" ]
}

# A preset name or a number from 0.5 to 2 (`1.35`, `.8`, `1,35`) -> the rate.
# Anything else, or out of range, fails.
_ds_voice_speed_preset() {
  case "$1" in
    slow) printf '%s' "$DS_VOICE_SPEED_SLOW" ;;
    normal) printf '%s' "$DS_VOICE_SPEED_NORMAL" ;;
    fast) printf '%s' "$DS_VOICE_SPEED_FAST" ;;
    *)
      printf '%s' "${1%x}" | tr ',' '.' | awk '
        $0 ~ /^[0-9]*\.?[0-9]+$/ && $0 + 0 >= 0.5 && $0 + 0 <= 2 { printf "%g", $0 + 0; found = 1 }
        END { exit !found }' ;;
  esac
}

# The speech rate, clamped to what the server voice accepts (0.5-2).
_ds_voice_speed() {
  _ds_voice_conf .speed "$DS_VOICE_SPEED_NORMAL" | awk -v d="$DS_VOICE_SPEED_NORMAL" '
    { v = $0 + 0; if ($0 !~ /^[0-9]*\.?[0-9]+$/) v = d; if (v < 0.5) v = 0.5; if (v > 2) v = 2; print v }'
}

# The preset a rate matches, or "custom".
_ds_voice_speed_name() {
  case "$(_ds_voice_speed)" in
    "$DS_VOICE_SPEED_SLOW"|1) echo slow ;;
    "$DS_VOICE_SPEED_NORMAL") echo normal ;;
    "$DS_VOICE_SPEED_FAST") echo fast ;;
    *) echo custom ;;
  esac
}

# How the current speed reads: "normal (1.2x)", or "1.35x" for one set as a number.
_ds_voice_speed_text() {
  local name
  name=$(_ds_voice_speed_name)
  if [ "$name" = custom ]; then printf '%sx' "$(_ds_voice_speed)"; else printf '%s (%sx)' "$name" "$(_ds_voice_speed)"; fi
}

# Grace delay before the first announcement, per trigger type.
_ds_voice_delay() {
  local d
  case "$1" in
    failed) d=10 ;;
    finished) d=120 ;;
    *) d=30 ;;
  esac
  _ds_voice_int ".delays.$1" "$d"
}

# Apply a jq update to voice.json, creating it if needed.
_ds_voice_set() {
  local cur tmp
  mkdir -p "$(dirname "$DS_VOICE_CONFIG")"
  cur=$(cat "$DS_VOICE_CONFIG" 2>/dev/null || echo '{}')
  tmp="$DS_VOICE_CONFIG.tmp.$$"
  printf '%s' "$cur" | jq "$@" > "$tmp" && mv "$tmp" "$DS_VOICE_CONFIG"
}

# --- Markers ---

_ds_voice_marker() {
  printf '%s/%s.json' "$DS_VOICE_PENDING" "$(printf '%s' "$1" | tr -cd 'A-Za-z0-9_-')"
}

# Arm or clear from one hook event. Arguments: DevScope event type, raw hook input.
_ds_voice_on_event() {
  _ds_voice_on_reply_event "$1" "$2"
  _ds_voice_enabled || return 0
  local et="$1" input="$2" sid tool m
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$sid" ] || return 0
  tool=$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)
  m=$(_ds_voice_marker "$sid")
  case "$et" in
    permission.request)
      if [ "$tool" = "AskUserQuestion" ]; then
        _ds_voice_arm "$sid" question "$input"
      else
        _ds_voice_arm "$sid" permission "$input"
      fi ;;
    tool.start)
      [ "$tool" = "AskUserQuestion" ] && _ds_voice_arm "$sid" question "$input" ;;
    elicitation.request) _ds_voice_arm "$sid" question "$input" ;;
    response.failed) _ds_voice_arm "$sid" failed "$input" ;;
    notification)
      # Claude Code also notifies about prompts the hooks above usually cover
      # already; these only fill in when no marker exists. idle_prompt means
      # Claude waits for a new prompt, so an earlier permission or question was
      # settled (a rejected tool may leave no other trace).
      case "$(printf '%s' "$input" | jq -r '.notification_type // empty' 2>/dev/null)" in
        permission_prompt) [ -f "$m" ] || _ds_voice_arm "$sid" permission "$input" ;;
        elicitation_dialog) [ -f "$m" ] || _ds_voice_arm "$sid" question "$input" ;;
        idle_prompt)
          case "$(jq -r '.type' "$m" 2>/dev/null)" in
            permission|question) _ds_voice_clear "$sid" ;;
          esac ;;
      esac ;;
    response.complete)
      _ds_voice_clear "$sid"
      [ "$(_ds_voice_conf .announce_finished false)" = "true" ] && _ds_voice_arm "$sid" finished "$input" ;;
    tool.complete|tool.fail) _ds_voice_clear "$sid" "$tool" ;;
    prompt.submit|prompt.expansion|elicitation.response|permission.denied|session.end)
      _ds_voice_clear "$sid" ;;
  esac
  return 0
}

# --- Auto voice (/devscope:voice auto on): reply summaries ---

# Independent of the announcer: on every finished turn, queue Claude's reply
# for speak.sh to summarize and speak. A turn that already spoke an explanation
# (/devscope:voice explain) is not summarized on top of it.
_ds_voice_on_reply_event() {  # event-type hook-input
  _ds_voice_replies_on || return 0
  local et="$1" input="$2" sid pid eid job tmp privacy="${DEVSCOPE_PRIVACY:-standard}" last=""
  case "$et" in
    prompt.submit)
      # A turn interrupted after it spoke never reached Stop: forget it.
      pid=$(_ds_voice_claude_pid)
      [ -n "$pid" ] && rm -f "$DS_VOICE_DIR/spoke/$pid"
      return 0 ;;
    response.complete) ;;
    *) return 0 ;;
  esac
  pid=$(_ds_voice_claude_pid)
  if [ -n "$pid" ] && [ -f "$DS_VOICE_DIR/spoke/$pid" ]; then
    rm -f "$DS_VOICE_DIR/spoke/$pid"
    return 0
  fi
  _ds_voice_muted && return 0
  [ "$(_ds_voice_conf .engine auto)" = "off" ] && return 0
  sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
  [ -n "$sid" ] || return 0
  # Private sessions keep the reply on this machine and get the template.
  [ "$privacy" = "private" ] || last=$(printf '%s' "$input" | jq -r \
    --argjson h "$DS_VOICE_REPLY_HEAD" --argjson t "$DS_VOICE_REPLY_TAIL" '
      .last_assistant_message // "" | if length > ($h + $t) then .[:$h] + " ... " + .[-$t:] else . end' 2>/dev/null)
  eid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "r-$(_ds_now_ns)")
  _ds_voice_mkdirs
  job="$DS_VOICE_DIR/replies/$(printf '%s' "$sid" | tr -cd 'A-Za-z0-9_-').json"
  tmp="$job.tmp.$$"
  jq -n --arg eid "$eid" --arg sid "$sid" --arg privacy "$privacy" --arg last "$last" \
    --arg project "$(basename "$(printf '%s' "$input" | jq -r '.cwd // "session"' 2>/dev/null)")" \
    '{eventId: $eid, sessionId: $sid, project: $project, lastMessage: $last, privacy: $privacy}' \
    > "$tmp" && mv "$tmp" "$job" || { rm -f "$tmp"; return 0; }
  _ds_voice_spawn "$DS_VOICE_LIB_DIR/speak.sh" reply "$sid" "$eid"
}

# The text for a queued reply: an AI summary, or the template when the session
# is private, the reply was empty or the server fails.
_ds_voice_reply_text() {  # job-file
  local body text="" project privacy
  read -r privacy < <(jq -r '.privacy' "$1" 2>/dev/null) || return 1
  project=$(jq -r '.project' "$1" 2>/dev/null)
  if [ "$privacy" != "private" ] && [ -n "${DEVSCOPE_API_KEY:-}" ]; then
    body=$(jq -c --arg length "$(_ds_voice_verbosity auto)" \
      '{trigger: "reply", project: .project, last_message: .lastMessage, length: $length}
       | with_entries(select(.value != ""))' "$1" 2>/dev/null)
    if printf '%s' "$body" | jq -e '.last_message' >/dev/null 2>&1; then
      text=$(_ds_api POST /api/ai/voice-summary "$body" "$DS_VOICE_SUMMARY_TIMEOUT" | jq -r '.text // empty' 2>/dev/null)
    fi
  fi
  [ -n "$text" ] || text=$(_ds_voice_template finished "$project")
  printf '%s' "$text"
}

# Delete a session's marker. With a tool name, only a marker for that tool (or
# one without a tool) is cleared, so another tool finishing in parallel does not
# count as answering a permission prompt.
_ds_voice_clear() {
  local m mt
  m=$(_ds_voice_marker "$1")
  [ -f "$m" ] || return 0
  if [ -n "${2:-}" ]; then
    mt=$(jq -r '.tool // ""' "$m" 2>/dev/null)
    [ -z "$mt" ] || [ "$mt" = "$2" ] || return 0
  fi
  rm -f "$m"
}

# What the summary may say about the block, within the privacy mode. Standard
# mode sends no more than its events already do; private mode sends nothing.
_ds_voice_detail() {  # type tool hook-input
  local type="$1" tool="$2" input="$3" sub
  case "${DEVSCOPE_PRIVACY:-standard}" in
    private) return 0 ;;
    open)
      printf '%s' "$input" | jq -r --arg t "$type" '
        if $t == "failed" then (.error // "" | tostring)
        elif .tool_input then
          (.tool_input | .questions[0].question // .description // .command // .file_path // .url // tostring)
        else (.message // "") end | .[:300]' 2>/dev/null
      return 0 ;;
  esac
  case "$type" in
    failed) printf '%s' "$input" | jq -r '.error // "" | tostring | .[:300]' 2>/dev/null ;;
    permission)
      if [ -n "$tool" ]; then
        sub=$(_ds_extract_subcommand "$tool" "$(printf '%s' "$input" | jq -c '.tool_input // {}' 2>/dev/null)")
        case "$tool" in
          Bash) [ -n "$sub" ] && printf 'runs the %s command' "$sub" ;;
          Read|Write|Edit) [ -n "$sub" ] && printf 'a .%s file' "$sub" ;;
        esac
      else
        _ds_voice_notification_message "$input"
      fi ;;
    question) _ds_voice_notification_message "$input" ;;
  esac
  return 0
}

# A Notification's message, which standard-mode events already send. Elicitation
# and AskUserQuestion text is sent only in open mode, so it is not used here.
_ds_voice_notification_message() {
  printf '%s' "$1" | jq -r 'if .hook_event_name == "Notification" then .message // "" | .[:100] else "" end' 2>/dev/null
}

# PID of the Claude Code process this hook runs under, or nothing.
_ds_voice_claude_pid() {
  local p=$$ i=0
  # Test hook: a PID, or "none" to skip the lookup.
  if [ -n "${DS_VOICE_CLAUDE_PID:-}" ]; then
    case "$DS_VOICE_CLAUDE_PID" in *[!0-9]*) ;; *) printf '%s' "$DS_VOICE_CLAUDE_PID" ;; esac
    return
  fi
  while [ "$p" -gt 1 ] && [ "$i" -lt 12 ]; do
    case "$(ps -o comm= -p "$p" 2>/dev/null)" in
      claude|*/claude) printf '%s' "$p"; return ;;
      node|*/node) ps -o args= -p "$p" 2>/dev/null | grep -q claude && { printf '%s' "$p"; return; } ;;
    esac
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$p" ] || return 0
    i=$((i + 1))
  done
}

# The start of a Bash command as it appears in the argv of the shell Claude
# Code runs it in (`... eval '<command>'`): up to the first quote, which the
# eval escapes, and at most 60 characters.
_ds_voice_command_needle() {
  printf '%s' "$1" | jq -r '.tool_input.command // "" | split("\n")[0] | split("\u0027")[0] | .[:60]' 2>/dev/null
}

# Claude Code has no hook for "the user approved": a running tool only shows up
# at PostToolUse, after it finishes. A Bash command is visible sooner, as a
# child process of the session's claude process, so an approved long-running
# command is detected here instead of being announced as still waiting.
_ds_voice_tool_started() {  # marker-file
  local pid needle
  pid=$(jq -r '.claudePid // ""' "$1" 2>/dev/null)
  needle=$(jq -r '.match // ""' "$1" 2>/dev/null)
  [ -n "$pid" ] && [ "${#needle}" -ge 3 ] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -Ao ppid=,args= 2>/dev/null | awk -v p="$pid" -v n="$needle" '$1 == p && index($0, n) { f = 1 } END { exit !f }'
}

_ds_voice_arm() {  # session-id type hook-input
  local sid="$1" type="$2" input="$3" m tool cwd last eid tmp pid="" match=""
  m=$(_ds_voice_marker "$sid")
  tool=$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null)
  # The same block reported twice (hook plus notification) keeps its timer.
  if [ -f "$m" ] && [ "$(jq -r '.type + "|" + .tool' "$m" 2>/dev/null)" = "$type|$tool" ]; then
    return 0
  fi
  cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
  last=""
  [ "${DEVSCOPE_PRIVACY:-standard}" = "open" ] && \
    last=$(printf '%s' "$input" | jq -r '.last_assistant_message // "" | .[:1500]' 2>/dev/null)
  # Local only (never sent): lets the timer see an approved command running.
  if [ "$type" = "permission" ] && [ "$tool" = "Bash" ]; then
    pid=$(_ds_voice_claude_pid)
    match=$(_ds_voice_command_needle "$input")
  fi
  eid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "v-$(_ds_now_ns)")
  _ds_voice_mkdirs
  tmp="$m.tmp.$$"
  jq -n \
    --arg eid "$eid" --arg sid "$sid" --arg type "$type" --arg tool "$tool" \
    --arg project "$(basename "${cwd:-session}")" \
    --arg detail "$(_ds_voice_detail "$type" "$tool" "$input")" \
    --arg last "$last" --arg privacy "${DEVSCOPE_PRIVACY:-standard}" \
    --arg pid "$pid" --arg match "$match" \
    --argjson now "$(date +%s)" \
    '{eventId: $eid, sessionId: $sid, type: $type, tool: $tool, project: $project,
      detail: $detail, lastMessage: $last, privacy: $privacy, armedAt: $now, spoken: 0,
      claudePid: $pid, match: $match}' \
    > "$tmp" && mv "$tmp" "$m" || { rm -f "$tmp"; return 0; }
  _ds_voice_spawn "$DS_VOICE_LIB_DIR/timer.sh" "$sid" "$eid"
}

# Start a process that outlives the hook (Claude Code may reap the hook's group).
_ds_voice_spawn() {
  if command -v setsid >/dev/null 2>&1; then
    ( setsid "$@" </dev/null >/dev/null 2>&1 & )
  elif command -v perl >/dev/null 2>&1; then  # macOS: no setsid(1), perl ships with it
    ( perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' "$@" </dev/null >/dev/null 2>&1 & )
  else
    ( nohup "$@" </dev/null >/dev/null 2>&1 & )
  fi
}

# Print when a marker's next announcement is due (epoch seconds). Fails when
# the marker is gone, stale (removed here) or out of reminders.
_ds_voice_due() {  # marker-file now
  local f="$1" now="$2" armed type spoken since interval
  read -r armed type spoken < <(jq -r '"\(.armedAt) \(.type) \(.spoken)"' "$f" 2>/dev/null) || return 1
  [ -n "$spoken" ] || return 1
  # Age counts from the end of a mute, so muting postpones rather than drops.
  since=$(_ds_voice_int .mute_until 0)
  [ "$since" -gt "$armed" ] || since=$armed
  if [ $((now - since)) -ge "$DS_VOICE_STALE_SEC" ]; then
    rm -f "$f"
    return 1
  fi
  [ "$spoken" -le "$(_ds_voice_int .max_reminders "$DS_VOICE_MAX_REMINDERS")" ] || return 1
  interval=$(_ds_voice_int .reminder_interval "$DS_VOICE_REMINDER_INTERVAL")
  [ "$interval" -ge "$DS_VOICE_MIN_REMINDER_INTERVAL" ] || interval=$DS_VOICE_MIN_REMINDER_INTERVAL
  echo $((armed + $(_ds_voice_delay "$type") + spoken * interval))
}

# --- Announcing ---

_ds_voice_template() {  # type project tool
  case "$1" in
    permission) printf '%s needs permission%s.' "$2" "${3:+ to use $3}" ;;
    question) printf '%s has a question for you.' "$2" ;;
    failed) printf '%s stopped with an error.' "$2" ;;
    *) printf '%s is done and waiting for you.' "$2" ;;
  esac
}

# The sentence for one marker: an AI summary unless the session is private or
# the backend is unreachable, then the local template.
_ds_voice_text() {
  local f="$1" type project tool privacy spoken body text=""
  read -r type privacy spoken < <(jq -r '"\(.type) \(.privacy) \(.spoken)"' "$f" 2>/dev/null) || return 1
  project=$(jq -r '.project' "$f" 2>/dev/null)
  tool=$(jq -r '.tool' "$f" 2>/dev/null)
  if [ "$privacy" != "private" ] && [ -n "${DEVSCOPE_API_KEY:-}" ]; then
    body=$(jq -c '{trigger: .type, project: .project, tool: .tool, detail: .detail, last_message: .lastMessage}
                  | with_entries(select(.value != ""))' "$f" 2>/dev/null)
    text=$(_ds_api POST /api/ai/voice-summary "$body" "$DS_VOICE_SUMMARY_TIMEOUT" | jq -r '.text // empty' 2>/dev/null)
  fi
  [ -n "$text" ] || text=$(_ds_voice_template "$type" "$project" "$tool")
  [ "$spoken" -gt 0 ] 2>/dev/null && text="Still waiting. $text"
  printf '%s' "$text"
}

_ds_voice_count_word() {
  local words=(zero one two three four five six seven eight nine)
  [ "$1" -lt 10 ] && printf '%s' "${words[$1]}" || printf '%s' "$1"
}

# Count one more announcement, unless the session re-armed or moved on meanwhile.
_ds_voice_bump() {  # marker-file event-id
  local tmp="$1.tmp.$$"
  [ "$(jq -r '.eventId' "$1" 2>/dev/null)" = "$2" ] || return 0
  jq '.spoken += 1' "$1" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  # Answered while jq ran: moving now would bring the marker back.
  if [ "$(jq -r '.eventId' "$1" 2>/dev/null)" = "$2" ]; then mv "$tmp" "$1"; else rm -f "$tmp"; fi
}

# Speak every marker that is due. Runs under the speak lock, so whichever timer
# gets there first announces for all sessions and the rest find nothing left.
# Markers due within the batch window count too when that makes a batch.
_ds_voice_announce_due() {
  local now f due eid text names n i privacy
  local -a files=() eids=() soon=() soon_eids=()
  now=$(date +%s)
  for f in "$DS_VOICE_PENDING"/*.json; do
    [ -f "$f" ] || continue
    due=$(_ds_voice_due "$f" "$now") || continue
    [ "$due" -le $((now + DS_VOICE_BATCH_WINDOW)) ] || continue
    if _ds_voice_tool_started "$f"; then
      rm -f "$f"
      continue
    fi
    eid=$(jq -r '.eventId' "$f" 2>/dev/null)
    if [ "$now" -ge "$due" ]; then
      files+=("$f"); eids+=("$eid")
    else
      soon+=("$f"); soon_eids+=("$eid")
    fi
  done
  n=${#files[@]}
  [ "$n" -gt 0 ] || return 0

  if [ $((n + ${#soon[@]})) -ge "$DS_VOICE_BATCH_MIN" ]; then
    for i in "${!soon[@]}"; do files+=("${soon[$i]}"); eids+=("${soon_eids[$i]}"); done
    n=${#files[@]}
    names=$(for f in "${files[@]}"; do jq -r '.project' "$f"; done | awk '
      { a[NR] = $0 } END { for (i = 1; i <= NR; i++) printf "%s%s", (i == 1 ? "" : (i == NR ? " and " : ", ")), a[i] }')
    text="$(_ds_voice_count_word "$n") sessions need you: $names."
    # It names every project, so it is private if any of them is.
    privacy=standard
    for f in "${files[@]}"; do
      [ "$(jq -r '.privacy' "$f" 2>/dev/null)" = "private" ] && privacy=private
    done
    _ds_voice_log "speak: $text"
    _ds_voice_speak "$text" "$privacy"
    for i in "${!files[@]}"; do _ds_voice_bump "${files[$i]}" "${eids[$i]}"; done
    return 0
  fi

  for i in "${!files[@]}"; do
    f="${files[$i]}"
    text=$(_ds_voice_text "$f") || continue
    # Summarizing takes a moment; skip a session that was answered meanwhile.
    [ "$(jq -r '.eventId' "$f" 2>/dev/null)" = "${eids[$i]}" ] || continue
    _ds_voice_log "speak: $text"
    _ds_voice_speak "$text" "$(jq -r '.privacy' "$f" 2>/dev/null)"
    _ds_voice_bump "$f" "${eids[$i]}"
  done
}

# Run a command while holding the global speak lock.
_ds_voice_with_lock() {
  local lock="$DS_VOICE_DIR/speak.lock" i=0
  _ds_voice_mkdirs
  if command -v flock >/dev/null 2>&1; then
    ( flock -w 120 9 || exit 0; "$@" ) 9>"$lock"
    return 0
  fi
  # macOS has no flock: mkdir is atomic. A holder killed mid-speech leaves the
  # directory behind, so one older than two minutes is taken over.
  until mkdir "$lock.d" 2>/dev/null; do
    # Rename before removing: only one waiter can win the rename.
    [ -n "$(find "$lock.d" -maxdepth 0 -mmin +2 2>/dev/null)" ] && \
      mv "$lock.d" "$lock.d.stale.$$" 2>/dev/null && rmdir "$lock.d.stale.$$" 2>/dev/null
    i=$((i + 1))
    [ "$i" -gt 400 ] && return 0
    sleep 0.3
  done
  "$@"
  rmdir "$lock.d" 2>/dev/null
  return 0
}

# --- Speech engines ---

# Voiced by the DevScope server (/api/ai/voice-audio, Kokoro on the homelab),
# so no local model is needed. Only for text the server already produced or
# may see: never for `private` sessions. Fails when the server has no voice.
_ds_voice_server() {  # text privacy
  local wav rc=1
  wav="$(mktemp "${TMPDIR:-/tmp}/ds-voice.XXXXXX")" || return 1
  if _ds_voice_server_fetch "$1" "${2:-standard}" "$wav"; then
    _ds_voice_play "$wav"; rc=$?
  fi
  rm -f "$wav"
  return "$rc"
}

# Fetch the server voice for a text (at most 440 characters) into a WAV file,
# trying a passing failure again up to `attempts` times in all (default 2).
_ds_voice_server_fetch() {  # text privacy out-file [attempts]
  local body code cfg="" attempt=1 attempts="${4:-2}"
  [ "${2:-standard}" != "private" ] && [ -n "${DEVSCOPE_API_KEY:-}" ] || return 1
  # volume is only sent when set, so the server's default applies otherwise.
  body=$(jq -nc --arg t "$1" --arg v "$(_ds_voice_conf .voice "$DS_VOICE_SERVER_VOICE")" \
    --argjson s "$(_ds_voice_speed)" \
    --arg vol "$(_ds_voice_conf .volume "")" \
    '{text: $t, voice: $v, speed: $s} + (if $vol == "" then {} else {volume: ($vol | tonumber)} end)' 2>/dev/null) || return 1
  cfg="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
  while :; do
    code=$(printf '%s' "$cfg" | curl --config - -s -o "$3" -w '%{http_code} %{content_type}' \
      -X POST "${DEVSCOPE_URL}/api/ai/voice-audio" -H "x-requested-with: devscope-cli" \
      -H "Content-Type: application/json" -d "$body" --max-time "$DS_VOICE_SERVER_TIMEOUT" 2>/dev/null)
    case "$code" in
      "200 audio/"*) return 0 ;;
    esac
    case "${code%% *}" in
      401|429|502|503|504|000|'') ;;
      *) break ;;
    esac
    [ "$attempt" -lt "$attempts" ] || break
    attempt=$((attempt + 1))
    sleep "$DS_VOICE_SERVER_RETRY_DELAY"
  done
  _ds_voice_log "server voice unavailable (${code:-no response}) $(head -c 160 "$3" 2>/dev/null | tr -d '\n')"
  return 1
}

_ds_voice_piper_bin() {
  if command -v piper >/dev/null 2>&1; then
    command -v piper
  elif [ -x "$DS_VOICE_DATA/piper/piper" ]; then
    printf '%s' "$DS_VOICE_DATA/piper/piper"
  else
    return 1
  fi
}

# Run a speech engine or player, killed if it hangs (it holds the speak lock).
_ds_voice_run() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$DS_VOICE_SPEAK_TIMEOUT" "$@"
  elif command -v perl >/dev/null 2>&1; then  # macOS
    perl -e 'alarm shift; exec @ARGV' "$DS_VOICE_SPEAK_TIMEOUT" "$@"
  else
    "$@"
  fi
}

_ds_voice_play() {
  local p
  for p in paplay pw-play aplay afplay; do
    if command -v "$p" >/dev/null 2>&1; then
      _ds_voice_run "$p" "$1" >/dev/null 2>&1
      return
    fi
  done
  return 1
}

_ds_voice_piper() {
  local bin model wav rc
  bin=$(_ds_voice_piper_bin) || return 1
  model=$(_ds_voice_conf .piper_model "$DS_VOICE_DEFAULT_MODEL")
  [ -f "$model" ] || return 1
  wav="$(mktemp "${TMPDIR:-/tmp}/ds-voice.XXXXXX")" || return 1
  # Piper stretches time: a length scale of 1/speed.
  printf '%s\n' "$1" | _ds_voice_run "$bin" --model "$model" --output_file "$wav" \
    --length_scale "$(awk -v s="$(_ds_voice_speed)" 'BEGIN { printf "%.2f", 1 / s }')" >/dev/null 2>&1 && _ds_voice_play "$wav"
  rc=$?
  rm -f "$wav"
  return "$rc"
}

_ds_voice_system() {
  local s wpm rate
  s=$(_ds_voice_speed)
  # say and espeak take words per minute (about 175 is natural); spd-say -100..100.
  wpm=$(awk -v s="$s" 'BEGIN { printf "%d", 175 * s }')
  rate=$(awk -v s="$s" 'BEGIN { r = (s - 1) * 100; if (r > 100) r = 100; if (r < -100) r = -100; printf "%d", r }')
  if command -v say >/dev/null 2>&1; then _ds_voice_run say -r "$wpm" "$1"
  elif command -v spd-say >/dev/null 2>&1; then _ds_voice_run spd-say -w -r "$rate" "$1"
  elif command -v espeak-ng >/dev/null 2>&1; then _ds_voice_run espeak-ng -s "$wpm" "$1"
  elif command -v espeak >/dev/null 2>&1; then _ds_voice_run espeak -s "$wpm" "$1"
  else return 1
  fi >/dev/null 2>&1
}

# Which engine would speak right now: piper, system or none.
_ds_voice_engine() {
  local engine
  engine=$(_ds_voice_conf .engine auto)
  [ "$engine" = "off" ] && { echo none; return; }
  case "$engine" in
    auto|server) [ -n "${DEVSCOPE_API_KEY:-}" ] && { echo server; return; } ;;
  esac
  if [ "$engine" != "system" ] && _ds_voice_piper_bin >/dev/null && \
     [ -f "$(_ds_voice_conf .piper_model "$DS_VOICE_DEFAULT_MODEL")" ]; then
    echo piper; return
  fi
  if command -v say >/dev/null 2>&1 || command -v spd-say >/dev/null 2>&1 || \
     command -v espeak-ng >/dev/null 2>&1 || command -v espeak >/dev/null 2>&1; then
    echo system; return
  fi
  echo none
}

# Speak a sentence: the server voice (not for private sessions), else Piper
# when installed, else the OS voice; silent if none works.
_ds_voice_speak() {  # text [privacy]
  local engine text privacy="${2:-standard}"
  # Engines take the text as an argument: a leading "-" (a project folder
  # named "-o x", say) would be parsed as an option.
  text=$(printf '%s' "$1" | sed 's/^[^[:alnum:]]*//')
  [ -n "$text" ] || return 0
  set -- "$text"
  engine=$(_ds_voice_conf .engine auto)
  [ "$engine" = "off" ] && return 0
  if [ -n "${DS_VOICE_SPEAK_LOG:-}" ]; then  # test hook
    printf '%s\n' "$1" >> "$DS_VOICE_SPEAK_LOG"
    [ -n "${DS_VOICE_PRIVACY_LOG:-}" ] && printf '%s\n' "$privacy" >> "$DS_VOICE_PRIVACY_LOG"
    return 0
  fi
  case "$engine" in
    auto|server) _ds_voice_server "$1" "$privacy" && return 0 ;;
  esac
  _ds_voice_speak_local "$1"
}

# Piper when installed (unless the engine is `system`), else the OS voice.
_ds_voice_speak_local() {  # text
  local text
  text=$(printf '%s' "$1" | sed 's/^[^[:alnum:]]*//')
  [ -n "$text" ] || return 0
  if [ "$(_ds_voice_conf .engine auto)" != "system" ] && _ds_voice_piper "$text"; then return 0; fi
  _ds_voice_system "$text" || _ds_voice_log "no speech engine available"
  return 0
}

# --- Long speech (explanations, reply summaries) ---

# Progress for the devscope-live mod's bar, written only under speak.sh (which
# sets DS_VOICE_PROGRESS_KIND) and only by the process holding the speak lock.
# `at` is when this phase or piece began (epoch ms), `pieceMs` how long the
# piece plays (0 when unknown), `pid` the speak.sh process group to stop.
_ds_voice_progress() {  # phase [piece pieces [piece-ms]]
  [ -n "${DS_VOICE_PROGRESS_KIND:-}" ] || return 0
  local tmp="$DS_VOICE_PROGRESS.tmp.$$"
  jq -n --arg kind "$DS_VOICE_PROGRESS_KIND" --arg project "${DS_VOICE_PROGRESS_PROJECT:-}" \
    --arg phase "$1" --argjson piece "${2:-0}" --argjson pieces "${3:-0}" --argjson ms "${4:-0}" \
    --argjson at "$(( $(_ds_now_ns) / 1000000 ))" --argjson pid "$$" \
    '{kind: $kind, project: $project, phase: $phase, piece: $piece, pieces: $pieces,
      pieceMs: $ms, at: $at, pid: $pid}' > "$tmp" 2>/dev/null && mv "$tmp" "$DS_VOICE_PROGRESS" || rm -f "$tmp"
}

# Remove the progress file if this process wrote it.
_ds_voice_progress_done() {
  [ "$(jq -r '.pid' "$DS_VOICE_PROGRESS" 2>/dev/null)" = "$$" ] && rm -f "$DS_VOICE_PROGRESS"
  return 0
}

# How long a WAV file plays, in milliseconds (0 when the header is unreadable).
_ds_voice_wav_ms() {
  local rate size
  rate=$(od -An -t u4 -j 28 -N 4 "$1" 2>/dev/null | tr -d ' ')
  size=$(wc -c < "$1" 2>/dev/null | tr -d ' ')
  case "$rate" in ''|*[!0-9]*) echo 0; return ;; esac
  case "$size" in ''|*[!0-9]*) echo 0; return ;; esac
  [ "$rate" -gt 0 ] && [ "$size" -gt 44 ] || { echo 0; return; }
  echo $(( (size - 44) * 1000 / rate ))
}

# Split a text into pieces of at most DS_VOICE_CHUNK_MAX characters (the first
# at most DS_VOICE_CHUNK_FIRST), ending at sentence ends where possible. One
# piece per line; the text is cut after DS_VOICE_LONG_MAX characters.
_ds_voice_chunks() {
  printf '%s\n' "$1" | tr '\n\r\t' '   ' | awk -v first="$DS_VOICE_CHUNK_FIRST" \
    -v max="$DS_VOICE_CHUNK_MAX" -v cap="$DS_VOICE_LONG_MAX" '
    { for (i = 1; i <= NF; i++) w[++n] = $i }
    END {
      cur = ""; lim = first; total = 0
      for (i = 1; i <= n && total < cap; i++) {
        word = substr(w[i], 1, max)
        if (cur != "" && length(cur) + 1 + length(word) > lim) { print cur; total += length(cur); cur = ""; lim = max }
        cur = (cur == "" ? word : cur " " word)
        # A sentence end closes a piece once it is half full.
        if (length(cur) >= lim / 2 && word ~ /[.!?:;][")]*$/) { print cur; total += length(cur); cur = ""; lim = max }
      }
      if (cur != "" && total < cap) print cur
    }'
}

# Speak a long text piece by piece. With the server voice the next piece is
# fetched while the current one plays, so there is no gap; if the server fails
# partway, the rest is spoken with a local voice.
_ds_voice_speak_long() {  # text [privacy]
  local privacy="${2:-standard}" engine chunk dir next i=0 n
  local -a chunks=()
  while IFS= read -r chunk; do
    [ -n "$chunk" ] && chunks+=("$chunk")
  done < <(_ds_voice_chunks "$1")
  n=${#chunks[@]}
  [ "$n" -gt 0 ] || return 0
  engine=$(_ds_voice_conf .engine auto)
  [ "$engine" = "off" ] && return 0
  if [ -n "${DS_VOICE_SPEAK_LOG:-}" ] || [ "$privacy" = "private" ] || [ -z "${DEVSCOPE_API_KEY:-}" ] || \
     { [ "$engine" != "auto" ] && [ "$engine" != "server" ]; }; then
    while [ "$i" -lt "$n" ]; do
      _ds_voice_progress speaking "$i" "$n"
      _ds_voice_speak "${chunks[$i]}" "$privacy"
      i=$((i + 1))
    done
    return 0
  fi
  dir=$(mktemp -d "${TMPDIR:-/tmp}/ds-voice.XXXXXX") || return 0
  _ds_voice_progress voicing 0 "$n"
  if ! _ds_voice_server_fetch "${chunks[0]}" "$privacy" "$dir/0.wav"; then
    while [ "$i" -lt "$n" ]; do
      _ds_voice_progress speaking "$i" "$n"
      _ds_voice_speak_local "${chunks[$i]}"
      i=$((i + 1))
    done
    rm -rf "$dir"
    return 0
  fi
  while [ "$i" -lt "$n" ]; do
    next=""
    if [ $((i + 1)) -lt "$n" ]; then
      # Mid-speech, a switch to the local voice is jarring: try harder (this
      # runs while the current piece plays, so the wait is mostly hidden).
      _ds_voice_server_fetch "${chunks[$((i + 1))]}" "$privacy" "$dir/$((i + 1)).wav" 4 &
      next=$!
    fi
    _ds_voice_progress speaking "$i" "$n" "$(_ds_voice_wav_ms "$dir/$i.wav")"
    _ds_voice_play "$dir/$i.wav"
    i=$((i + 1))
    if [ -n "$next" ] && ! wait "$next"; then
      while [ "$i" -lt "$n" ]; do
        _ds_voice_progress speaking "$i" "$n"
        _ds_voice_speak_local "${chunks[$i]}"
        i=$((i + 1))
      done
    fi
  done
  rm -rf "$dir"
  return 0
}
