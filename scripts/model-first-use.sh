#!/usr/bin/env bash
# First use of a model: offer to review model instructions in CLAUDE.md and memory.
#
# SessionStart (`model`) and PostModelSwitch (`to_model`). A CLAUDE.md or memory
# file often says which model to use for what, or carries advice written for an
# older model; a new model is the moment those go stale. The first time a model
# shows up on this machine, Claude is asked to offer a review of them (never to
# do it unasked), the user sees a one-line notice, and a `model.first_use` event
# is sent.
#
# Seen models live in ~/.cache/devscope/models-seen, one id per line, without
# the context-window suffix (`claude-opus-5-5[1m]` is `claude-opus-5-5`). When
# that file does not exist yet it is seeded silently with the model in use (on
# a switch, the model switched from), so installing the plugin or clearing the
# cache does not make every model look new.
#
# Synchronous by necessity: Claude Code ignores the output of async hooks. It
# is local, the event is sent in the background, and it is silent on any error.
# DEVSCOPE_HINTS=off drops the notice and the message to Claude; the event is
# still sent.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh" 2>/dev/null || exit 0

INPUT=$(cat)
HOOK=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // ""' 2>/dev/null) || exit 0

# Lowercased, context-window suffix dropped; empty unless it looks like a model id.
normalize() {
  local m
  m=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/\[[^]]*\]$//')
  printf '%s' "$m" | grep -Eq '^[a-z0-9][a-z0-9._:@/-]{0,99}$' && printf '%s' "$m"
}

case "$HOOK" in
  SessionStart)
    MODEL=$(normalize "$(printf '%s' "$INPUT" | jq -r '.model // ""' 2>/dev/null)")
    PREVIOUS=""
    TRIGGER="session_start"
    ;;
  PostModelSwitch)
    MODEL=$(normalize "$(printf '%s' "$INPUT" | jq -r '.to_model // ""' 2>/dev/null)")
    PREVIOUS=$(normalize "$(printf '%s' "$INPUT" | jq -r '.from_model // ""' 2>/dev/null)")
    TRIGGER="model_switch"
    ;;
  *) exit 0 ;;
esac
[ -n "$MODEL" ] || exit 0

DIR="${HOME}/.cache/devscope"
SEEN="$DIR/models-seen"
mkdir -p -m 0700 "$DIR" 2>/dev/null || exit 0
if [ ! -f "$SEEN" ]; then
  # Baseline: what was in use before the plugin could see it is not new.
  printf '%s\n' "${PREVIOUS:-$MODEL}" > "$SEEN" 2>/dev/null || exit 0
  [ -z "$PREVIOUS" ] && exit 0
fi
grep -Fxq "$MODEL" "$SEEN" 2>/dev/null && exit 0
printf '%s\n' "$MODEL" >> "$SEEN" 2>/dev/null || exit 0

PAYLOAD=$(jq -n --arg m "$MODEL" --arg t "$TRIGGER" --arg p "$PREVIOUS" \
  '{model: $m, trigger: $t} | if $p != "" then . + {previousModel: $p} else . end') || exit 0
# Detached with every stream closed, so Claude Code does not wait on the network.
( printf '%s' "$INPUT" | "$SCRIPT_DIR/send-event.sh" "model.first_use" "$PAYLOAD" ) \
  </dev/null >/dev/null 2>&1 &

[ "${DEVSCOPE_HINTS:-on}" = "off" ] && exit 0

jq -n --arg h "$HOOK" \
  --arg msg "DevScope: first time on ${MODEL}." \
  --arg ctx "DevScope: this is the first time the user has used the model ${MODEL}. Before starting on their request (or right away if there is none yet), ask the user in one short question whether they want you to check their CLAUDE.md files and memory files for instructions about model selection or model usage (for example rules that name a specific model, which model to use for subagents, or advice written for an older model) and update them for ${MODEL}. Do not read or change those files unless the user agrees." \
  '{systemMessage: $msg, hookSpecificOutput: {hookEventName: $h, additionalContext: $ctx}}'
exit 0
