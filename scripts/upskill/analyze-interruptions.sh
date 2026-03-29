#!/usr/bin/env bash
# Analyze user interruption patterns from Claude Code sessions
# Interruptions reveal approach gaps, missing knowledge, and friction hotspots
# Usage: ./analyze-interruptions.sh [--days N] [--top N] [--verbose] [--sessions-dir PATH]

set -e

DAYS=14
TOP=20
VERBOSE=""
PROJECT_SESSIONS=""
MAX_FILE_SIZE=52428800  # 50MB guard for jq -s

# Cross-platform file size
_file_size() {
  stat -c '%s' "$1" 2>/dev/null || stat -f%z "$1" 2>/dev/null || echo "0"
}

# Auto-detect project sessions directory from CWD
_detect_project_sessions() {
  local cwd="${1:-$(pwd)}"
  local encoded
  encoded=$(echo "$cwd" | sed 's|^/|-|; s|/|-|g')
  echo "$HOME/.claude/projects/${encoded}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --top)  TOP="$2"; shift 2 ;;
        --verbose) VERBOSE="1"; shift ;;
        --sessions-dir) PROJECT_SESSIONS="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--days N] [--top N] [--verbose] [--sessions-dir PATH]"; exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

PROJECT_SESSIONS="${PROJECT_SESSIONS:-$(_detect_project_sessions)}"

INTERRUPTS_FILE=$(mktemp)
CATEGORIES_FILE=$(mktemp)
SESSION_COUNTS_FILE=$(mktemp)

cleanup() {
    rm -f "$INTERRUPTS_FILE" "$CATEGORIES_FILE" "$SESSION_COUNTS_FILE" 2>/dev/null
}
trap cleanup EXIT

echo "INTERRUPTION ANALYSIS REPORT"
echo "==================================================="
echo "  Period: last $DAYS days"
echo "  Source: $PROJECT_SESSIONS"
echo ""

if [[ ! -d "$PROJECT_SESSIONS" ]]; then
    echo "  ERROR: Sessions directory not found: $PROJECT_SESSIONS"
    exit 1
fi

SESSION_COUNT=0
TOTAL_INTERRUPTS=0
SKIPPED_LARGE=0

