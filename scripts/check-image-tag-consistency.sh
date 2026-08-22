#!/usr/bin/env bash
# Validate that no service directory pins the same image repository to two
# different tags.
#
# Usage: scripts/check-image-tag-consistency.sh
#   Run from the repo root.
#
# Checks performed:
#   1. Extracts every `image:` reference under apps/, clusters/, migrations/
#   2. Skips Helm-templated / shell-substituted refs, digest-pinned refs,
#      and untagged refs
#   3. Groups by (directory, image repository) and fails if the same group
#      has more than one distinct tag
#
# Directory-scoped deliberately: the same image (e.g. busybox, postgres) may
# legitimately be pinned to different tags in different service directories.

set -uo pipefail

REFS="$(find apps clusters migrations -name '*.yaml' -print0 \
  | xargs -0 -r grep -oHE '^[[:space:]]*-?[[:space:]]*image:[[:space:]]*"?[^ "]+' \
  | sed -E 's/:[[:space:]]*-?[[:space:]]*image:[[:space:]]*"?/\t/' \
  | grep -v '{{\|\$(\|\${\|@sha256' || true)"

OUTPUT="$(printf '%s\n' "$REFS" | awk -F'\t' '
  $2 == "" { next }
  { n = split($2, a, ":"); if (n < 2) next          # untagged ref — skip
    tag = a[n]; repo = $2; sub(/:[^:]*$/, "", repo)
    dir = $1; sub(/\/[^\/]*$/, "", dir)
    k = dir "|" repo
    if (!(k in seen)) { seen[k] = tag; where[k] = $1; groups++ }
    else if (seen[k] != tag) {
      printf "❌ %s: %s pinned to %s (%s) but %s (%s)\n",
             dir, repo, seen[k], where[k], tag, $1
      bad = 1 } }
  END { if (!bad) printf "✅ No image tag skew within any service directory (%d groups checked)\n", groups
        exit bad ? 1 : 0 }')"
STATUS=$?
echo "$OUTPUT"
exit "$STATUS"
