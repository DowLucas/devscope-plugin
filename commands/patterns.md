---
allowed-tools: Bash(curl:*), Bash(source:*), Bash(jq:*)
description: View discovered effective patterns and detected anti-patterns
---

## Your task

Fetch and display the team's discovered tool usage patterns (effective workflows) and detected anti-patterns (problematic behaviors) from DevScope.

### Step 1: Fetch patterns and anti-patterns

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"

PATTERNS=$(_ds_api_get "/api/patterns?limit=10")
ANTI_PATTERNS=$(_ds_api_get "/api/patterns/anti?limit=10")

echo "=== PATTERNS ==="
echo "$PATTERNS"
echo "=== ANTI-PATTERNS ==="
echo "$ANTI_PATTERNS"
```

### Step 2: Present the results

**Effective Patterns** — show each pattern with:
- `name`: Pattern name
- `tool_sequence`: The sequence of tools used
- `avg_success_rate`: How often it succeeds
- `occurrence_count`: How many times it's been seen
- `effectiveness`: effective, neutral, or ineffective
- `description`: What the pattern does

**Anti-Patterns** — show each with:
- `name`: Anti-pattern name
- `detection_rule`: The rule that triggered it (retry_loop, failure_cascade, etc.)
- `severity`: info, warning, or critical
- `suggestion`: How to avoid this anti-pattern
- `occurrence_count`: How often it's been detected

Format as two clear sections. Highlight any critical-severity anti-patterns. If either list is empty, mention that pattern analysis may still be running (it runs hourly).

If the API returns an error, explain the issue.
