#!/usr/bin/env bash
# Tests for the subagent intent queue: tool-use.sh (PreToolUse of the Agent
# tool) queues description and model, agent-start.sh puts them on agent.start.
#
#   bash tests/agents/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/config"
unset DEVSCOPE_PRIVACY DEVSCOPE_NUDGE_MODE
# shellcheck disable=SC1091
. "$ROOT/tests/lib/stub.sh"
respond '{}'

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
pre() {  # session subagent_type description [model]
  jq -n --arg s "$1" --arg t "$2" --arg d "$3" --arg m "${4:-}" \
    '{session_id: $s, cwd: "/tmp", hook_event_name: "PreToolUse", tool_name: "Agent",
      tool_input: ({subagent_type: $t, description: $d, prompt: "do it"}
                   + (if $m != "" then {model: $m} else {} end))}' \
    | "$ROOT/scripts/tool-use.sh" >/dev/null
}
start() {  # session agent_type agent_id
  jq -n --arg s "$1" --arg t "$2" --arg a "$3" \
    '{session_id: $s, cwd: "/tmp", hook_event_name: "SubagentStart", agent_type: $t, agent_id: $a}' \
    | "$ROOT/scripts/agent-start.sh" >/dev/null
  last_at /api/events '.body.payload'
}
wait_hits() { for _ in $(seq 1 30); do [ "$(hits)" -ge "$1" ] && return; sleep 0.1; done; }

pre s1 Explore "Map the topology code" haiku
p=$(start s1 Explore a1)
[ "$(printf '%s' "$p" | jq -r .description)" = "Map the topology code" ] && ok "description reaches agent.start" || bad "description" "$p"
[ "$(printf '%s' "$p" | jq -r .model)" = "haiku" ] && ok "model reaches agent.start" || bad "model" "$p"

pre s2 Explore "first"; pre s2 Plan "the plan"; pre s2 Explore "second"
[ "$(start s2 Plan a2 | jq -r .description)" = "the plan" ] && ok "matches by agent type" || bad "type match" ""
[ "$(start s2 Explore a3 | jq -r .description)" = "first" ] && ok "same type: oldest first" || bad "fifo 1" ""
[ "$(start s2 Explore a4 | jq -r .description)" = "second" ] && ok "same type: then the next" || bad "fifo 2" ""
p=$(start s2 Explore a5)
[ "$(printf '%s' "$p" | jq -r '.description // "none"')" = "none" ] && [ "$(printf '%s' "$p" | jq -r .agentId)" = "a5" ] \
  && ok "empty queue: plain agent.start" || bad "empty" "$p"

pre s4 general-purpose "secret task" sonnet
p=$(start s4 general-purpose a7)
[ "$(printf '%s' "$p" | jq -r .description)" = "secret task" ] && ok "standard mode keeps description" || bad "standard" "$p"
DEVSCOPE_PRIVACY=private pre s5 general-purpose "secret task" sonnet
grep -q "secret task" "$HOME/.cache/devscope/intents/s5.jsonl" && bad "private queue" "description written to disk" || ok "private mode never stores the description"
p=$(start s5 general-purpose a8)
[ "$(printf '%s' "$p" | jq -r '.description // "none"')" = "none" ] && [ "$(printf '%s' "$p" | jq -r .model)" = "sonnet" ] \
  && ok "private mode: model only" || bad "private" "$p"

pre s6 Explore "old one"
jq -c '.ts = (.ts - 3600)' "$HOME/.cache/devscope/intents/s6.jsonl" > "$TMP/x" && mv "$TMP/x" "$HOME/.cache/devscope/intents/s6.jsonl"
[ "$(start s6 Explore a9 | jq -r '.description // "none"')" = "none" ] && ok "intents older than 10 min are dropped" || bad "stale" ""
[ ! -f "$HOME/.cache/devscope/intents/s6.jsonl" ] && ok "empty queue file is removed" || bad "cleanup" "file left"

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
