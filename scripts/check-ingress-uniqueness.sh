#!/usr/bin/env bash
# Check that no two Ingress or IngressRoute resources claim the same hostname.
# Operates on kustomize build output for apps and infrastructure overlays.
#
# Usage: ./scripts/check-ingress-uniqueness.sh
# Requires: kustomize, yq (https://github.com/mikefarah/yq)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t OVERLAYS < <("$SCRIPT_DIR/overlays.sh" | cut -d: -f1)
if [ "${#OVERLAYS[@]}" -eq 0 ]; then
  echo "❌ scripts/overlays.sh produced no overlays"
  exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

for overlay in "${OVERLAYS[@]}"; do
  if [ ! -d "$overlay" ]; then
    continue
  fi
  echo "Building $overlay..."
  MANIFESTS=$(kustomize build "$overlay") || {
    echo "❌ kustomize build $overlay failed"
    exit 1
  }

  # Ingress: extract spec.rules[].host
  # Output format: "hostname resource-name/namespace"
  echo "$MANIFESTS" | yq -N '
    select(.kind == "Ingress") |
    (.metadata.name + "/" + (.metadata.namespace // "default")) as $ref |
    .spec.rules[]?.host |
    select(. != null) |
    . + " " + $ref
  ' >> "$TMP"

  # IngressRoute: extract Host(`...`) patterns from spec.routes[].match
  # Handles compound expressions like Host(`a`) && PathPrefix(`/api`)
  # or Host(`a`) || Host(`b`) (which contain literal || characters)
  # Use tab as delimiter since it cannot appear in Traefik match expressions
  while IFS=$'\t' read -r match ref; do
    [ -z "$match" ] && continue
    echo "$match" | grep -oP 'Host\(`\K[^`]+' | while read -r host; do
      echo "$host $ref"
    done
  done < <(echo "$MANIFESTS" | yq -N '
    select(.kind == "IngressRoute") |
    (.metadata.name + "/" + (.metadata.namespace // "default")) as $ref |
    .spec.routes[]?.match |
    select(. != null) |
    . + "\t" + $ref
  ') >> "$TMP"
done

TOTAL=$(wc -l < "$TMP")
if [ "$TOTAL" -eq 0 ]; then
  echo "⚠️  No Ingress or IngressRoute hostnames found — nothing to check"
  exit 0
fi

echo ""
echo "==> Checking $TOTAL host entries for duplicates..."
echo ""

# Sort, deduplicate exact pairs, then flag any hostname that maps to >1 resource.
# NOTE: This intentionally flags all hostname collisions regardless of path matchers.
# Path-based routing (multiple resources sharing a host with different PathPrefix values)
# is valid in Traefik but is not used in this repo's conventions, so we treat it as a conflict.
sort -u "$TMP" | awk '
{
  if ($1 == prev_host) {
    if (!conflict[$1]++) {
      print "❌ CONFLICT: hostname \"" $1 "\" claimed by multiple resources:"
      print "   - " prev_ref
    }
    print "   - " $2
    failed = 1
  }
  prev_host = $1
  prev_ref = $2
  hosts[$1] = 1
}
END {
  n = 0
  for (h in hosts) n++
  if (failed) {
    print ""
    print "❌ " n " hostname(s) checked, conflicts found above"
    exit 1
  }
  print "✅ " n " unique hostname(s), no conflicts"
}'
