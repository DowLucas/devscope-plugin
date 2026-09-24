#!/usr/bin/env bash
# Tests for scripts/skill-hint.sh (PostToolUse next-step hint). No backend needed.
#
#   bash tests/hints/run.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/scripts/skill-hint.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP" XDG_CONFIG_HOME="$TMP/config"
unset DEVSCOPE_HINTS DEVSCOPE_HINT_AFTER_PR
pass=0; fail=0

payload() {  # command stdout [interrupted] [session]
  jq -n --arg c "$1" --arg o "$2" --argjson i "${3:-false}" --arg s "${4:-s1}" \
    '{session_id: $s, hook_event_name: "PostToolUse", tool_name: "Bash",
      tool_input: {command: $c}, tool_response: {stdout: $o, stderr: "", interrupted: $i}}'
}
check() {  # name expected-substring-or-EMPTY actual
  if { [ "$2" = "EMPTY" ] && [ -z "$3" ]; } || { [ "$2" != "EMPTY" ] && printf '%s' "$3" | grep -Fq "$2"; }; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: expected '$2', got '$3'"
  fi
}
PR="https://github.com/acme/app/pull/42"

out=$(payload "gh pr create --fill" "$PR" | "$HOOK")
check "hint after a created PR" "/code-review" "$out"
check "output is valid JSON with systemMessage" "DevScope: PR opened" "$(printf '%s' "$out" | jq -r .systemMessage)"
check "same PR again in the session is silent" EMPTY "$(payload "gh pr create --fill" "$PR" | "$HOOK")"
check "same PR in another session hints" "/code-review" "$(payload "gh pr create --fill" "$PR" false s2 | "$HOOK")"
check "non-PR command is silent" EMPTY "$(payload "git push" "done" | "$HOOK")"
check "gh pr view is silent" EMPTY "$(payload "gh pr view 42" "$PR" | "$HOOK")"
check "no PR URL in output is silent" EMPTY "$(payload "gh pr create --fill" "a pull request already exists" false s3 | "$HOOK")"
check "interrupted command is silent" EMPTY "$(payload "gh pr create" "https://github.com/acme/app/pull/7" true s4 | "$HOOK")"
check "chained command still matches" "/code-review" "$(payload "git push -u origin x && gh  pr  create --title t" "https://github.com/acme/app/pull/8" false s5 | "$HOOK")"
check "hints off via env" EMPTY "$(payload "gh pr create" "https://github.com/acme/app/pull/9" false s6 | DEVSCOPE_HINTS=off "$HOOK")"
mkdir -p "$XDG_CONFIG_HOME/devscope"
printf 'DEVSCOPE_HINTS=off\n' > "$XDG_CONFIG_HOME/devscope/config"
check "hints off via config file" EMPTY "$(payload "gh pr create" "https://github.com/acme/app/pull/10" false s7 | "$HOOK")"
check "env beats config file" "/code-review" "$(payload "gh pr create" "https://github.com/acme/app/pull/11" false s8 | DEVSCOPE_HINTS=on "$HOOK")"
rm "$XDG_CONFIG_HOME/devscope/config"
check "custom next command" "/review-pr" "$(payload "gh pr create" "https://github.com/acme/app/pull/12" false s9 | DEVSCOPE_HINT_AFTER_PR=/review-pr "$HOOK")"
check "unsafe custom command falls back" "/code-review?" "$(payload "gh pr create" "https://github.com/acme/app/pull/13" false s10 | DEVSCOPE_HINT_AFTER_PR='/x; rm -rf ~' "$HOOK")"
out=$(payload "gh pr create" "https://github.com/acme/app/pull/14" false s11 | "$HOOK")
check "default mode does not tell Claude" "null" "$(printf '%s' "$out" | jq -c '.hookSpecificOutput')"
out=$(payload "gh pr create" "https://github.com/acme/app/pull/15" false s12 | DEVSCOPE_HINTS=claude "$HOOK")
check "claude mode still shows the user" "/code-review" "$(printf '%s' "$out" | jq -r '.systemMessage')"
check "claude mode tells Claude, with the PR" "https://github.com/acme/app/pull/15" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
check "claude mode asks Claude to offer, not run" "do not run it unless the user agrees" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext')"
check "claude mode sets the hook event name" "PostToolUse" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')"
check "user mode is user-only" "null" "$(payload "gh pr create" "https://github.com/acme/app/pull/16" false s13 | DEVSCOPE_HINTS=user "$HOOK" | jq -c '.hookSpecificOutput')"
check "unknown mode falls back to user-only" "null" "$(payload "gh pr create" "https://github.com/acme/app/pull/17" false s14 | DEVSCOPE_HINTS=loud "$HOOK" | jq -c '.hookSpecificOutput')"
check "garbage stdin is silent" EMPTY "$(printf 'not json' | "$HOOK")"
check "empty stdin is silent" EMPTY "$(printf '' | "$HOOK")"

