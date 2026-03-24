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
- "What's the average session duration?"

### Step 2: Verify connection and send query

Source the DevScope helpers and check the server is reachable before querying:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

echo "=== CONFIG ==="
echo "URL: $DEVSCOPE_URL"
echo "API_KEY: ${DEVSCOPE_API_KEY:+configured}"

echo "=== HEALTH CHECK ==="
HEALTH=$(_ds_health_check)
HC_STATUS=$?
echo "HC_STATUS: $HC_STATUS"
echo "HEALTH: $HEALTH"
```

If the health check fails (`HC_STATUS` is non-zero or `HEALTH` is "UNREACHABLE"):
- Tell the user that the DevScope server at the displayed URL is not reachable.
- If the URL is `http://localhost:6767` (the default), suggest they may need to start the server or run `/devscope:setup` to configure the correct URL.
- If the URL is a custom value, suggest checking that the server is running and the URL is correct.
- **Do NOT proceed to the query. Stop here.**

If the health check succeeds, send the streaming AI query:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

CURL_ARGS=(-s -N -X POST "${DEVSCOPE_URL}/api/ai/chat" -H "Content-Type: application/json" -d "$(jq -n --arg q "$QUESTION" '{question: $q}')" --max-time 60)
CURL_CONFIG=""
if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
  CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
fi

SSE_OUTPUT=$(echo "$CURL_CONFIG" | curl --config - "${CURL_ARGS[@]}" 2>&1)
CURL_EXIT=$?

echo "CURL_EXIT: $CURL_EXIT"

if [ $CURL_EXIT -ne 0 ]; then
  echo "CURL_ERROR: $SSE_OUTPUT"
else
  # Check if the response is a JSON error (not an SSE stream)
  ERROR_MSG=$(echo "$SSE_OUTPUT" | head -1 | jq -r '.error // .message // empty' 2>/dev/null)
  if [ -n "$ERROR_MSG" ]; then
    echo "API_ERROR: $ERROR_MSG"
    echo "RAW: $(echo "$SSE_OUTPUT" | head -5)"
  else
    ANSWER=$(echo "$SSE_OUTPUT" | grep '^data: ' | grep -v '\[DONE\]' | sed 's/^data: //' | jq -rs '[.[] | select(.type == "text") | .content] | join("")')
    echo "$ANSWER"
  fi
fi
```

### Step 3: Present the answer

If the query succeeded and `ANSWER` has content, display the AI's response in a clear, readable format. Preserve any markdown formatting in the response.

Handle errors based on what was returned:

| Situation | What to tell the user |
|---|---|
| Health check failed | "Cannot reach DevScope server at {URL}. Is the server running? Run `/devscope:setup` to reconfigure." |
| `CURL_EXIT` is non-zero | "Connection to DevScope failed during the query. The server may have gone down." |
| `API_ERROR` mentions auth/unauthorized | "Authentication failed. Your API key may be invalid or expired. Run `/devscope:setup` to update it." |
| `API_ERROR` mentions unavailable/not configured | "AI features are not available on this DevScope server. The server admin may need to configure an AI provider (e.g., set `GEMINI_API_KEY`)." |
| `API_ERROR` mentions rate limit | "Rate limit reached. Please wait a moment and try again." |
| `ANSWER` is empty | "The server responded but returned no answer. This may indicate an AI configuration issue on the server side." |
