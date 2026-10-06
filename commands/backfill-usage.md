---
allowed-tools: Bash(python3:*), Bash(source:*), Bash(echo:*), Bash(ls:*)
description: Upload exact token usage for past sessions from the Claude Code transcripts still on this machine
---

## Your task

Correct the token usage and API-equivalent cost of the user's past sessions on their DevScope server, using the Claude Code transcripts still on this machine.

Background, for explaining results: plugins before 0.23.0 recorded only the last API call of each session, so stored usage was far too low (typically ~40x). The server replaces those numbers with an estimate; this command replaces the estimate with exact totals wherever a transcript still exists. Claude Code deletes transcripts after `cleanupPeriodDays` (30 days by default), so older sessions keep the estimate. Only token counts and model ids are uploaded, never transcript content, and the server only updates sessions that belong to the user.

### Step 1: Check the connection

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"
echo "URL: $DEVSCOPE_URL"
echo "API_KEY: ${DEVSCOPE_API_KEY:+configured}"
HEALTH=$(_ds_health_check); echo "HC_STATUS: $?"; echo "HEALTH: $HEALTH"
PROJECTS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
echo "PROJECTS: $PROJECTS"
ls "$PROJECTS"/*/*.jsonl 2>/dev/null | wc -l
```

If the health check fails, tell the user the server at that URL is unreachable, suggest `/devscope:setup`, and stop. If no transcripts were found, say so and stop.

### Step 2: Upload

```bash
source "${CLAUDE_PLUGIN_ROOT}/scripts/_helpers.sh"
export DEVSCOPE_URL DEVSCOPE_API_KEY
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/token_usage.py" upload "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects"
```

The output is one JSON line: `transcripts` found, `withUsage` (transcripts with any API calls), `applied` (sessions updated) and `skipped` (transcripts with no matching session of the user's on the server, e.g. sessions recorded before DevScope was installed or on another account).

### Step 3: Report

Summarize in two or three sentences: how many sessions now have exact usage, and that older sessions keep the server's estimate because their transcripts are gone. If `skipped` is large, explain it is expected for sessions DevScope never recorded.

If the output has an `error`:

| Error | What to tell the user |
|---|---|
| `HTTP 401` / `HTTP 403` | "Authentication failed. Run `/devscope:setup` to update your API key." |
| `HTTP 404` | "This DevScope server is too old for usage backfill; it needs the version with token accounting v2." |
| `HTTP 429` | "Rate limited. Wait a minute and run the command again; it is safe to re-run." |
| anything else | Show the error. Re-running is safe: uploads are idempotent. |

To keep more history recoverable in the future, the user can raise `cleanupPeriodDays` in `~/.claude/settings.json`.
