#!/usr/bin/env bash
# Check that every third-party GitHub Action is pinned to a full 40-hex commit
# SHA rather than a mutable tag. A rewritten upstream tag would otherwise run
# attacker code in jobs holding this repo's OIDC token, registry credentials
# and version-bump PAT.
#
# In-repo composite actions (./.github/actions/...) are exempt: they are
# checked out at the workflow's own commit and cannot be SHA-pinned.
#
# Usage: ./scripts/check-action-pins.sh
# Requires: grep, bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

failed=0
checked=0

while IFS= read -r line; do
  file="${line%%:*}"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  ref="$(printf '%s\n' "$line" | sed -E 's/.*uses:[[:space:]]*//; s/[[:space:]]+#.*//')"

  # In-repo composite actions are exempt.
  case "$ref" in
    ./*) continue ;;
  esac

  checked=$((checked + 1))

  if ! printf '%s\n' "$ref" | grep -Eq '@[0-9a-f]{40}$'; then
    echo "❌ $file:$lineno — not SHA-pinned: $ref"
    failed=1
  fi
done < <(grep -rn --include='*.yml' --include='*.yaml' -E '^[[:space:]]*-?[[:space:]]*uses:' \
           "$REPO_ROOT/.github/workflows" "$REPO_ROOT/.github/actions" 2>/dev/null \
         | sed "s|$REPO_ROOT/||")

if [ "$failed" -ne 0 ]; then
  echo ""
  echo "❌ Pin third-party actions to a full commit SHA, e.g.:"
  echo "     uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262  # v4.4.0"
  echo "   Resolve with: gh api repos/<owner>/<repo>/git/ref/tags/<tag> --jq .object.sha"
  echo "   (if .object.type is \"tag\", dereference: gh api repos/<owner>/<repo>/git/tags/<sha> --jq .object.sha)"
  exit 1
fi

echo "✅ $checked third-party action reference(s) pinned to commit SHAs"
