#!/usr/bin/env bash
# Validate .trivyignore governance: expiry dates, format, and upstream links.
#
# Usage: scripts/check-trivyignore.sh [--strict] [file]
#   --strict  Exit 1 on expiry warnings in addition to format errors
#   file      Path to trivyignore file (default: .trivyignore)
#
# Checks performed:
#   1. Every CVE line must match: CVE-YYYY-NNNNN exp:YYYY-MM-DD
#   2. Every CVE line must have a comment block above it containing https://
#   3. Expiry dates must be valid calendar dates
#   4. Warns when any suppression expires within 30 days
#   5. Errors when any suppression has already expired

set -uo pipefail

STRICT=0
FILE=".trivyignore"

for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) FILE="$arg" ;;
    esac
done

if [ ! -f "$FILE" ]; then
    echo "❌ File not found: $FILE"
    exit 1
fi

ERRORS=0
WARNINGS=0
TODAY_EPOCH=$(date -d "$(date +%Y-%m-%d)" +%s)
WARN_THRESHOLD_SECS=$((30 * 86400))

# Validate that a date string is a real calendar date.
# Uses date -d (Linux/GNU date only — CI runs on self-hosted Linux).
is_valid_date() {
    date -d "$1" +%s &>/dev/null
}

# Convert a YYYY-MM-DD date string to epoch seconds.
date_to_epoch() {
    date -d "$1" +%s
}

# Read the file into an array so we can look backward for comment context.
mapfile -t LINES < "$FILE"
TOTAL=${#LINES[@]}

for (( i=0; i<TOTAL; i++ )); do
    line="${LINES[$i]}"

    # Skip blank/whitespace-only lines and comment-only lines.
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue

    # Every non-blank, non-comment line must be a properly formatted CVE entry.
    if ! [[ "$line" =~ ^CVE-[0-9]{4}-[0-9]{4,}[[:space:]]+exp:[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]].*)?$ ]]; then
        echo "❌ Line $((i+1)): invalid format (expected 'CVE-YYYY-NNNNN exp:YYYY-MM-DD')"
        echo "   Got: $line"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Extract the CVE ID and expiry date using bash builtins.
    CVE_ID="${line%% *}"
    EXP_DATE="${line##*exp:}"
    EXP_DATE="${EXP_DATE%% *}"

    # Validate the expiry date is a real calendar date.
    if ! is_valid_date "$EXP_DATE"; then
        echo "❌ $CVE_ID: invalid expiry date '$EXP_DATE'"
        ERRORS=$((ERRORS + 1))
        continue
    fi

    # Check expiry (ceiling division so 12 hours remaining shows as 1 day, not 0).
    EXP_EPOCH=$(date_to_epoch "$EXP_DATE")
    DAYS_UNTIL=$(( (EXP_EPOCH - TODAY_EPOCH + 86399) / 86400 ))

    if [ "$EXP_EPOCH" -lt "$TODAY_EPOCH" ]; then
        DAYS_AGO=$(( (TODAY_EPOCH - EXP_EPOCH) / 86400 ))
        echo "❌ $CVE_ID: suppression EXPIRED on $EXP_DATE ($DAYS_AGO days ago) — remove or renew"
        ERRORS=$((ERRORS + 1))
    elif [ $(( EXP_EPOCH - TODAY_EPOCH )) -lt "$WARN_THRESHOLD_SECS" ]; then
        echo "⚠️  $CVE_ID: suppression expires in ${DAYS_UNTIL} day(s) on $EXP_DATE — re-evaluate soon"
        WARNINGS=$((WARNINGS + 1))
    fi

    # Check that the comment block immediately above this CVE line contains
    # at least one https:// URL. Walk backward through preceding comment lines
    # until we hit a blank line, a CVE entry, or the start of the file.
    # Grouped CVEs sharing the same comment block are supported: skip over
    # adjacent CVE lines, then search only the first comment block found.
    FOUND_URL=0
    j=$((i - 1))
    # Skip past any adjacent CVE lines (shared group).
    while [ $j -ge 0 ] && [[ "${LINES[$j]}" =~ ^CVE- ]]; do
        j=$((j - 1))
    done
    # Now walk backward through the comment block.
    while [ $j -ge 0 ]; do
        prev="${LINES[$j]}"
        # Stop at blank/whitespace-only lines (end of comment block).
        [[ "$prev" =~ ^[[:space:]]*$ ]] && break
        # Stop at non-comment lines (shouldn't happen in well-formed files).
        [[ ! "$prev" =~ ^[[:space:]]*# ]] && break
        # Found a URL in a comment line.
        if [[ "$prev" =~ https:// ]]; then
            FOUND_URL=1
            break
        fi
        j=$((j - 1))
    done

    if [ "$FOUND_URL" -eq 0 ]; then
        echo "❌ $CVE_ID: no upstream link (https://) found in preceding comment block"
        ERRORS=$((ERRORS + 1))
    fi
done

echo ""

if [ $ERRORS -gt 0 ] || [ $WARNINGS -gt 0 ]; then
    [ $ERRORS -gt 0 ] && echo "❌ $ERRORS error(s) found in $FILE"
    [ $WARNINGS -gt 0 ] && echo "⚠️  $WARNINGS warning(s) found in $FILE"
else
    echo "✅ .trivyignore governance check passed"
fi

if [ $ERRORS -gt 0 ]; then
    exit 1
fi

if [ $STRICT -eq 1 ] && [ $WARNINGS -gt 0 ]; then
    echo "   (--strict mode: warnings treated as errors)"
    exit 1
fi

[ $WARNINGS -eq 0 ] && echo "✅ No suppressions expiring within 30 days"
exit 0
