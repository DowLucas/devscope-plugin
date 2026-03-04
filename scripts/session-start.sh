#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/_helpers.sh"
INPUT=$(cat)

START_TYPE=$(echo "$INPUT" | jq -r '.source // "startup"')
PERM_MODE=$(echo "$INPUT" | jq -r '.permission_mode // "default"')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
CC_SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
MODEL=$(echo "$INPUT" | jq -r '.model // ""')

# Git metadata (local operations, fast)
GIT_BRANCH=""
GIT_COMMIT=""
GIT_REMOTE=""
if [ -n "$CWD" ]; then
  GIT_BRANCH=$(git -C "$CWD" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  GIT_COMMIT=$(git -C "$CWD" rev-parse HEAD 2>/dev/null || echo "")
  GIT_REMOTE=$(git -C "$CWD" remote get-url origin 2>/dev/null || echo "")
  # Strip embedded credentials (user[:pass]@) from remote URL
  GIT_REMOTE=$(echo "$GIT_REMOTE" | sed -E 's,://[^@/]+@,://,')
fi
# Redact remote URL in privacy mode — may leak org/repo info
[ "$DEVSCOPE_PRIVACY" = "private" ] && GIT_REMOTE=""

# --- Session continuity state file ---
GC_CACHE_DIR="${HOME}/.cache/devscope"
mkdir -p -m 0700 "$GC_CACHE_DIR"
CONTINUED=false

if [ -n "$CWD" ] && [ -n "$CC_SESSION_ID" ]; then
  DEV_EMAIL=$(git -C "$CWD" config user.email 2>/dev/null || echo "${USER}@local")
  # Include PPID so concurrent sessions in the same project get separate state files.
  # PPID = Claude Code process PID, consistent across context clears but unique per instance.
  PROJECT_HASH=$(_ds_sha256 "${DEV_EMAIL}:${CWD}:${PPID}")
  STATE_FILE="${GC_CACHE_DIR}/${PROJECT_HASH}.session"

  if [ "$START_TYPE" = "startup" ]; then
    # New logical session — write CC session_id to state file
    echo "$CC_SESSION_ID" > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    # Clean stale tracking files from prior crashed sessions
    rm -f "${GC_CACHE_DIR}/${PROJECT_HASH}.files"
    rm -f "${GC_CACHE_DIR}/${PROJECT_HASH}.agents"
  else
    # clear/resume/compact — preserve existing DevScope session
    if [ -f "$STATE_FILE" ]; then
      CONTINUED=true
    else
      # No state file yet (edge case) — treat as new session
      echo "$CC_SESSION_ID" > "$STATE_FILE"
      chmod 600 "$STATE_FILE"
    fi
  fi
fi

PAYLOAD=$(jq -n \
  --arg st "$START_TYPE" \
  --arg pm "$PERM_MODE" \
  --argjson cont "$CONTINUED" \
  --arg ccid "$CC_SESSION_ID" \
  --arg priv "$DEVSCOPE_PRIVACY" \
  --arg model "$MODEL" \
  --arg branch "$GIT_BRANCH" \
  --arg commit "$GIT_COMMIT" \
  --arg remote "$GIT_REMOTE" \
  '{startType: $st, permissionMode: $pm, continued: $cont, claudeSessionId: $ccid, privacyMode: $priv}
   | if $model != "" then . + {model: $model} else . end
   | if $branch != "" then . + {gitBranch: $branch} else . end
   | if $commit != "" then . + {gitCommit: $commit} else . end
   | if $remote != "" then . + {gitRemoteUrl: $remote} else . end')

echo "$INPUT" | "$SCRIPT_DIR/send-event.sh" "session.start" "$PAYLOAD"
