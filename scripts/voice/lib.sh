# shellcheck shell=bash
# Voice announcer: speaks when a Claude Code session has been waiting on the
# user past a grace delay. Sourced (after _helpers.sh) by send-event.sh, which
# arms and clears on every hook event, by timer.sh, which waits and announces,
# and by cli.sh (/devscope:voice). Opt-in: nothing happens until voice.json
# says enabled.
#
# State under ~/.cache/devscope/voice/:
#   pending/<session>.json  one marker per blocked session. Later activity from
#                           that session deletes it, which is how answering in
#                           time keeps the announcer silent.
#   speak.lock              serializes speech across all sessions.
#   voice.log               errors and announcements.

DS_VOICE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DS_VOICE_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/devscope/voice.json"
DS_VOICE_DIR="${HOME}/.cache/devscope/voice"
DS_VOICE_PENDING="$DS_VOICE_DIR/pending"
DS_VOICE_LOG="$DS_VOICE_DIR/voice.log"
DS_VOICE_DATA="${XDG_DATA_HOME:-$HOME/.local/share}/devscope/piper"
DS_VOICE_DEFAULT_MODEL="$DS_VOICE_DATA/en_US-lessac-medium.onnx"
# A marker this old belongs to a session that most likely died without
# SessionEnd (closed terminal): drop it rather than keep reminding.
DS_VOICE_STALE_SEC=1800
# This many announcements falling due together are read as one sentence.
DS_VOICE_BATCH_MIN=3
DS_VOICE_REMINDER_INTERVAL=300
DS_VOICE_MAX_REMINDERS=3
# Floor for reminder_interval, so a 0 cannot loop speech back to back.
DS_VOICE_MIN_REMINDER_INTERVAL=5
# Longest single sleep in timer.sh, so off/unmute/re-arm are noticed promptly.
DS_VOICE_MAX_SLEEP=30
# A speech engine or player that hangs longer than this is killed.
DS_VOICE_SPEAK_TIMEOUT=30

# State and log can hold summaries of the user's work: keep them owner-only.
_ds_voice_mkdirs() {
  ( umask 077; mkdir -p "$DS_VOICE_PENDING" ) 2>/dev/null
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

_ds_voice_arm() {  # session-id type hook-input
  local sid="$1" type="$2" input="$3" m tool cwd last eid tmp
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
  eid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "v-$(_ds_now_ns)")
  _ds_voice_mkdirs
  tmp="$m.tmp.$$"
  jq -n \
    --arg eid "$eid" --arg sid "$sid" --arg type "$type" --arg tool "$tool" \
    --arg project "$(basename "${cwd:-session}")" \
    --arg detail "$(_ds_voice_detail "$type" "$tool" "$input")" \
    --arg last "$last" --arg privacy "${DEVSCOPE_PRIVACY:-standard}" \
    --argjson now "$(date +%s)" \
    '{eventId: $eid, sessionId: $sid, type: $type, tool: $tool, project: $project,
      detail: $detail, lastMessage: $last, privacy: $privacy, armedAt: $now, spoken: 0}' \
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
    text=$(_ds_api POST /api/ai/voice-summary "$body" 4 | jq -r '.text // empty' 2>/dev/null)
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
_ds_voice_announce_due() {
  local now f due eid text names n i
  local -a files=() eids=()
  now=$(date +%s)
  for f in "$DS_VOICE_PENDING"/*.json; do
    [ -f "$f" ] || continue
    due=$(_ds_voice_due "$f" "$now") || continue
    [ "$now" -ge "$due" ] || continue
    files+=("$f")
    eids+=("$(jq -r '.eventId' "$f" 2>/dev/null)")
  done
  n=${#files[@]}
  [ "$n" -gt 0 ] || return 0

  if [ "$n" -ge "$DS_VOICE_BATCH_MIN" ]; then
    names=$(for f in "${files[@]}"; do jq -r '.project' "$f"; done | awk '
      { a[NR] = $0 } END { for (i = 1; i <= NR; i++) printf "%s%s", (i == 1 ? "" : (i == NR ? " and " : ", ")), a[i] }')
    text="$(_ds_voice_count_word "$n") sessions need you: $names."
    _ds_voice_log "speak: $text"
    _ds_voice_speak "$text"
    for i in "${!files[@]}"; do _ds_voice_bump "${files[$i]}" "${eids[$i]}"; done
    return 0
  fi

  for i in "${!files[@]}"; do
    f="${files[$i]}"
    text=$(_ds_voice_text "$f") || continue
    # Summarizing takes a moment; skip a session that was answered meanwhile.
    [ "$(jq -r '.eventId' "$f" 2>/dev/null)" = "${eids[$i]}" ] || continue
    _ds_voice_log "speak: $text"
    _ds_voice_speak "$text"
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
  printf '%s\n' "$1" | _ds_voice_run "$bin" --model "$model" --output_file "$wav" >/dev/null 2>&1 && _ds_voice_play "$wav"
  rc=$?
  rm -f "$wav"
  return "$rc"
}

_ds_voice_system() {
  if command -v say >/dev/null 2>&1; then _ds_voice_run say "$1"
  elif command -v spd-say >/dev/null 2>&1; then _ds_voice_run spd-say -w "$1"
  elif command -v espeak-ng >/dev/null 2>&1; then _ds_voice_run espeak-ng "$1"
  elif command -v espeak >/dev/null 2>&1; then _ds_voice_run espeak "$1"
  else return 1
  fi >/dev/null 2>&1
}

# Which engine would speak right now: piper, system or none.
_ds_voice_engine() {
  local engine
  engine=$(_ds_voice_conf .engine auto)
  [ "$engine" = "off" ] && { echo none; return; }
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

# Speak a sentence. Piper when installed, otherwise the OS voice; silent if neither.
_ds_voice_speak() {
  local engine text
  # Engines take the text as an argument: a leading "-" (a project folder
  # named "-o x", say) would be parsed as an option.
  text=$(printf '%s' "$1" | sed 's/^[^[:alnum:]]*//')
  [ -n "$text" ] || return 0
  set -- "$text"
  engine=$(_ds_voice_conf .engine auto)
  [ "$engine" = "off" ] && return 0
  if [ -n "${DS_VOICE_SPEAK_LOG:-}" ]; then  # test hook
    printf '%s\n' "$1" >> "$DS_VOICE_SPEAK_LOG"
    return 0
  fi
  if [ "$engine" != "system" ] && _ds_voice_piper "$1"; then return 0; fi
  _ds_voice_system "$1" || _ds_voice_log "no speech engine available"
  return 0
}