for session in $(find "$PROJECT_SESSIONS" -name "*.jsonl" -mtime -"$DAYS" 2>/dev/null | grep -v '/agent-a' | sort -r); do
    session_name=$(basename "$session")
    file_size=$(_file_size "$session")

    # Skip files larger than 50MB to avoid jq -s memory issues
    if [[ "$file_size" -gt "$MAX_FILE_SIZE" ]]; then
        SKIPPED_LARGE=$((SKIPPED_LARGE + 1))
        continue
    fi

    # Quick check: does this session have any interruptions?
    if ! grep -q '\[Request interrupted by user' "$session" 2>/dev/null; then
        continue
    fi

    SESSION_COUNT=$((SESSION_COUNT + 1))

    # Extract interruption events and their follow-up messages using jq -s
    jq -s --arg sess "$session_name" '
      . as $msgs |

      # Find indices of user messages that contain interruption markers
      [range(length) | select(
        $msgs[.].type == "user" and
        (($msgs[.].message.content | tostring) | test("\\[Request interrupted by user"))
      )] |

      # For each interruption, extract context
      . as $interrupt_indices |
      [.[] | . as $i |
        # Find the preceding assistant message
        ([$msgs[range(0; $i)] | select(.type == "assistant")] | last // null) as $prev_assistant |

        # Extract what tool was being used
        ($prev_assistant | if . != null then
          (if (.message.content | type) == "array" then
            [.message.content[] | select(type == "object" and .type == "tool_use") | .name] | last // "unknown"
          else "text" end)
        else "unknown" end) as $interrupted_tool |

        # Find the next non-interrupt user message
        ([$msgs[range($i+1; ($msgs | length))] |
          select(.type == "user") |
          select((.message.content | tostring) | test("\\[Request interrupted by user") | not)
        ] | .[0] // null) as $followup |

        # Extract follow-up text
        ($followup | if . != null then
          (if (.message.content | type) == "string" then .message.content
          elif (.message.content | type) == "array" then
            [.message.content[] |
              if type == "string" then .
              elif type == "object" and .type == "text" then .text
              else empty end
            ] | join("\n")
          else "" end)
        else "" end) as $followup_text |

        # Clean follow-up text
        ($followup_text |
          gsub("<system-reminder>[^<]*</system-reminder>"; "") |
          gsub("<local-command-caveat>[^<]*</local-command-caveat>"; "") |
          gsub("\\n+"; " ") |
          ltrimstr(" ") | rtrimstr(" ") |
          .[:300]
        ) as $clean_followup |

        {
          session: $sess,
          interrupted_tool: $interrupted_tool,
          followup: $clean_followup
        }
      ] |

      .[] | "\(.session)|\(.interrupted_tool)|\(.followup)"
    ' "$session" 2>/dev/null >> "$INTERRUPTS_FILE" || true

    # Count interruptions in this session
    session_interrupt_count=$(grep -c '\[Request interrupted by user' "$session" 2>/dev/null | tr -d '[:space:]' || true)
    session_interrupt_count=${session_interrupt_count:-0}
    TOTAL_INTERRUPTS=$((TOTAL_INTERRUPTS + session_interrupt_count))
    echo "$session_interrupt_count|$session_name" >> "$SESSION_COUNTS_FILE"
done

echo "  Sessions with interruptions: $SESSION_COUNT"
echo "  Total interruption events: $TOTAL_INTERRUPTS"
[[ "$SKIPPED_LARGE" -gt 0 ]] && echo "  Skipped (>50MB): $SKIPPED_LARGE"
echo ""

if [[ ! -s "$INTERRUPTS_FILE" ]]; then
    echo "  No interruptions found in the analysis period."
    echo ""
    echo "==================================================="
    exit 0
fi

# Categorize follow-up messages
echo "INTERRUPTION CATEGORIES"
echo "---------------------------------------------------"

awk -F'|' '
{
    sess = $1
    tool = $2
    followup = ""
    for (i = 3; i <= NF; i++) {
        if (i > 3) followup = followup "|"
        followup = followup $i
    }

    lower = tolower(followup)
    len = length(followup)
    category = "OTHER"

    if (lower ~ /instead/ || lower ~ /wrong/ || lower ~ /should be/ || lower ~ /correct/ || lower ~ /use the/ || lower ~ /dont use/ || lower ~ /don.?t use/ || lower ~ /not that/ || lower ~ /^no[, ]/ || lower ~ /^stop/) {
        category = "COURSE_CORRECTION"
    }
    else if (lower ~ /\?$/ || lower ~ /^do we/ || lower ~ /^can you/ || lower ~ /^what / || lower ~ /^why / || lower ~ /^how / || lower ~ /^where / || lower ~ /^which /) {
        category = "QUESTION"
    }
    else if (lower ~ /^continue/ || lower ~ /^try again/ || lower ~ /^go ahead/ || lower ~ /^ok / || lower ~ /^yes/ || (len > 0 && len < 15)) {
        category = "IMPATIENCE"
    }
    else if (lower ~ /^now do/ || lower ~ /^switch to/ || lower ~ /^forget/ || lower ~ /^move on/ || lower ~ /^lets do/ || lower ~ /^let.?s do/ || lower ~ /^actually,? (can|lets|let.?s|do|make)/) {
        category = "ABANDONMENT"
    }

    if (len == 0) {
        category = "NO_FOLLOWUP"
    }

    print category "|" sess "|" tool "|" followup
}' "$INTERRUPTS_FILE" > "$CATEGORIES_FILE"

# Count by category
COURSE_COUNT=$(grep -c "^COURSE_CORRECTION|" "$CATEGORIES_FILE" 2>/dev/null || echo "0")
QUESTION_COUNT=$(grep -c "^QUESTION|" "$CATEGORIES_FILE" 2>/dev/null || echo "0")
IMPATIENCE_COUNT=$(grep -c "^IMPATIENCE|" "$CATEGORIES_FILE" 2>/dev/null || echo "0")
ABANDONMENT_COUNT=$(grep -c "^ABANDONMENT|" "$CATEGORIES_FILE" 2>/dev/null || echo "0")
NO_FOLLOWUP_COUNT=$(grep -c "^NO_FOLLOWUP|" "$CATEGORIES_FILE" 2>/dev/null || echo "0")
OTHER_COUNT=$(grep -c "^OTHER|" "$CATEGORIES_FILE" 2>/dev/null || echo "0")

echo "  COURSE_CORRECTION: $COURSE_COUNT  (user redirected approach)"
echo "  QUESTION:          $QUESTION_COUNT  (user asked clarification)"
echo "  IMPATIENCE:        $IMPATIENCE_COUNT  (user wanted faster progress)"
echo "  ABANDONMENT:       $ABANDONMENT_COUNT  (user switched topics)"
echo "  NO_FOLLOWUP:       $NO_FOLLOWUP_COUNT  (session ended after interrupt)"
echo "  OTHER:             $OTHER_COUNT  (unclassified)"
echo ""

# Course corrections (highest signal)
echo "COURSE CORRECTIONS (highest signal)"
echo "---------------------------------------------------"

if [[ "$COURSE_COUNT" -gt 0 ]]; then
    echo "  These reveal where Claude took the wrong approach:"
    echo ""
    grep "^COURSE_CORRECTION|" "$CATEGORIES_FILE" | head -"$TOP" | while IFS='|' read -r _ sess tool followup; do
        echo "  Session: $sess"
        echo "    Interrupted: $tool"
        echo "    Follow-up: \"$(echo "$followup" | cut -c1-150)\""
        echo ""
    done
else
    echo "  No course corrections found."
fi
echo ""

# Questions after interruption
echo "QUESTIONS AFTER INTERRUPTION"
echo "---------------------------------------------------"

if [[ "$QUESTION_COUNT" -gt 0 ]]; then
    echo "  User needed clarification before Claude could continue:"
    echo ""
    grep "^QUESTION|" "$CATEGORIES_FILE" | head -"$TOP" | while IFS='|' read -r _ sess tool followup; do
        echo "  Session: $sess"
        echo "    Interrupted: $tool"
        echo "    Question: \"$(echo "$followup" | cut -c1-150)\""
        echo ""
    done
else
    echo "  No post-interruption questions found."
fi
echo ""

# Verbose: abandonment patterns
if [[ -n "$VERBOSE" ]]; then
    echo "ABANDONMENT PATTERNS"
    echo "---------------------------------------------------"
    if [[ "$ABANDONMENT_COUNT" -gt 0 ]]; then
        grep "^ABANDONMENT|" "$CATEGORIES_FILE" | head -"$TOP" | while IFS='|' read -r _ sess tool followup; do
            echo "  Session: $sess"
            echo "    Was doing: $tool"
            echo "    Switched to: \"$(echo "$followup" | cut -c1-150)\""
            echo ""
        done
    else
        echo "  No abandonment patterns found."
    fi
    echo ""
fi

# High-interrupt sessions
echo "HIGH-INTERRUPT SESSIONS (friction hotspots)"
echo "---------------------------------------------------"

if [[ -s "$SESSION_COUNTS_FILE" ]]; then
    sort -t'|' -k1 -rn "$SESSION_COUNTS_FILE" | head -"$TOP" | while IFS='|' read -r count sess; do
        [[ "$count" -lt 2 ]] && continue
        echo "  ($count interrupts) $sess"
    done
else
    echo "  No high-interrupt sessions found."
fi
echo ""

# Interrupted tools
echo "INTERRUPTED TOOLS (what was being stopped)"
echo "---------------------------------------------------"

awk -F'|' '{print $3}' "$CATEGORIES_FILE" | sort | uniq -c | sort -rn | while read count tool; do
    [[ -z "$tool" ]] && continue
    echo "  ($count) $tool"
done
echo ""

# Actionable improvements
echo "ACTIONABLE IMPROVEMENTS"
echo "---------------------------------------------------"

if [[ "$COURSE_COUNT" -gt 0 ]]; then
    grep "^COURSE_CORRECTION|" "$CATEGORIES_FILE" | head -5 | while IFS='|' read -r _ sess tool followup; do
        echo "  [INTERRUPT-FIX] From $tool interruption: \"$(echo "$followup" | cut -c1-100)\""
    done
fi

if [[ "$QUESTION_COUNT" -gt 0 ]]; then
    grep "^QUESTION|" "$CATEGORIES_FILE" | head -3 | while IFS='|' read -r _ sess tool followup; do
        echo "  [INTERRUPT-GAP] Missing knowledge led to: \"$(echo "$followup" | cut -c1-100)\""
    done
fi

echo ""
echo "==================================================="
echo "  Run with --verbose for abandonment patterns"
echo "  Adjust window with --days N (default: 14)"
echo "==================================================="
