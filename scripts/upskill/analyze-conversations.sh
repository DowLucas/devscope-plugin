#!/usr/bin/env bash
# Analyze user-assistant conversation patterns from Claude Code sessions
# Detects corrections, knowledge gaps, repeated instructions, and workway patterns
# Usage: ./analyze-conversations.sh [--days N] [--top N] [--verbose] [--sessions-dir PATH]

set -e

DAYS=14
TOP=20
VERBOSE=""
PROJECT_SESSIONS=""

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

CORRECTIONS_FILE=$(mktemp)
GAPS_FILE=$(mktemp)
REPEATED_FILE=$(mktemp)
WORKWAY_FILE=$(mktemp)
PROMPTS_FILE=$(mktemp)

cleanup() {
    rm -f "$CORRECTIONS_FILE" "$GAPS_FILE" "$REPEATED_FILE" "$WORKWAY_FILE" "$PROMPTS_FILE" "${REPEATED_FILE}.grouped" 2>/dev/null
}
trap cleanup EXIT

echo "CONVERSATION INTELLIGENCE REPORT"
echo "==================================================="
echo "  Period: last $DAYS days"
echo "  Source: $PROJECT_SESSIONS"
echo ""

if [[ ! -d "$PROJECT_SESSIONS" ]]; then
    echo "  ERROR: Sessions directory not found: $PROJECT_SESSIONS"
    echo "  Make sure you're running from a project directory with Claude Code sessions."
    exit 1
fi

SESSION_COUNT=0
TOTAL_PROMPTS=0

