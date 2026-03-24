---
allowed-tools: Bash(curl:*), Bash(source:*), Bash(jq:*), AskUserQuestion
description: Generate an AI summary report of team development activity
---

## Your task

Generate an on-demand AI-powered summary report of team development activity using DevScope.

### Step 1: Ask report preferences

Ask the user what kind of report they want using AskUserQuestion:
- **Report type**: "Daily summary" or "Weekly summary"
- **Persona**: "Developer" (technical detail), "Manager" (team health overview), or "CTO" (strategic view)

### Step 2: Generate the report

Map the user's choice to the API parameters and call the report generation endpoint:

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

# report_type: "daily" or "weekly"
# persona: "manager", "cto", or omit for developer-level detail
BODY=$(jq -n --arg rt "$REPORT_TYPE" --arg p "$PERSONA" 'if $p == "" then {report_type: $rt} else {report_type: $rt, persona: $p} end')
RAW=$(_ds_api_post "/api/ai/reports/generate" "$BODY")
HTTP_STATUS=$(echo "$RAW" | tail -1)
RESPONSE=$(echo "$RAW" | sed '$d')
echo "$RESPONSE"
```

### Step 3: Present the report

Parse the response and branch on the HTTP status code:
- **200**: Parse the JSON response. Display the `markdown_content` field to the user. If the `status` field is `"failed"`, tell the user report generation encountered an error and they should try again. The response schema includes:
  - `title`: Report title
  - `markdown_content`: Full report in Markdown format
  - `report_type`: daily/weekly
  - `period_start` / `period_end`: Time range covered
  - `status`: "completed" or "failed"
- **503**: AI features aren't available on the server
- **429**: Rate limit or token budget has been exceeded
