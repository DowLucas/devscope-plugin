#!/usr/bin/env bash
# Analyze all CLAUDE.md files for staleness, accuracy, and hygiene
# Checks referenced paths, commands, versions, and cross-references
# Usage: ./analyze-claude-md.sh [--verbose] [--repo-root PATH]

set -e

VERBOSE=""
REPO_ROOT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose) VERBOSE="true"; shift ;;
        --repo-root) REPO_ROOT="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--verbose] [--repo-root PATH]"; exit 0 ;;
        *) shift ;;
    esac
done

# Auto-detect repo root
if [[ -z "$REPO_ROOT" ]]; then
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "$(pwd)")
fi

ISSUES_FILE=$(mktemp)
DUPES_FILE=$(mktemp)

cleanup() {
    rm -f "$ISSUES_FILE" "$DUPES_FILE" 2>/dev/null
}
trap cleanup EXIT

echo "CLAUDE.MD HYGIENE ANALYZER"
echo "==========================================================="
echo "  Repo root: $REPO_ROOT"
echo ""

# Collect all CLAUDE.md files
CLAUDE_FILES=()
while IFS= read -r f; do
    [[ -f "$f" ]] && CLAUDE_FILES+=("$f")
done < <(find "$REPO_ROOT" -name "CLAUDE.md" -not -path "*/node_modules/*" -not -path "*/.next/*" -not -path "*/dist/*" -not -path "*/.git/*" -not -path "*/vendor/*" 2>/dev/null | sort)

echo "FILES FOUND"
echo "-----------------------------------------------------------"
for f in "${CLAUDE_FILES[@]}"; do
    rel_path="${f#$REPO_ROOT/}"
    size=$(wc -c < "$f" | tr -d ' ')
    lines=$(wc -l < "$f" | tr -d ' ')
    printf "  %-55s %5d bytes  %4d lines\n" "$rel_path" "$size" "$lines"
done
echo ""
echo "  Total: ${#CLAUDE_FILES[@]} files"
echo ""