for session in $(find "$PROJECT_SESSIONS" -name "*.jsonl" -mtime -"$DAYS" 2>/dev/null | grep -v '/agent-a' | sort -r); do
    SESSION_COUNT=$((SESSION_COUNT + 1))
    session_name=$(basename "$session")

    # Extract user prompts with noise filtering
    jq -r '
      select(.type == "user") | .message.content |
      if type == "string" then .
      elif type == "array" then [.[] |
        if type == "string" then .
        elif .type == "text" then .text
        else empty end
      ] | join("\n")
      else empty end
    ' "$session" 2>/dev/null | \
        sed '/<system-reminder>/,/<\/system-reminder>/d' | \
        sed '/<local-command-caveat>/d; /<command-name>/d; /<command-args>/d; /<local-command-stdout>/d; /<\/local-command-stdout>/d; /<\/command-name>/d; /<\/command-args>/d; /<\/local-command-caveat>/d' | \
        grep -v "^Base directory for this skill:" | \
        grep -v "^Implement the following plan:" | \
        grep -v "^\[*Request interrupted by user" | \
        grep -v "consider using the TeamCreate tool" | \
        grep -v "^$" > "$PROMPTS_FILE" 2>/dev/null || true

    [[ ! -s "$PROMPTS_FILE" ]] && continue

    prompt_count=$(wc -l < "$PROMPTS_FILE" | tr -d ' ')
    TOTAL_PROMPTS=$((TOTAL_PROMPTS + prompt_count))

    # All detection phases in a single awk pass per session
    awk -v sess="$session_name" -v corr_file="$CORRECTIONS_FILE" -v gaps_file="$GAPS_FILE" -v rep_file="$REPEATED_FILE" -v work_file="$WORKWAY_FILE" '
    {
        line = $0
        len = length(line)
        lower = tolower(line)

        # Skip structured content (markdown, code, list items, indented)
        if (lower ~ /^[#\-\*>|`]/ || lower ~ /^[0-9]+\./ || lower ~ /^   / || lower ~ /^"/) next

        # Correction detection (< 200 chars, > 2 chars)
        if (len > 2 && len < 200) {
            if (lower ~ /^no[, ]/ || lower ~ /not correct/ || lower ~ /not right/ || lower ~ /thats wrong/ || lower ~ /that.?s wrong/ || lower ~ /^wrong/ || lower ~ /fix it/ || lower ~ /fix that/ || lower ~ /^should be / || lower ~ /^it should be / || lower ~ /use .+ instead/) {
                print "HIGH|" sess "|" line >> corr_file
            } else if (lower ~ /^actually[, ]/ || lower ~ /are you sure/ || lower ~ /why is it using/ || lower ~ /isnt it/ || lower ~ /isn.?t it/ || lower ~ /too complex/ || lower ~ /we dont need/ || lower ~ /we don.?t need/) {
                print "MEDIUM|" sess "|" line >> corr_file
            }
        }

        # Knowledge gap detection (< 300 chars, > 4 chars)
        if (len > 4 && len < 300) {
            if (lower ~ /why is it using/ || lower ~ /but what about/ || lower ~ /isnt it using/ || lower ~ /isn.?t it using/ || lower ~ /its in \.env/ || lower ~ /it.?s in \.env/ || lower ~ /from the config/ || lower ~ /stored in/ || lower ~ /set in/ || lower ~ /we use / || lower ~ /should be using/ || lower ~ /supposed to/) {
                print sess "|" line >> gaps_file
            }
        }

        # Repeated instruction detection (10-150 chars)
        if (len >= 10 && len <= 150) {
            normalized = lower
            gsub(/[^a-z0-9 ]/, "", normalized)
            gsub(/  +/, " ", normalized)
            gsub(/^ +| +$/, "", normalized)
            if (length(normalized) > 0) {
                print normalized "|" sess >> rep_file
            }
        }

        # Workway pattern detection (8-200 chars)
        if (len >= 8 && len <= 200) {
            if (lower ~ /\<always\>/ || lower ~ /\<never\>/ || lower ~ /\<prefer\>/ || lower ~ /\<i want\>/ || lower ~ /i dont want/ || lower ~ /i don.?t want/ || lower ~ /\<we should\>/ || lower ~ /we dont\>/ || lower ~ /we don.?t\>/ || lower ~ /lets use/ || lower ~ /let.?s use/ || lower ~ /dont use/ || lower ~ /don.?t use/ || lower ~ /should always/ || lower ~ /should never/ || lower ~ /make sure/ || lower ~ /remember to/) {
                print sess "|" line >> work_file
            }
        }
    }
    ' "$PROMPTS_FILE"
done

echo "  Sessions analyzed: $SESSION_COUNT"
echo "  Total prompts extracted: $TOTAL_PROMPTS"
echo ""

# === Corrections ===
echo "CORRECTION PATTERNS"
echo "---------------------------------------------------"

HIGH_COUNT=0
MEDIUM_COUNT=0
if [[ -s "$CORRECTIONS_FILE" ]]; then
    HIGH_COUNT=$(grep -c "^HIGH|" "$CORRECTIONS_FILE" 2>/dev/null || echo "0")
    MEDIUM_COUNT=$(grep -c "^MEDIUM|" "$CORRECTIONS_FILE" 2>/dev/null || echo "0")
    echo "  HIGH confidence: $HIGH_COUNT"
    echo "  MEDIUM confidence: $MEDIUM_COUNT"
    echo ""

    if [[ "$HIGH_COUNT" -gt 0 ]]; then
        echo "  HIGH confidence corrections:"
        grep "^HIGH|" "$CORRECTIONS_FILE" | head -"$TOP" | while IFS='|' read -r _ sess msg; do
            echo "    Session: $sess"
            echo "      \"$(echo "$msg" | cut -c1-120)\""
            echo ""
        done
    fi

    if [[ -n "$VERBOSE" && "$MEDIUM_COUNT" -gt 0 ]]; then
        echo "  MEDIUM confidence corrections:"
        grep "^MEDIUM|" "$CORRECTIONS_FILE" | head -"$TOP" | while IFS='|' read -r _ sess msg; do
            echo "    Session: $sess"
            echo "      \"$(echo "$msg" | cut -c1-120)\""
            echo ""
        done
    fi
else
    echo "  No correction patterns found"
fi
echo ""

# === Knowledge Gaps ===
echo "KNOWLEDGE GAPS"
echo "---------------------------------------------------"

if [[ -s "$GAPS_FILE" ]]; then
    GAP_COUNT=$(wc -l < "$GAPS_FILE" | tr -d ' ')
    echo "  Found: $GAP_COUNT signals"
    echo ""
    head -"$TOP" "$GAPS_FILE" | while IFS='|' read -r sess msg; do
        echo "  Session: $sess"
        echo "    \"$(echo "$msg" | cut -c1-120)\""
        echo ""
    done
else
    echo "  No knowledge gap signals found"
fi
echo ""

# === Repeated Instructions ===
echo "REPEATED INSTRUCTIONS (3+ sessions)"
echo "---------------------------------------------------"

if [[ -s "$REPEATED_FILE" ]]; then
    sort "$REPEATED_FILE" | awk -F'|' '{
        msg = $1
        sess = $2
        if (!(msg SUBSEP sess in seen)) {
            seen[msg SUBSEP sess] = 1
            count[msg]++
        }
    }
    END {
        for (msg in count) {
            if (count[msg] >= 3) {
                printf "%d|%s\n", count[msg], msg
            }
        }
    }' | sort -t'|' -k1 -rn > "${REPEATED_FILE}.grouped"

    REPEATED_COUNT=$(wc -l < "${REPEATED_FILE}.grouped" | tr -d ' ')
    echo "  Found: $REPEATED_COUNT repeated instructions"
    echo ""

    if [[ "$REPEATED_COUNT" -gt 0 ]]; then
        head -"$TOP" "${REPEATED_FILE}.grouped" | while IFS='|' read -r count msg; do
            echo "  ($count sessions) \"$msg\""
        done
    fi
else
    echo "  No repeated instructions found"
fi
echo ""

# === Workway Patterns ===
echo "WORKWAY PATTERNS"
echo "---------------------------------------------------"

if [[ -s "$WORKWAY_FILE" ]]; then
    WORKWAY_COUNT=$(wc -l < "$WORKWAY_FILE" | tr -d ' ')
    echo "  Found: $WORKWAY_COUNT preference signals"
    echo ""
    head -"$TOP" "$WORKWAY_FILE" | while IFS='|' read -r sess msg; do
        echo "  Session: $sess"
        echo "    \"$(echo "$msg" | cut -c1-120)\""
        echo ""
    done
else
    echo "  No workway patterns found"
fi
echo ""

# === Actionable Summary ===
echo "ACTIONABLE UPDATES"
echo "---------------------------------------------------"

if [[ "$HIGH_COUNT" -gt 0 ]]; then
    grep "^HIGH|" "$CORRECTIONS_FILE" | head -5 | while IFS='|' read -r _ sess msg; do
        echo "  [RULE] From correction: \"$(echo "$msg" | cut -c1-80)\""
    done
fi

if [[ -s "$GAPS_FILE" ]]; then
    head -5 "$GAPS_FILE" | while IFS='|' read -r sess msg; do
        echo "  [KNOWLEDGE] From gap: \"$(echo "$msg" | cut -c1-80)\""
    done
fi

if [[ -f "${REPEATED_FILE}.grouped" && -s "${REPEATED_FILE}.grouped" ]]; then
    head -3 "${REPEATED_FILE}.grouped" | while IFS='|' read -r count msg; do
        echo "  [WORKFLOW] Repeated $count times: \"$msg\""
    done
fi

if [[ -s "$WORKWAY_FILE" ]]; then
    head -3 "$WORKWAY_FILE" | while IFS='|' read -r sess msg; do
        echo "  [CONVENTION] From preference: \"$(echo "$msg" | cut -c1-80)\""
    done
fi

echo ""
echo "==================================================="
echo "  Run with --verbose for MEDIUM confidence corrections"
echo "  Adjust window with --days N (default: 14)"
echo "==================================================="
