#!/usr/bin/env bash
# /devscope:voice — turn the voice announcer on/off, mute it, test it, and
# install the Piper voice.
# Usage: cli.sh [status|on|off|mute <30s|15m|1h>|unmute|test|setup|finished on|off]
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
  echo "Delays: permission $(_ds_voice_delay permission)s, question $(_ds_voice_delay question)s," \
       "failed $(_ds_voice_delay failed)s, finished $(_ds_voice_delay finished)s" \
       "($( [ "$(_ds_voice_conf .announce_finished false)" = true ] && echo announced || echo not announced))"
  echo "Reminders: every $(_ds_voice_int .reminder_interval "$DS_VOICE_REMINDER_INTERVAL")s, at most $(_ds_voice_int .max_reminders "$DS_VOICE_MAX_REMINDERS")"
  mute=$(_ds_voice_int .mute_until 0)
  [ "$mute" -gt "$(date +%s)" ] && echo "Muted for $(( (mute - $(date +%s) + 59) / 60 )) more min"
  pending=$(find "$DS_VOICE_PENDING" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  echo "Sessions waiting on you: $pending"
  echo "Settings: $DS_VOICE_CONFIG"
  [ "$(_ds_voice_engine)" = "piper" ] || echo "Tip: run '/devscope:voice setup' for the natural Piper voice."
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
  test)
    echo "Speaking with: $(_ds_voice_engine)"
    _ds_voice_speak "$(_ds_voice_template permission "$(basename "$PWD")" Bash) This is a DevScope voice test." ;;
  setup) setup ;;
  *)
    echo "Usage: /devscope:voice [status|on|off|mute <30s|15m|1h>|unmute|test|setup|finished on|off]"
    exit 1 ;;
esac
