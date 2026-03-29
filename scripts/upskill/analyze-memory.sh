#!/usr/bin/env bash
# Analyze Claude Code memory files for quality, staleness, and broken references
# Usage: ./analyze-memory.sh [--memory-dir PATH]

set -e

MEMORY_DIR=""

# Auto-detect memory directory from CWD
_detect_memory_dir() {
  local cwd="${1:-$(pwd)}"
  local encoded
  encoded=$(echo "$cwd" | sed 's|^/|-|; s|/|-|g')
  echo "$HOME/.claude/projects/${encoded}/memory"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --memory-dir) MEMORY_DIR="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--memory-dir PATH]"; exit 0 ;;
        *) shift ;;
    esac
done

MEMORY_DIR="${MEMORY_DIR:-$(_detect_memory_dir)}"

echo "MEMORY FILE QUALITY CHECK"
echo "==========================================================="
echo "  Memory dir: $MEMORY_DIR"
echo ""

MEMORY_ISSUES=0

if [[ ! -d "$MEMORY_DIR" ]]; then
    echo "  Memory directory not found: $MEMORY_DIR"
    echo "  This is normal if no memories have been saved for this project."
    echo ""
    echo "==========================================================="
    exit 0
fi

# Check MEMORY.md line count vs 200-line truncation limit
if [[ -f "$MEMORY_DIR/MEMORY.md" ]]; then
    MEMORY_LINES=$(wc -l < "$MEMORY_DIR/MEMORY.md" | tr -d ' ')
    if [[ "$MEMORY_LINES" -gt 180 ]]; then
        echo "  WARNING: MEMORY.md is $MEMORY_LINES lines (truncation at 200)"
        echo "    Move large sections to topic files to stay under limit"
        MEMORY_ISSUES=$((MEMORY_ISSUES + 1))
    elif [[ "$MEMORY_LINES" -gt 150 ]]; then
        echo "  CAUTION: MEMORY.md is $MEMORY_LINES lines (approaching 200-line truncation limit)"
    else
        echo "  MEMORY.md: $MEMORY_LINES lines (within limit)"
    fi
else
    echo "  WARNING: MEMORY.md not found at $MEMORY_DIR/MEMORY.md"
    MEMORY_ISSUES=$((MEMORY_ISSUES + 1))
fi
echo ""

# Check for broken topic file references in MEMORY.md
echo "BROKEN REFERENCES"
echo "-----------------------------------------------------------"
BROKEN_REFS=0

if [[ -f "$MEMORY_DIR/MEMORY.md" ]]; then
    # Check markdown link references like [Title](file.md)
    while IFS= read -r ref; do
        ref_file=$(echo "$ref" | sed 's/.*(\(.*\))/\1/')
        # Handle relative paths
        if [[ "$ref_file" == ./* ]]; then
            ref_file="${ref_file#./}"
        fi
        if [[ ! -f "$MEMORY_DIR/$ref_file" ]]; then
            echo "  BROKEN: MEMORY.md links to $ref_file which does not exist"
            BROKEN_REFS=$((BROKEN_REFS + 1))
        fi
    done < <(grep -oE '\[[^]]*\]\([^)]+\.md\)' "$MEMORY_DIR/MEMORY.md" 2>/dev/null || true)

    if [[ "$BROKEN_REFS" -eq 0 ]]; then
        echo "  No broken references found."
    fi
    MEMORY_ISSUES=$((MEMORY_ISSUES + BROKEN_REFS))
else
    echo "  (skipped - no MEMORY.md)"
fi
echo ""

# Check for stale date references (>30 days old)
echo "STALE DATE REFERENCES"
echo "-----------------------------------------------------------"
STALE_DATES=0

if [[ -f "$MEMORY_DIR/MEMORY.md" ]]; then
    # Cross-platform: 30 days ago
    THIRTY_DAYS_AGO=$(date -d "30 days ago" "+%Y-%m-%d" 2>/dev/null || date -v-30d "+%Y-%m-%d" 2>/dev/null || echo "")

    if [[ -n "$THIRTY_DAYS_AGO" ]]; then
        while IFS= read -r date_ref; do
            if [[ "$date_ref" < "$THIRTY_DAYS_AGO" ]]; then
                echo "  STALE: $date_ref (older than 30 days)"
                STALE_DATES=$((STALE_DATES + 1))
            fi
        done < <(grep -oE '20[0-9]{2}-[0-9]{2}-[0-9]{2}' "$MEMORY_DIR/MEMORY.md" 2>/dev/null | sort -u || true)

        if [[ "$STALE_DATES" -gt 0 ]]; then
            echo "  Found $STALE_DATES date references older than 30 days - review for relevance"
            MEMORY_ISSUES=$((MEMORY_ISSUES + 1))
        else
            echo "  No stale date references found."
        fi
    else
        echo "  (skipped - could not compute date threshold)"
    fi
else
    echo "  (skipped - no MEMORY.md)"
fi
echo ""

# Topic file inventory
echo "TOPIC FILES"
echo "-----------------------------------------------------------"
TOPIC_COUNT=0

for tf in "$MEMORY_DIR"/*.md; do
    [[ ! -f "$tf" ]] && continue
    tf_name=$(basename "$tf")
    [[ "$tf_name" == "MEMORY.md" ]] && continue
    tf_lines=$(wc -l < "$tf" | tr -d ' ')
    # Cross-platform last modified date
    tf_modified=$(date -r "$tf" "+%Y-%m-%d" 2>/dev/null || stat -c '%y' "$tf" 2>/dev/null | cut -d' ' -f1 || echo "unknown")
    printf "  %-35s %4d lines  (modified: %s)\n" "$tf_name" "$tf_lines" "$tf_modified"
    TOPIC_COUNT=$((TOPIC_COUNT + 1))
done

if [[ "$TOPIC_COUNT" -eq 0 ]]; then
    echo "  (no topic files found)"
fi
echo ""

# Check for orphaned topic files (exist on disk but not referenced in MEMORY.md)
echo "ORPHANED FILES"
echo "-----------------------------------------------------------"
ORPHANED=0

if [[ -f "$MEMORY_DIR/MEMORY.md" ]]; then
    for tf in "$MEMORY_DIR"/*.md; do
        [[ ! -f "$tf" ]] && continue
        tf_name=$(basename "$tf")
        [[ "$tf_name" == "MEMORY.md" ]] && continue
        if ! grep -q "$tf_name" "$MEMORY_DIR/MEMORY.md" 2>/dev/null; then
            echo "  ORPHANED: $tf_name (exists but not referenced in MEMORY.md)"
            ORPHANED=$((ORPHANED + 1))
        fi
    done
fi

if [[ "$ORPHANED" -eq 0 ]]; then
    echo "  No orphaned topic files."
fi
MEMORY_ISSUES=$((MEMORY_ISSUES + ORPHANED))
echo ""

# Summary
echo "==========================================================="
echo "SUMMARY"
echo "==========================================================="
echo ""
echo "  Topic files: $TOPIC_COUNT"
echo "  Broken refs: $BROKEN_REFS"
echo "  Stale dates: $STALE_DATES"
echo "  Orphaned:    $ORPHANED"
echo "  Total issues: $MEMORY_ISSUES"
echo ""
