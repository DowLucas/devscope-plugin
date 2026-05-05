#!/usr/bin/env bash
# Verify devscope-plugin hooks.json and scripts/ are in sync.
#
# Fails if:
#   1. A script referenced by hooks.json does not exist on disk.
#   2. A script in scripts/ is neither wired in hooks.json nor on the
#      explicit excluded allow-list below.
#
# The allow-list captures files that intentionally are not hook entry points:
#   _helpers.sh   — sourced helpers, never invoked directly
#   send-event.sh — shared event sender invoked by every hook script
#   setup.sh      — interactive installer, executed by install.sh / slash command

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOKS_JSON="$ROOT/hooks/hooks.json"
SCRIPTS_DIR="$ROOT/scripts"

EXCLUDED=(
  "_helpers.sh"
  "send-event.sh"
  "setup.sh"
)

if [ ! -f "$HOOKS_JSON" ]; then
  echo "ERROR: $HOOKS_JSON not found" >&2
  exit 1
fi

# Extract every command path under .hooks[].hooks[].command, take the basename,
# and dedupe. ${CLAUDE_PLUGIN_ROOT}/scripts/foo.sh -> foo.sh
referenced=$(jq -r '
  [.hooks
   | to_entries[]
   | .value[]
   | .hooks[]
   | select(.type == "command")
   | .command]
  | unique
  | .[]
' "$HOOKS_JSON" | awk -F/ '{print $NF}' | sort -u)

# Every .sh in scripts/ (top-level only, not subdirs like scripts/upskill/)
on_disk=$(find "$SCRIPTS_DIR" -maxdepth 1 -name '*.sh' -printf '%f\n' | sort -u)

excluded_set=$(printf '%s\n' "${EXCLUDED[@]}" | sort -u)

fail=0

# Check 1: every referenced script exists.
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  if ! [ -f "$SCRIPTS_DIR/$ref" ]; then
    echo "ERROR: hooks.json references $ref but scripts/$ref is missing" >&2
    fail=1
  fi
done <<< "$referenced"

# Check 2: every script on disk is wired or excluded.
while IFS= read -r script; do
  [ -z "$script" ] && continue
  if grep -qx "$script" <<< "$referenced"; then
    continue
  fi
  if grep -qx "$script" <<< "$excluded_set"; then
    continue
  fi
  echo "ERROR: scripts/$script is not wired in hooks.json and not on the excluded allow-list" >&2
  echo "  -> add it to hooks.json or to EXCLUDED in tests/check-hooks-consistency.sh" >&2
  fail=1
done <<< "$on_disk"

# Check 3: excluded entries that no longer exist on disk
while IFS= read -r ex; do
  [ -z "$ex" ] && continue
  if ! [ -f "$SCRIPTS_DIR/$ex" ]; then
    echo "ERROR: excluded allow-list entry $ex does not exist on disk" >&2
    fail=1
  fi
done <<< "$excluded_set"

if [ "$fail" -ne 0 ]; then
  echo "Hooks consistency check FAILED" >&2
  exit 1
fi

ref_count=$(printf '%s\n' "$referenced" | grep -c . || true)
disk_count=$(printf '%s\n' "$on_disk" | grep -c . || true)
echo "Hooks consistency OK: $ref_count wired, ${#EXCLUDED[@]} excluded, $disk_count total scripts"
