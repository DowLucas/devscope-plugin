---
allowed-tools: Bash(curl:*), Bash(source:*), Bash(jq:*)
description: View the latest AI-generated insights about your team's development
---

## Your task

Fetch and display the latest AI-generated insights from DevScope. These are automatically generated analyses including anomaly detection, trends, recommendations, and coaching tips.

### Step 1: Fetch insights

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

RESPONSE=$(_ds_api_get "/api/ai/insights?limit=10")
echo "$RESPONSE"
```

### Step 2: Present the insights

Parse the JSON array response and present each insight clearly. Each insight has:
- `type`: anomaly, trend, comparison, recommendation, or coaching
- `severity`: info, warning, or critical
- `title`: Short summary
- `narrative`: Detailed explanation
- `created_at`: When it was generated
- `expires_at`: When it expires

Format them as a readable list, grouped by severity (critical first, then warning, then info). Use markdown formatting for readability.

If the response is empty, tell the user no insights have been generated yet. They may need to wait for the next scheduled insight generation cycle, or the server admin can trigger manual generation from the dashboard.

If the API returns an error, explain the issue (401 = not authenticated, 403 = no org, 503 = server unavailable).
