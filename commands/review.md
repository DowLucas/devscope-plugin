---
allowed-tools: Bash(curl:*), Bash(source:*), Bash(cat:*), Bash(grep:*), Bash(jq:*)
description: Get AI feedback on your current Claude Code session
---

## Your task

Generate AI-powered feedback for the user's current Claude Code session. This provides mid-session coaching including anti-pattern detection, tool sequence analysis, and improvement suggestions.

### Step 1: Get the current session ID

The session ID is stored in the DevScope cache:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

CWD="$(pwd)"
PROJECT_HASH=$(_ds_project_hash "$CWD")
STATE_FILE="${HOME}/.cache/devscope/${PROJECT_HASH}.session"

if [ -f "$STATE_FILE" ]; then
  SESSION_ID=$(cat "$STATE_FILE")
  echo "Session ID: $SESSION_ID"
else
  echo "NO_SESSION"
fi
```

If no session is found, tell the user that DevScope hasn't tracked a session yet for this project directory. They may need to start a new session or check their DevScope setup with `/devscope:setup`.

### Step 2: Request session feedback

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

RESPONSE=$(_ds_api_post "/api/ai/session-feedback" "$(jq -n --arg sid "$SESSION_ID" '{session_id: $sid}')")
echo "$RESPONSE"
```

### Step 3: Present the feedback

Parse the response and present the AI feedback in a structured format:
- Show the report markdown content (from the `markdown_content` or `content` field)
- If the API returns a 404, the session hasn't been synced to the server yet
- If the API returns a 403, the session is in private mode
- If the API returns a 503, AI features aren't available on the server

Tell the user this is based on the events tracked so far in their session, and they can run this command again later for updated feedback.
