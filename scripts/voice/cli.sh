#!/usr/bin/env bash
# /devscope:voice — turn the voice announcer and auto voice (a spoken summary of every reply) on/off,
# mute, test, stop speech, install the Piper voice; `say` speaks text from
# stdin (/devscope:voice explain).
# Usage: cli.sh [status|on|off|mute <30s|15m|1h>|unmute|test|setup|finished on|off|auto [on|off]|auto-default [on|off]|speed [slow|normal|fast|<0.5-2>]|verbosity [explain|auto] [short|normal|long]|when-locked [quiet|play]|model [name|local|default]|stop|say]
set -uo pipefail
VOICE_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$VOICE_DIR/../_helpers.sh"
# shellcheck disable=SC1091
. "$VOICE_DIR/lib.sh"

PIPER_RELEASE="https://github.com/rhasspy/piper/releases/download/2023.11.14-2"
VOICE_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium"

status() {
  local mute pending
  echo "Voice announcer: $(_ds_voice_enabled && echo on || echo off)"
  echo "Engine: $(_ds_voice_engine) (setting: $(_ds_voice_conf .engine auto))"
  case "$(_ds_voice_engine)/$(_ds_voice_conf .engine auto)" in
    server/*) echo "Voice: $(current_voice) via $DEVSCOPE_URL (private sessions and outages use a local voice)" ;;
    */system) echo "Voice: $(current_voice)" ;;
  esac
  echo "Speed: $(_ds_voice_speed_text)"
  echo "Delays: permission $(_ds_voice_delay permission)s, question $(_ds_voice_delay question)s," \
       "failed $(_ds_voice_delay failed)s, finished $(_ds_voice_delay finished)s" \
       "($( [ "$(_ds_voice_conf .announce_finished false)" = true ] && echo announced || echo not announced))"
  echo "Reminders: every $(_ds_voice_int .reminder_interval "$DS_VOICE_REMINDER_INTERVAL")s, at most $(_ds_voice_int .max_reminders "$DS_VOICE_MAX_REMINDERS")"
  echo "Auto voice: $(_ds_voice_replies_on && echo on || echo off) in this session$( [ -n "$(_ds_voice_auto_session)" ] && echo " (set here)"); new sessions: $(_ds_voice_auto_default_on && echo on || echo off)"
  echo "Verbosity: explain $(_ds_voice_verbosity explain), auto $(_ds_voice_verbosity auto)"
  echo "Screen: $(_ds_voice_screen_locked && echo locked || echo unlocked); when locked: $(_ds_voice_conf .when_locked quiet)"
  mute=$(_ds_voice_int .mute_until 0)
  [ "$mute" -gt "$(date +%s)" ] && echo "Muted for $(( (mute - $(date +%s) + 59) / 60 )) more min"
  pending=$(find "$DS_VOICE_PENDING" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "Sessions waiting on you: $pending"
  echo "Settings: $DS_VOICE_CONFIG"
  case "$(_ds_voice_engine)" in
    server|piper) ;;
    *) echo "Tip: run '/devscope:setup' (API key) for the server voice, or '/devscope:voice setup' for Piper." ;;
  esac
}

# Auto voice: a spoken summary whenever Claude finishes a reply (`replies` is
# its old name). `auto` is this Claude Code window; `auto-default` is the
# setting for windows where you have not used `auto`.
auto_privacy_note() {
  if [ "${DEVSCOPE_PRIVACY:-standard}" = "private" ]; then
    echo "Private mode: replies stay on this machine, so you hear only which project finished."
  else
    echo "The reply is sent to your DevScope server to summarize; nothing is stored."
  fi
  if _ds_voice_muted; then echo "Note: voice is muted; run '/devscope:voice unmute'."; fi
}

