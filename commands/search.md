---
allowed-tools: Bash(curl:*), Bash(source:*), Bash(jq:*), Bash(echo:*), AskUserQuestion
description: Search your past Claude Code sessions (prompts and Claude's replies) by keyword and meaning
---

## Your task

Search the user's past Claude Code sessions on their DevScope server and show the best matching turns. Search covers the user's own sessions plus those of teammates who opted in to sharing; private sessions are never included. It combines exact keyword matching with semantic (meaning) search.

### Step 1: Get the search terms

If the user passed arguments (check the `ARGUMENTS` section at the bottom of this prompt), use them as the query directly — do NOT ask again. Pass them through unchanged: the server understands `"exact phrase"`, `OR` and `-exclude`.

Otherwise, ask the user what to search for using AskUserQuestion.

### Step 2: Verify connection and search

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

echo "=== HEALTH CHECK ==="
HEALTH=$(_ds_health_check)
HC_STATUS=$?
echo "HC_STATUS: $HC_STATUS"
echo "URL: $DEVSCOPE_URL"
```

If the health check fails (`HC_STATUS` is non-zero or `HEALTH` is "UNREACHABLE"), tell the user the DevScope server at that URL is not reachable, suggest `/devscope:setup`, and stop.

Otherwise run the search, substituting the query for `$QUERY`:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

CURL_CONFIG=""
if [ -n "${DEVSCOPE_API_KEY:-}" ]; then
  CURL_CONFIG="header = \"x-api-key: ${DEVSCOPE_API_KEY}\""
fi

RESULT=$(echo "$CURL_CONFIG" | curl --config - -s -G "${DEVSCOPE_URL}/api/similar/search" \
  -H "x-requested-with: devscope-cli" \
  --data-urlencode "q=$QUERY" --data-urlencode "limit=10" \
  -w '\nHTTP_STATUS:%{http_code}' --max-time 30)
CURL_EXIT=$?
STATUS=$(printf '%s' "$RESULT" | sed -n 's/^HTTP_STATUS://p')
BODY=$(printf '%s' "$RESULT" | sed '/^HTTP_STATUS:/d')
echo "CURL_EXIT: $CURL_EXIT"
echo "STATUS: $STATUS"

if [ "$CURL_EXIT" -eq 0 ] && [ "$STATUS" = "200" ]; then
  printf '%s' "$BODY" | jq -r --arg base "$DEVSCOPE_URL" '
    "SEMANTIC_AVAILABLE: \(.semanticAvailable)",
    "COUNT: \(.results | length)",
    (.results[] |
      "---",
      "WHEN: \(.promptAt)",
      "PROJECT: \(.projectName)",
      "SESSION: \(.sessionTitle // "Untitled session")",
      "MATCHED: \(.matchedBy | join(", "))",
      "PROMPT: \(.promptSnippet | gsub("\\s+"; " ") | .[0:300])",
      "REPLY: \((.responseSnippet // "") | gsub("\\s+"; " ") | .[0:300])",
      "LINK: \($base)/dashboard/sessions/\(.sessionId | @uri)?turn=\(.promptEventId | @uri)")'
else
  echo "BODY: $(printf '%s' "$BODY" | head -c 500)"
fi
```

### Step 3: Present the results

If `COUNT` is 0, say nothing matched and suggest fewer or different words.

Otherwise show each result as a compact entry, best first:

- **Session title** · project · relative date (from `WHEN`)
- The prompt excerpt, and the reply excerpt if present. Matched terms are wrapped in `«` `»`: render them in **bold** and drop the markers.
- The `LINK`, so the user can open the exact turn in the dashboard.

Keep it scannable; do not add commentary on each result. If `SEMANTIC_AVAILABLE` is `false`, add one line noting that only exact keyword matches were searched.

Handle errors:

| Situation | What to tell the user |
|---|---|
| `CURL_EXIT` is non-zero | "Connection to DevScope failed during the search." |
| `STATUS` 401 or 403 | "Authentication failed. Your API key may be invalid or expired. Run `/devscope:setup` to update it." |
| `STATUS` 404 | "This DevScope server does not support session search yet. It needs a newer server version." |
| `STATUS` 429 | "Rate limit reached. Please wait a moment and try again." |
| `STATUS` 400 | "The search query was not accepted. Try a shorter query." |
| Anything else | Show the status and `BODY`. |
