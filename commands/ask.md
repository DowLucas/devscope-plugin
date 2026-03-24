---
allowed-tools: Bash(curl:*), Bash(source:*), Bash(cat:*), Bash(jq:*), Bash(grep:*), Bash(sed:*), Bash(echo:*), AskUserQuestion
description: Ask an AI-powered question about your development data
---

## Your task

Help the user ask a natural language question about their team's development data using DevScope's AI query engine.

### Step 1: Get the question

Ask the user what they'd like to know using AskUserQuestion. Suggest example questions:
- "Which tools have the highest failure rate this week?"
- "What were the most active projects in the last 7 days?"
- "Show me session trends over the past month"
- "What anti-patterns have been detected recently?"

### Step 2: Load config and send query

Source the DevScope helpers to load config:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"
```

Then call the AI chat endpoint:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"
RESPONSE=$(_ds_api_post "/api/ai/chat" "$(jq -n --arg q "$QUESTION" '{question: $q}')")
echo "$RESPONSE"
```

Note: The `/api/ai/chat` endpoint returns a streaming SSE response. Use curl to read it:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

CURL_ARGS=(-s -N -X POST "${DEVSCOPE_URL}/api/ai/chat" -H "Content-Type: application/json" -d "$(jq -n --arg q "$QUESTION" '{question: $q}')" --max-time 60)
CURL_CONFIG=""
if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
  CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
fi

ANSWER=$(echo "$CURL_CONFIG" | curl --config - "${CURL_ARGS[@]}" 2>/dev/null | grep '^data: ' | grep -v '\[DONE\]' | sed 's/^data: //' | jq -rs '[.[] | select(.type == "text") | .content] | join("")')
echo "$ANSWER"
```

### Step 3: Present the answer

Display the AI's response to the user in a clear, readable format. If the response contains markdown, preserve the formatting.

If the API returns an error (e.g., 503 for AI unavailable, 429 for rate limit), explain the issue to the user.