auto() {
  local want="${1:-}" f
  _ds_voice_mkdirs
  _ds_voice_auto_prune
  f=$(_ds_voice_auto_file)
  if [ -z "$f" ]; then
    echo "Cannot tell which Claude Code session this is; use 'auto-default on|off' for all sessions."
    return 1
  fi
  if [ -z "$want" ]; then
    _ds_voice_replies_on && want=off || want=on
  fi
  case "$want" in
    on)
      printf 'on' > "$f"
      echo "Auto voice in this session: on. When Claude finishes a reply here, you hear a short summary of it."
      auto_privacy_note ;;
    off)
      printf 'off' > "$f"
      echo "Auto voice in this session: off." ;;
    *) echo "Usage: auto [on|off] (this session), auto-default [on|off] (new sessions)"; return 1 ;;
  esac
  echo "New sessions: $(_ds_voice_auto_default_on && echo on || echo off) (change with 'auto-default on|off')."
}

auto_default() {
  local want="${1:-}"
  if [ -z "$want" ]; then
    echo "Auto voice for new sessions: $(_ds_voice_auto_default_on && echo on || echo off)"
    return 0
  fi
  case "$want" in
    on)
      _ds_voice_set '.speak_replies = true'
      echo "Auto voice for new sessions: on. Sessions where you used 'auto' keep their own setting."
      auto_privacy_note ;;
    off)
      _ds_voice_set '.speak_replies = false'
      echo "Auto voice for new sessions: off. Sessions where you used 'auto' keep their own setting." ;;
    *) echo "Usage: auto-default [on|off]"; return 1 ;;
  esac
}

# Which voice speaks: model [name|local|default]. A server voice by name, or
# `local` for this computer's own voice (`say` on macOS, which speaks with the
# System voice set in Accessibility > Spoken Content, a Siri voice included).
# No name lists the choices.
LOCAL_HINT="On a Mac it uses your System voice: System Settings > Accessibility > Spoken Content > System voice (pick a Siri voice there to hear Siri)."

current_voice() {
  if [ "$(_ds_voice_conf .engine auto)" = system ]; then
    echo "local (this computer's own voice)"
  else
    echo "$(_ds_voice_conf .model "server default")"
  fi
}

model() {
  local name="${1:-}" offered
  if [ "$name" = local ]; then
    _ds_voice_set '.engine = "system"'
    echo "Voice: local. Speech uses this computer's own voice; the DevScope server still writes the summaries."
    echo "$LOCAL_HINT"
    return 0
  fi
  offered=$(_ds_api GET /api/ai/voice-models "" 5 2>/dev/null | jq -r '.models // [] | join(" ")' 2>/dev/null)
  if [ -z "$name" ]; then
    echo "Voice: $(current_voice)"
    if [ -n "$offered" ]; then
      echo "Choices: $offered (server voices, the first is its default), or local (this computer's own voice)"
    else
      echo "Choices: local (this computer's own voice). Could not list the server's voices; run '/devscope:setup' if the API key is missing."
    fi
    return 0
  fi
  if [ "$name" = default ]; then
    _ds_voice_set 'del(.model) | .engine = "auto"'
    echo "Voice: server default${offered:+ (${offered%% *})}"
    return 0
  fi
  case "$name" in
    *[!a-z0-9-]*) echo "Usage: model [name|local|default]"; return 1 ;;
  esac
  if [ -n "$offered" ] && ! printf ' %s ' "$offered" | grep -q " $name "; then
    echo "This server has no voice named '$name'. Choices: $offered, or local"
    return 1
  fi
  _ds_voice_set --arg m "$name" '.model = $m | .engine = "auto"'
  echo "Voice: $name"
}

# What happens while the screen is locked: quiet (default) holds announcements
# until unlock, skips auto voice and stops an explanation; play ignores the lock.
when_locked() {
  case "${1:-}" in
    '') echo "When locked: $(_ds_voice_conf .when_locked quiet) (screen is $(_ds_voice_screen_locked && echo locked || echo unlocked) now)" ;;
    quiet)
      _ds_voice_set '.when_locked = "quiet"'
      echo "When locked: quiet. Announcements wait until you unlock; auto voice is skipped; an explanation stops." ;;
    play)
      _ds_voice_set '.when_locked = "play"'
      echo "When locked: play. Speech plays whether or not the screen is locked." ;;
    *) echo "Usage: when-locked [quiet|play]"; return 1 ;;
  esac
}