# --- Skill chains: next-skill hints from the cached per-user chains ---
skill() {  # name [session]
  jq -n --arg k "$1" --arg s "${2:-k1}" \
    '{session_id: $s, hook_event_name: "PostToolUse", tool_name: "Skill", tool_input: {skill: $k}, tool_response: {}}'
}
CHAINS="$HOME/.cache/devscope/skill-chains.json"
check "no chain cache is silent" EMPTY "$(skill ship | "$HOOK")"
mkdir -p "$(dirname "$CHAINS")"
printf '%s' '{"chains":[{"from":"ship","to":"code-review","count":9,"share":0.62},{"from":"ship","to":"qa","count":3,"share":0.2},
  {"from":"evil","to":"x\"; rm -rf ~","count":9,"share":0.9},{"from":"odd","to":"qa","count":9,"share":"lots"}]}' > "$CHAINS"
out=$(skill ship | "$HOOK")
check "skill hint names the usual next skill" "after /ship you usually run /code-review next" "$(printf '%s' "$out" | jq -r .systemMessage)"
check "skill hint is user-only by default" "null" "$(printf '%s' "$out" | jq -c .hookSpecificOutput)"
check "same skill again in the session is silent" EMPTY "$(skill ship | "$HOOK")"
check "slash and case are normalised" "/code-review" "$(skill /SHIP k2 | "$HOOK")"
out=$(skill ship k3 | DEVSCOPE_HINTS=claude "$HOOK")
check "claude mode gives the share" "(62% of the time)" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)"
check "claude mode asks Claude to offer, not run" "do not run it unless the user agrees" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)"
check "skill without a chain is silent" EMPTY "$(skill brainstorm k4 | "$HOOK")"
check "unsafe skill name from the server is dropped" EMPTY "$(skill evil k5 | "$HOOK")"
check "malformed share is dropped" EMPTY "$(skill odd k6 | "$HOOK")"
check "skill hints off via env" EMPTY "$(skill ship k7 | DEVSCOPE_HINTS=off "$HOOK")"
printf 'garbage' > "$CHAINS"
check "corrupt chain cache is silent" EMPTY "$(skill ship k8 | "$HOOK")"

# Runs synchronously on every Bash call: the common (non-PR) path must be fast.
start=$(date +%s%N); for _ in 1 2 3 4 5 6 7 8 9 10; do payload "ls -la" "x" | "$HOOK" >/dev/null; done; end=$(date +%s%N)
avg_ms=$(( (end - start) / 10000000 ))
if [ "$avg_ms" -lt 150 ]; then pass=$((pass + 1)); echo "ok   non-PR path averages ${avg_ms}ms (< 150ms)"; else fail=$((fail + 1)); echo "FAIL non-PR path averages ${avg_ms}ms"; fi

# --- session-start.sh caches the chains from the API (stub server) ---
# shellcheck disable=SC1091
. "$ROOT/tests/lib/stub.sh"
start_session() { jq -n '{session_id: "ss-1", source: "startup", cwd: "/nonexistent"}' | "$ROOT/scripts/session-start.sh" >/dev/null 2>&1 || true; }
rm -f "$CHAINS"
respond '{"chains":[{"from":"ship","to":"qa","count":4,"share":0.5}]}'
start_session
check "session start caches the chains" "qa" "$(jq -r '.chains[0].to' "$CHAINS" 2>/dev/null)"
respond '{"chains":[{"from":"ship","to":"retro","count":4,"share":0.5}]}'
start_session
check "a fresh cache is not refetched" "qa" "$(jq -r '.chains[0].to' "$CHAINS" 2>/dev/null)"
touch -d '7 hours ago' "$CHAINS"; respond "<html>oops</html>"
start_session
check "a bad response keeps the old cache" "qa" "$(jq -r '.chains[0].to' "$CHAINS" 2>/dev/null)"
rm -f "$CHAINS"; respond '{"chains":[]}'
DEVSCOPE_PRIVACY=private start_session
check "private mode does not fetch chains" "missing" "$([ -f "$CHAINS" ] && echo present || echo missing)"

echo "---"; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