if [[ ${#CLAUDE_FILES[@]} -eq 0 ]]; then
    echo "  No CLAUDE.md files found in $REPO_ROOT"
    exit 0
fi

TOTAL_ISSUES=0

# Dead file/directory references
echo "DEAD FILE/DIRECTORY REFERENCES"
echo "-----------------------------------------------------------"
DEAD_REFS=0

for f in "${CLAUDE_FILES[@]}"; do
    rel_path="${f#$REPO_ROOT/}"

    # Extract backtick-quoted paths that look like file references
    grep -oE '`[a-zA-Z0-9_./-]+(/[a-zA-Z0-9_./-]+)+`' "$f" 2>/dev/null | tr -d '`' | while IFS= read -r ref_path; do
        # Skip URLs, shell variables, generic examples
        [[ "$ref_path" == *"http"* ]] && continue
        [[ "$ref_path" == *'$'* ]] && continue
        [[ "$ref_path" == *"{env}"* ]] && continue
        [[ "$ref_path" == *"{project}"* ]] && continue
        [[ "$ref_path" == *"<"* ]] && continue
        [[ "$ref_path" == *"your-"* ]] && continue
        [[ "$ref_path" == *"node_modules"* ]] && continue
        [[ "$ref_path" == *"example"* ]] && continue

        # Resolve relative to repo root or to the CLAUDE.md's directory
        if [[ -e "$REPO_ROOT/$ref_path" ]]; then
            continue
        fi

        claude_dir=$(dirname "$f")
        if [[ -e "$claude_dir/$ref_path" ]]; then
            continue
        fi

        # Could be a glob pattern
        if compgen -G "$REPO_ROOT/$ref_path" > /dev/null 2>&1; then
            continue
        fi

        echo "  DEAD: $ref_path"
        echo "    Referenced in: $rel_path"
        DEAD_REFS=$((DEAD_REFS + 1))
    done
done

if [[ "$DEAD_REFS" -eq 0 ]]; then
    echo "  No dead file references found."
fi
TOTAL_ISSUES=$((TOTAL_ISSUES + DEAD_REFS))
echo ""

# Duplicated guidance
echo "DUPLICATED GUIDANCE"
echo "-----------------------------------------------------------"
DUPE_COUNT=0

if [[ ${#CLAUDE_FILES[@]} -ge 2 ]]; then
    # Extract significant lines from each file and find overlaps
    for f in "${CLAUDE_FILES[@]}"; do
        rel_path="${f#$REPO_ROOT/}"
        grep -v '^#\|^$\|^```\|^-\s*$\|^\s*$' "$f" 2>/dev/null | \
            grep -E '.{30,}' | \
            while IFS= read -r line; do
                normalized=$(echo "$line" | tr -s ' ' | sed 's/^ *//;s/ *$//')
                echo "$normalized|$rel_path"
            done
    done | sort > "$DUPES_FILE"

    # Find lines that appear in multiple files
    cut -d'|' -f1 "$DUPES_FILE" | sort | uniq -c | sort -rn | while read count phrase; do
        if [[ "$count" -ge 2 && ${#phrase} -ge 40 ]]; then
            files=$(grep -F "$phrase" "$DUPES_FILE" 2>/dev/null | cut -d'|' -f2 | sort -u | wc -l | tr -d ' ')
            if [[ "$files" -ge 2 ]]; then
                echo "  DUPE: \"$(echo "$phrase" | cut -c1-80)...\""
                grep -F "$phrase" "$DUPES_FILE" 2>/dev/null | cut -d'|' -f2 | sort -u | while IFS= read -r df; do
                    echo "    in: $df"
                done
                DUPE_COUNT=$((DUPE_COUNT + 1))
            fi
        fi
    done 2>/dev/null | head -30
fi

if [[ "$DUPE_COUNT" -eq 0 ]]; then
    echo "  No significant duplicated guidance found."
fi
echo ""

# Referenced scripts validation
echo "REFERENCED SCRIPTS/COMMANDS VALIDATION"
echo "-----------------------------------------------------------"
DEAD_SCRIPTS=0

for f in "${CLAUDE_FILES[@]}"; do
    rel_path="${f#$REPO_ROOT/}"

    grep -oE '(bash |\./) *[a-zA-Z0-9_/-]+\.sh' "$f" 2>/dev/null | sed 's/^bash //;s/^\.\///' | while IFS= read -r script; do
        if [[ ! -f "$REPO_ROOT/$script" ]]; then
            claude_dir=$(dirname "$f")
            if [[ ! -f "$claude_dir/$script" ]]; then
                echo "  DEAD SCRIPT: $script (referenced in $rel_path)"
                DEAD_SCRIPTS=$((DEAD_SCRIPTS + 1))
            fi
        fi
    done
done

if [[ "$DEAD_SCRIPTS" -eq 0 ]]; then
    echo "  All referenced scripts exist."
fi
TOTAL_ISSUES=$((TOTAL_ISSUES + DEAD_SCRIPTS))
echo ""

# Staleness check (git-based)
echo "STALENESS CHECK (git-based)"
echo "-----------------------------------------------------------"
echo "  File freshness (last modified):"

IS_GIT_REPO=$(git -C "$REPO_ROOT" rev-parse --is-inside-work-tree 2>/dev/null || echo "false")

for f in "${CLAUDE_FILES[@]}"; do
    rel_path="${f#$REPO_ROOT/}"

    if [[ "$IS_GIT_REPO" == "true" ]]; then
        last_commit=$(git -C "$REPO_ROOT" log -1 --format="%ai" -- "$rel_path" 2>/dev/null || echo "unknown")
        last_date=$(echo "$last_commit" | cut -d' ' -f1)

        service_dir=$(dirname "$f")
        service_rel="${service_dir#$REPO_ROOT/}"
        service_last=$(git -C "$REPO_ROOT" log -1 --format="%ai" -- "$service_rel/" 2>/dev/null | cut -d' ' -f1)

        if [[ "$last_date" != "unknown" && -n "$service_last" ]]; then
            # Cross-platform date arithmetic
            claude_epoch=$(date -d "$last_date" "+%s" 2>/dev/null || date -j -f "%Y-%m-%d" "$last_date" "+%s" 2>/dev/null || echo "0")
            service_epoch=$(date -d "$service_last" "+%s" 2>/dev/null || date -j -f "%Y-%m-%d" "$service_last" "+%s" 2>/dev/null || echo "0")
            diff_days=$(( (service_epoch - claude_epoch) / 86400 ))

            staleness=""
            if [[ "$diff_days" -gt 30 ]]; then
                staleness=" !! STALE ($diff_days days behind service)"
                TOTAL_ISSUES=$((TOTAL_ISSUES + 1))
            elif [[ "$diff_days" -gt 14 ]]; then
                staleness=" (${diff_days}d behind)"
            fi

            printf "    %-45s last: %s%s\n" "$rel_path" "$last_date" "$staleness"
        else
            printf "    %-45s last: %s\n" "$rel_path" "$last_date"
        fi
    else
        printf "    %-45s (not a git repo)\n" "$rel_path"
    fi
done
echo ""

# Summary
echo "==========================================================="
echo "SUMMARY"
echo "==========================================================="
echo ""
echo "  CLAUDE.md files analyzed: ${#CLAUDE_FILES[@]}"
echo "  Total issues found:      $TOTAL_ISSUES"
echo ""

if [[ "$TOTAL_ISSUES" -gt 0 ]]; then
    echo "  ACTION REQUIRED: Review and update the flagged CLAUDE.md sections"
else
    echo "  All CLAUDE.md files appear healthy."
fi
echo ""
