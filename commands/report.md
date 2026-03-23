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
BODY=$(jq -n --arg rt "$REPORT_TYPE" --arg p "$PERSONA" '{report_type: $rt, persona: $p}')
RESPONSE=$(_ds_api_post "/api/ai/reports/generate" "$BODY")
echo "$RESPONSE"
```

### Step 3: Present the report

The response contains a generated report with:
- `title`: Report title
- `markdown_content`: Full report in markdown format
- `report_type`: daily/weekly
- `period_start` / `period_end`: Time range covered
- `status`: "completed" or "failed"

Display the `markdown_content` to the user. If the status is "failed", tell the user the report generation encountered an error and they should try again.

If the API returns 503, AI features aren't available on the server. If 429, the rate limit or token budget has been exceeded.