# How detailed explain and auto voice are: verbosity [explain|auto] [short|normal|long].
verbosity() {
  local modes="explain auto" level mode
  case "${1:-}" in
    explain|auto) modes=$1; level=${2:-} ;;
    *) level=${1:-} ;;
  esac
  if [ -z "$level" ]; then
    for mode in $modes; do echo "Verbosity ($mode): $(_ds_voice_verbosity "$mode")"; done
    [ "$modes" = "explain auto" ] && echo "Set with: verbosity [explain|auto] short|normal|long"
    return 0
  fi
  case "$level" in
    short|normal|long) ;;
    *) echo "Usage: verbosity [explain|auto] short|normal|long"; return 1 ;;
  esac
  for mode in $modes; do
    _ds_voice_set --arg m "$mode" --arg l "$level" '.verbosity[$m] = $l'
    echo "Verbosity ($mode): $level"
  done
}

speed() {
  local rate
  if [ -z "${1:-}" ]; then
    echo "Speed: $(_ds_voice_speed_text). Choose slow (1.0x), normal (1.2x), fast (1.5x), or any number from 0.5 to 2."
    return 0
  fi
  rate=$(_ds_voice_speed_preset "$1") || { echo "Usage: speed [slow|normal|fast|<0.5-2>], e.g. speed 1.35"; return 1; }
  _ds_voice_set --argjson s "$rate" '.speed = $s'
  echo "Speed: $(_ds_voice_speed_text)"
}

# Speak text from stdin in the background. Called by /devscope:voice explain.
say() {
  local text job pid
  text=$(cat)
  [ -n "${text//[[:space:]]/}" ] || { echo "Nothing to say."; return 1; }
  if [ "$(_ds_voice_engine)" = "none" ]; then
    echo "No voice available. Run '/devscope:setup' (server voice) or '/devscope:voice setup' (Piper)."
    return 0
  fi
  _ds_voice_mkdirs
  job="$DS_VOICE_DIR/say/$(cat /proc/sys/kernel/random/uuid 2>/dev/null || uuidgen 2>/dev/null || echo "s-$(_ds_now_ns)").json"
  ( umask 077; jq -n --arg t "$text" --arg p "${DEVSCOPE_PRIVACY:-standard}" --arg project "$(basename "$PWD")" \
      '{text: $t, privacy: $p, project: $project}' > "$job" ) || return 1
  # This turn spoke: auto voice does not summarize its reply on top.
  pid=$(_ds_voice_claude_pid)
  [ -n "$pid" ] && : > "$DS_VOICE_DIR/spoke/$pid"
  _ds_voice_spawn "$VOICE_DIR/speak.sh" say "$job"
  echo "Speaking with: $(_ds_voice_engine) (about $(( (${#text} + 17) / 18 )) s). Stop with '/devscope:voice stop'."
}

# End speech in progress or queued: auto voice and explanations.
stop() {
  local f pid n=0
  for f in "$DS_VOICE_DIR/speakers/"*; do
    [ -f "$f" ] || continue
    pid=$(basename "$f")
    case "$pid" in *[!0-9]*) rm -f "$f"; continue ;; esac
    # speak.sh leads its own process group (setsid), which includes the player.
    if kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null; then n=$((n + 1)); fi
    rm -f "$f"
  done
  rm -f "$DS_VOICE_DIR/say/"*.json "$DS_VOICE_DIR/replies/"*.json "$DS_VOICE_PROGRESS" 2>/dev/null
  # macOS lock: a killed holder leaves its directory (with its pid) behind.
  # Queue tickets of killed speakers are pruned by the next one to look.
  [ "$n" -gt 0 ] && rm -rf "$DS_VOICE_DIR/speak.lock.d" 2>/dev/null
  echo "Stopped ($n speaking)."
}

to_seconds() {
  case "$1" in
    *[0-9]s) echo "${1%s}" ;;
    *[0-9]m) echo $(( ${1%m} * 60 )) ;;
    *[0-9]h) echo $(( ${1%h} * 3600 )) ;;
    *[0-9]) echo $(( $1 * 60 )) ;;
    *) return 1 ;;
  esac
}

