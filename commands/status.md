---
allowed-tools: Bash(curl:*), Bash(source:*), Bash(cat:*), Bash(jq:*)
description: Check DevScope connection status and quick team activity overview
---

## Your task

Show a quick DevScope status overview including connection health, current session info, and recent team activity. This is a lightweight check that doesn't use AI.

### Step 1: Check connection and gather data

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

echo "=== CONFIG ==="
echo "URL: $DEVSCOPE_URL"
echo "API Key: ${DEVSCOPE_API_KEY:+configured}${DEVSCOPE_API_KEY:-not set}"
echo "Privacy: $DEVSCOPE_PRIVACY"

echo "=== HEALTH ==="
HEALTH=$(curl -sf --max-time 5 "${DEVSCOPE_URL}/api/health" 2>/dev/null)
echo "$HEALTH"

echo "=== SESSION ==="
CWD="$(pwd)"
PROJECT_HASH=$(_ds_project_hash "$CWD")
STATE_FILE="${HOME}/.cache/devscope/${PROJECT_HASH}.session"
if [ -f "$STATE_FILE" ]; then
  echo "Session ID: $(cat "$STATE_FILE")"
else
  echo "No active session tracked"
fi

echo "=== TEAM ACTIVITY ==="
ACTIVITY=$(_ds_api_get "/api/insights/team-activity?days=7")
echo "$ACTIVITY"
```

### Step 2: Present the status

Format the information as a clean status dashboard:

1. **Connection**: Show server URL, whether the API key is configured, and health check result (status + connected WebSocket clients)
2. **Current Session**: Show the tracked session ID for this project directory, or note if none exists
3. **Team Activity (7 days)**: Show key metrics from the team activity response:
   - Total sessions and events
   - Active developers count
   - Top tools used
   - Any notable trends

If the health check fails, the server may be down or the URL may be wrong. Suggest running `/devscope:setup` to reconfigure.

If the team activity endpoint returns 401/403, the API key may not have access to read data (it may only be configured for event ingestion on older setups). Mention this to the user.
