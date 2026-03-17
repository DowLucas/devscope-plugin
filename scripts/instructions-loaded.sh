#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')
CWD=$(echo "$INPUT" | jq -r '.cwd // ""')

# Build file list with hashes and optional content
FILES_JSON="[]"
if command -v jq >/dev/null 2>&1; then
  # Extract file paths from hook input
  FILE_PATHS=$(echo "$INPUT" | jq -r '.files[]? // empty' 2>/dev/null)
  if [ -z "$FILE_PATHS" ]; then
    # Try alternative field name
    FILE_PATHS=$(echo "$INPUT" | jq -r '.file_paths[]? // empty' 2>/dev/null)
  fi

  while IFS= read -r _file_path; do
    [ -z "$_file_path" ] && continue
    [ ! -f "$_file_path" ] && continue

    _hash=$(_ds_sha256 "$(cat "$_file_path")")
    _size=$(wc -c < "$_file_path" | tr -d ' ')

    # Determine file type
    _basename=$(basename "$_file_path")
    if [ "$_basename" = "CLAUDE.md" ]; then
      _type="claude_md"
    else
      _type="rule"
    fi

    # Relative path from cwd
    _relpath="$_file_path"
    if [ -n "$CWD" ]; then
      _relpath="${_file_path#$CWD/}"
    fi

    if [ "$DEVSCOPE_PRIVACY" = "private" ]; then
      FILES_JSON=$(echo "$FILES_JSON" | jq \
        --arg p "$_relpath" --arg h "$_hash" --argjson s "$_size" --arg t "$_type" \
        '. + [{"path":$p,"hash":$h,"size":$s,"type":$t}]')
    else
      _content=$(head -c 51200 "$_file_path")  # Cap at 50KB
      FILES_JSON=$(echo "$FILES_JSON" | jq \
        --arg p "$_relpath" --arg h "$_hash" --argjson s "$_size" --arg t "$_type" --arg c "$_content" \
        '. + [{"path":$p,"hash":$h,"size":$s,"type":$t,"content":$c}]')
    fi
  done <<< "$FILE_PATHS"
fi

PAYLOAD=$(jq -n \
  --argjson files "$FILES_JSON" \
  --arg tr "$TRIGGER" \
  '{files: $files, trigger: $tr}')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "instructions.loaded" "$PAYLOAD"
