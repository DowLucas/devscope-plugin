#!/usr/bin/env bash
# Cross-platform helpers for DevScope plugin scripts
# Sourced by other scripts — not executed directly

# Load config: env var > config file > default
if [ -z "${DEVSCOPE_URL:-}" ]; then
  _DS_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/devscope/config"
  if [ -f "$_DS_CONFIG" ]; then
    while IFS='=' read -r key value; do
      key=$(echo "$key" | tr -d ' ')
      value=$(echo "$value" | sed 's/^"//;s/"$//' | sed "s/^'//;s/'$//")
      case "$key" in
        DEVSCOPE_URL) DEVSCOPE_URL="$value" ;;
        DEVSCOPE_API_KEY) DEVSCOPE_API_KEY="$value" ;;
        DEVSCOPE_PRIVACY) DEVSCOPE_PRIVACY="$value" ;;
      esac
    done < <(grep -v '^#' "$_DS_CONFIG" | grep -v '^$')
  fi
fi
DEVSCOPE_URL="${DEVSCOPE_URL:-http://localhost:6767}"

# SHA256 hash — works on Linux, macOS, and BSDs
_ds_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    echo -n "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    echo -n "$1" | shasum -a 256 | cut -d' ' -f1
  else
    echo -n "$1" | openssl dgst -sha256 -r | cut -d' ' -f1
  fi
}

# Nanosecond timestamp — Linux uses GNU date, macOS falls back to python3/perl/seconds
_ds_now_ns() {
  local ns
  ns=$(date +%s%N 2>/dev/null)
  # macOS date prints literal "%sN" or similar when %N is unsupported
  if [ "${ns##*[!0-9]*}" != "$ns" ] || [ -z "$ns" ]; then
    ns=$(python3 -c 'import time; print(int(time.time() * 1e9))' 2>/dev/null) || \
    ns=$(perl -MTime::HiRes=time -e 'printf "%d\n", time*1e9' 2>/dev/null) || \
    ns="$(date +%s)000000000"
  fi
  echo "$ns"
}

# ISO 8601 timestamp with milliseconds
_ds_timestamp() {
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null)
  # macOS BSD date doesn't support %N — verify milliseconds are digits
  if ! echo "$ts" | grep -qE '\.[0-9]{3}Z$'; then
    ts=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
  fi
  echo "$ts"
}

# Compute project hash for session-scoped state files
# Usage: PROJECT_HASH=$(_ds_project_hash "$CWD")
_ds_project_hash() {
  local cwd="$1"
  local email
  email=$(git -C "$cwd" config user.email 2>/dev/null || echo "${USER}@local")
  _ds_sha256 "${email}:${cwd}:${PPID}"
}

# Cross-platform reverse file (tac on Linux, tail -r on macOS)
_ds_tac() {
  if command -v tac >/dev/null 2>&1; then
    tac "$@"
  else
    tail -r "$@"
  fi
}

# Privacy mode: "private", "standard" (default), or "open"
DEVSCOPE_PRIVACY="${DEVSCOPE_PRIVACY:-standard}"

# Backwards-compat: map old values to new names silently
case "$DEVSCOPE_PRIVACY" in
  redacted) DEVSCOPE_PRIVACY="private" ;;
  full)     DEVSCOPE_PRIVACY="open" ;;
esac

# Sanitize tool input for privacy — extract only safe metadata keys
_ds_sanitize_tool_input() {
  local tool_name="$1"
  local tool_input="$2"

  case "$tool_name" in
    Read|Write|Edit)
      echo "$tool_input" | jq -c '{file_path: .file_path} // {}' 2>/dev/null || echo '{}'
      ;;
    Grep|Glob)
      echo "$tool_input" | jq -c '{pattern: .pattern, path: .path} // {}' 2>/dev/null || echo '{}'
      ;;
    Skill)
      echo "$tool_input" | jq -c '{skill: .skill} // {}' 2>/dev/null || echo '{}'
      ;;
    Bash)
      echo '{"redacted": true}'
      ;;
    *)
      echo '{"redacted": true}'
      ;;
  esac
}