setup() {
  local os arch asset
  mkdir -p "$DS_VOICE_DATA"
  if _ds_voice_piper_bin >/dev/null; then
    echo "Piper found: $(_ds_voice_piper_bin)"
  else
    os=$(uname -s) arch=$(uname -m)
    case "$os/$arch" in
      Linux/x86_64) asset=piper_linux_x86_64.tar.gz ;;
      Linux/aarch64|Linux/arm64) asset=piper_linux_aarch64.tar.gz ;;
      *)
        echo "No prebuilt Piper for $os/$arch. Install it with 'pipx install piper-tts'" \
             "(or keep the built-in system voice), then run setup again."
        return 1 ;;
    esac
    echo "Downloading Piper ($asset)..."
    curl -fsSL "$PIPER_RELEASE/$asset" | tar -xz -C "$DS_VOICE_DATA" || { echo "Download failed."; return 1; }
    echo "Installed Piper to $DS_VOICE_DATA/piper"
  fi
  if [ -f "$DS_VOICE_DEFAULT_MODEL" ]; then
    echo "Voice model found: $DS_VOICE_DEFAULT_MODEL"
  else
    echo "Downloading voice model (en_US lessac, ~60 MB)..."
    curl -fsSL -o "$DS_VOICE_DEFAULT_MODEL.json" "$VOICE_BASE/en_US-lessac-medium.onnx.json" && \
      curl -fsSL -o "$DS_VOICE_DEFAULT_MODEL.part" "$VOICE_BASE/en_US-lessac-medium.onnx" && \
      mv "$DS_VOICE_DEFAULT_MODEL.part" "$DS_VOICE_DEFAULT_MODEL" || { echo "Download failed."; return 1; }
  fi
  echo "Engine now: $(_ds_voice_engine)"
}

case "${1:-status}" in
  status) status ;;
  on)
    _ds_voice_set '.enabled = true'
    status ;;
  off)
    _ds_voice_set '.enabled = false'
    rm -f "$DS_VOICE_PENDING"/*.json 2>/dev/null
    echo "Voice announcer: off" ;;
  mute)
    secs=$(to_seconds "${2:-1h}") || { echo "Usage: mute <30s|15m|1h>"; exit 1; }
    _ds_voice_set --argjson t $(( $(date +%s) + secs )) '.mute_until = $t'
    echo "Muted for ${2:-1h}. Anything still waiting is announced when the mute ends." ;;
  unmute)
    _ds_voice_set '.mute_until = 0'
    echo "Unmuted." ;;
  finished)
    case "${2:-}" in
      on) _ds_voice_set '.announce_finished = true'; echo "Finished turns will be announced." ;;
      off) _ds_voice_set '.announce_finished = false'; echo "Finished turns will not be announced." ;;
      *) echo "Usage: finished on|off"; exit 1 ;;
    esac ;;
  auto|replies) auto "${2:-}" ;;
  auto-default) auto_default "${2:-}" ;;
  speed) speed "${2:-}" ;;
  verbosity) verbosity "${2:-}" "${3:-}" ;;
  when-locked) when_locked "${2:-}" ;;
  model) model "${2:-}" ;;
  say) say ;;
  stop) stop ;;
  test)
    echo "Speaking with: $(_ds_voice_engine)"
    _ds_voice_speak "$(_ds_voice_template permission "$(basename "$PWD")" Bash) This is a DevScope voice test." \
      "${DEVSCOPE_PRIVACY:-standard}" ;;
  setup) setup ;;
  *)
    echo "Usage: /devscope:voice [status|on|off|mute <30s|15m|1h>|unmute|test|setup|finished on|off|auto [on|off]|auto-default [on|off]|speed [slow|normal|fast|<0.5-2>]|verbosity [explain|auto] [short|normal|long]|when-locked [quiet|play]|model [name|local|default]|stop]"
    exit 1 ;;
esac
