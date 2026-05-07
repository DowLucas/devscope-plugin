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

# Normalize an email for identity derivation (lowercase + trim whitespace).
# Must match backend's `computeDeveloperId` in
# devscope/packages/backend/src/services/developerLink.ts which does
# `email.toLowerCase().trim()` before SHA256. Plugin and backend MUST agree on
# this normalization or the same human ends up with split developer rows.
# Call this on any email before passing it to `_ds_sha256` for identity hashes
# (developerId and any session-/project-hash that mixes email into the input).
_ds_normalize_email() {
  # tr lowercases; awk strips leading/trailing whitespace (POSIX-portable trim).
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | awk '{ gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print }'
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
  # Normalize so a mixed-case `git user.email` doesn't fork the local
  # session-state file from the developerId derivation in send-event.sh.
  email=$(_ds_normalize_email "$email")
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

# Extract cumulative token usage from the last assistant message in transcript JSONL.
# Returns JSON: {inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens}
# Uses python3/jq to properly parse multi-line JSON entries from the transcript.
_ds_extract_token_usage() {
  local transcript_path="$1"
  if [ -z "$transcript_path" ] || [ ! -f "$transcript_path" ]; then
    echo '{}'
    return
  fi
  # Transcript entries may span multiple lines (code blocks contain literal newlines),
  # so grep-based extraction breaks. Use python3 for correct JSON parsing; fall back
  # to jq streaming for environments without python3.
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    lines = f.readlines()
for line in reversed(lines):
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    u = (obj.get('message') or {}).get('usage')
    if u:
        json.dump({
            'inputTokens': u.get('input_tokens', 0),
            'outputTokens': u.get('output_tokens', 0),
            'cacheCreationTokens': u.get('cache_creation_input_tokens', 0),
            'cacheReadTokens': u.get('cache_read_input_tokens', 0)
        }, sys.stdout)
        sys.exit(0)
print('{}')
" "$transcript_path" 2>/dev/null || echo '{}'
  else
    # Fallback: jq slurp with raw-input to handle multi-line entries
    jq -R -s -c '
      [split("\n") | .[] | select(length > 0) |
       try fromjson catch empty |
       select(.message.usage)] | last //  {} |
      if .message.usage then {
        inputTokens: (.message.usage.input_tokens // 0),
        outputTokens: (.message.usage.output_tokens // 0),
        cacheCreationTokens: (.message.usage.cache_creation_input_tokens // 0),
        cacheReadTokens: (.message.usage.cache_read_input_tokens // 0)
      } else {} end
    ' "$transcript_path" 2>/dev/null || echo '{}'
  fi
}

# --- API query helpers for plugin commands ---
# These are used by command scripts (e.g. /devscope:ask, /devscope:status)

# GET request to DevScope API. Returns JSON body followed by HTTP status on last line.
# Usage: RAW=$(_ds_api_get "/api/insights?limit=5")
#        HTTP_STATUS=$(echo "$RAW" | tail -1)
#        BODY=$(echo "$RAW" | sed '$d')
_ds_api_get() {
  local path="$1"
  local curl_args=(-s -X GET "${DEVSCOPE_URL}${path}" -H "Content-Type: application/json" --max-time 15 -w '\n%{http_code}')
  local curl_config=""
  if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
    curl_config="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
  fi
  echo "$curl_config" | curl --config - "${curl_args[@]}" 2>/dev/null
}

# POST request to DevScope API. Returns JSON body followed by HTTP status on last line.
# Usage: RAW=$(_ds_api_post "/api/ai/chat" '{"question":"hello"}')
#        HTTP_STATUS=$(echo "$RAW" | tail -1)
#        BODY=$(echo "$RAW" | sed '$d')
_ds_api_post() {
  local path="$1"
  local body="$2"
  local curl_args=(-s -X POST "${DEVSCOPE_URL}${path}" -H "Content-Type: application/json" -H "x-requested-with: devscope-cli" -d "$body" --max-time 30 -w '\n%{http_code}')
  local curl_config=""
  if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
    curl_config="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
  fi
  echo "$curl_config" | curl --config - "${curl_args[@]}" 2>/dev/null
}

# Quick health check. Returns 0 if server is reachable, 1 otherwise.
# Prints the health JSON on success, "UNREACHABLE" on failure.
_ds_health_check() {
  local result
  result=$(curl -sf --max-time 5 "${DEVSCOPE_URL}/api/health" 2>&1)
  local exit_code=$?
  if [ $exit_code -eq 0 ] && [ -n "$result" ]; then
    echo "$result"
    return 0
  else
    echo "UNREACHABLE"
    return 1
  fi
}

# Privacy mode: "private", "standard" (default), or "open"
DEVSCOPE_PRIVACY="${DEVSCOPE_PRIVACY:-standard}"

# Backwards-compat: map old values to new names silently
case "$DEVSCOPE_PRIVACY" in
  redacted) DEVSCOPE_PRIVACY="private" ;;
  full)     DEVSCOPE_PRIVACY="open" ;;
esac

# Repo-relative path. Returns the path relative to the git repo root that
# contains $cwd, or empty if the target is outside the repo (or repo
# resolution fails). Pure read-only — `git rev-parse --show-toplevel` is fast
# and side-effect-free, so we recompute per call rather than maintain a
# session cache. DEV-74.
_ds_repo_relative() {
  local target="$1"
  local cwd="$2"
  [ -z "$target" ] || [ -z "$cwd" ] && return 0
  local repo_root
  repo_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || return 0
  [ -z "$repo_root" ] && return 0
  case "$target" in
    "$repo_root") printf '%s' "." ;;
    "$repo_root"/*) printf '%s' "${target#$repo_root/}" ;;
    *) ;;  # outside repo — caller buckets via [ext-redacted:…]
  esac
}

# Read the per-session org salt that `session.start` cached locally
# (see send-event.sh). Empty if no cache yet (e.g. first event before
# session.start completes, or the backend doesn't expose a salt).
_ds_load_salt() {
  local cwd="$1"
  [ -z "$cwd" ] && return 0
  local _ph _f
  _ph=$(_ds_project_hash "$cwd")
  _f="${HOME}/.cache/devscope/${_ph}.salt"
  [ -f "$_f" ] || return 0
  awk -F= '$1=="SALT"{print $2; exit}' "$_f" 2>/dev/null
}

# Read the salt_version stamped by `session.start`. Empty if no cache yet.
_ds_load_salt_version() {
  local cwd="$1"
  [ -z "$cwd" ] && return 0
  local _ph _f
  _ph=$(_ds_project_hash "$cwd")
  _f="${HOME}/.cache/devscope/${_ph}.salt"
  [ -f "$_f" ] || return 0
  awk -F= '$1=="SALT_VERSION"{print $2; exit}' "$_f" 2>/dev/null
}

# Hash a path-like value for `private` mode. In-repo paths are normalized to
# repo-relative and emitted as `[redacted:<16-hex>]`; out-of-repo paths use
# the absolute path with the `[ext-redacted:<16-hex>]` prefix so they bucket
# separately from in-repo hashes (per DEV-72 spike).
# Hash input is `salt || normalized_path` — the org salt unlocks
# cross-developer clustering at the same org while preventing rainbow-table
# reversal (DEV-72 no-reverse-map rule).
_ds_hash_path() {
  local target="$1"
  local cwd="$2"
  local salt rel hash
  salt=$(_ds_load_salt "$cwd")
  rel=$(_ds_repo_relative "$target" "$cwd")
  if [ -n "$rel" ]; then
    hash=$(_ds_sha256 "${salt}${rel}")
    printf '[redacted:%s]' "${hash:0:16}"
  else
    hash=$(_ds_sha256 "${salt}${target}")
    printf '[ext-redacted:%s]' "${hash:0:16}"
  fi
}

# Hash a Grep/Glob pattern (regex/glob — not a path, so no repo-relative
# normalization). Always emits `[redacted:…]`.
_ds_hash_pattern() {
  local pattern="$1"
  local cwd="$2"
  local salt hash
  salt=$(_ds_load_salt "$cwd")
  hash=$(_ds_sha256 "${salt}${pattern}")
  printf '[redacted:%s]' "${hash:0:16}"
}

# Sanitize tool input for privacy — extract only safe metadata keys.
# In `private` mode (DEV-74), path-like fields are hashed at emit using
# org-salted, repo-relative normalization:
#   - Read|Write|Edit `file_path` → `[redacted:<16-hex>]` (in-repo) or
#     `[ext-redacted:<16-hex>]` (out-of-repo).
#   - Grep|Glob `path` → same as above; `pattern` → `[redacted:<16-hex>]`.
# Hash input is `salt || normalized_path` where the salt is per-org, fetched
# from the `session.start` response and cached locally. See the
# no-reverse-map rule on DEV-72.
# `standard`/`open` modes are unchanged. Bash/Skill/default arms unchanged.
_ds_sanitize_tool_input() {
  local tool_name="$1"
  local tool_input="$2"
  local cwd="${3:-${PWD:-}}"

  case "$tool_name" in
    Read|Write|Edit)
      if [ "$DEVSCOPE_PRIVACY" = "private" ]; then
        local _fp _hashed
        _fp=$(echo "$tool_input" | jq -r '.file_path // empty' 2>/dev/null)
        if [ -n "$_fp" ]; then
          _hashed=$(_ds_hash_path "$_fp" "$cwd")
          jq -nc --arg v "$_hashed" '{file_path: $v}'
        else
          echo '{"file_path":null}'
        fi
      else
        echo "$tool_input" | jq -c '{file_path: .file_path} // {}' 2>/dev/null || echo '{}'
      fi
      ;;
    Grep|Glob)
      if [ "$DEVSCOPE_PRIVACY" = "private" ]; then
        local _pat _path _vp _va
        _pat=$(echo "$tool_input" | jq -r '.pattern // empty' 2>/dev/null)
        _path=$(echo "$tool_input" | jq -r '.path // empty' 2>/dev/null)
        _vp=""
        _va=""
        [ -n "$_pat" ] && _vp=$(_ds_hash_pattern "$_pat" "$cwd")
        [ -n "$_path" ] && _va=$(_ds_hash_path "$_path" "$cwd")
        jq -nc --arg p "$_vp" --arg a "$_va" \
          '{pattern: (if $p == "" then null else $p end),
            path:    (if $a == "" then null else $a end)}'
      else
        echo "$tool_input" | jq -c '{pattern: .pattern, path: .path} // {}' 2>/dev/null || echo '{}'
      fi
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

# Sanitize tool result for standard privacy mode.
# Mirrors _ds_sanitize_tool_input: keeps safe metadata, redacts content.
_ds_sanitize_tool_result() {
  local tool_name="$1"
  local tool_result="$2"

  case "$tool_name" in
    Read|Grep|Glob)
      # File contents / search results — redact in standard mode
      echo '{"redacted": true}'
      ;;
    Bash)
      # Command output — redact in standard mode
      echo '{"redacted": true}'
      ;;
    Write|Edit)
      # Write/Edit results are typically short confirmations — safe to keep
      echo "$tool_result" | jq -R -s '(fromjson? // .) | tostring | .[:500]' 2>/dev/null || echo '{"redacted": true}'
      ;;
    *)
      echo '{"redacted": true}'
      ;;
  esac
}

# Extract a privacy-safe subcommand from raw tool input.
# Always uses the RAW tool_input (not sanitized) because the first word
# of a bash command and file extensions are not sensitive.
_ds_extract_subcommand() {
  local tool_name="$1"
  local raw_tool_input="$2"

  case "$tool_name" in
    Bash)
      # First word of command, strip path prefix, lowercase
      echo "$raw_tool_input" | jq -r '.command // "" | split(" ") | .[0] | split("/") | .[-1]' 2>/dev/null | tr '[:upper:]' '[:lower:]'
      ;;
    Read|Write|Edit)
      # File extension only (no path leaked)
      echo "$raw_tool_input" | jq -r '.file_path // "" | split(".") | last // ""' 2>/dev/null
      ;;
    Grep)
      echo "grep"
      ;;
    Glob)
      echo "glob"
      ;;
    Skill)
      echo "$raw_tool_input" | jq -r '.skill // ""' 2>/dev/null
      ;;
    Agent)
      echo "$raw_tool_input" | jq -r '.subagent_type // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]'
      ;;
    *)
      echo ""
      ;;
  esac
}
