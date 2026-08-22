#!/usr/bin/env bash
# Check that every imagePullSecrets reference resolves to a dockerconfigjson
# Secret produced by the same overlay.
#
# Kubernetes does not reject a workload that names a nonexistent pull secret —
# kubelet logs a warning and falls back to an anonymous pull, which only fails
# once the image is no longer cached on the node. This guard makes the typo
# fatal at PR time instead. (See #856: arpwatch referenced `ghcr-pull-secret`,
# the *filename* of apps/ghcr-pull-secret.enc.yaml, instead of the Secret's
# actual name `ghcr-pull`.)
#
# Usage: ./scripts/check-image-pull-secrets.sh
# Requires: kustomize, yq (https://github.com/mikefarah/yq)

set -uo pipefail

# overlay:effective-default-namespace, from scripts/overlays.sh (single
# source of truth). apps and migrations get targetNamespace: default from
# their Flux Kustomizations; infrastructure and config do not set
# targetNamespace.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t OVERLAYS < <("$SCRIPT_DIR/overlays.sh")
if [ "${#OVERLAYS[@]}" -eq 0 ]; then
  echo "❌ scripts/overlays.sh produced no overlays"
  exit 1
fi

# Pull secrets bootstrapped imperatively (kubectl create secret) rather than
# rendered from Git. Format: namespace/name. Keep this empty if you can —
# prefer a SOPS-encrypted *.enc.yaml (see docs/ghcr-auth.md).
ALLOWLIST=()

REFS=$(mktemp)
SECRETS=$(mktemp)
trap 'rm -f "$REFS" "$SECRETS"' EXIT

for entry in "${OVERLAYS[@]}"; do
  overlay="${entry%%:*}"
  export DEFAULT_NS="${entry#*:}"
  [ -d "$overlay" ] || continue

  echo "Building $overlay..."
  MANIFESTS=$(kustomize build "$overlay") || {
    echo "❌ kustomize build $overlay failed"
    exit 1
  }

  # References: "namespace/secret-name Kind/resource-name"
  echo "$MANIFESTS" | yq -N '
    select(.kind != "HelmRelease") |
    (.metadata.namespace // strenv(DEFAULT_NS)) as $ns |
    (.kind + "/" + .metadata.name) as $ref |
    .. | select(tag == "!!map") | select(has("imagePullSecrets")) |
    .imagePullSecrets[] |
    $ns + "/" + .name + " " + $ref
  ' >> "$REFS"

  # Declarations: "namespace/secret-name"
  echo "$MANIFESTS" | yq -N '
    select(.kind == "Secret" and .type == "kubernetes.io/dockerconfigjson") |
    (.metadata.namespace // strenv(DEFAULT_NS)) + "/" + .metadata.name
  ' >> "$SECRETS"
done

for allowed in ${ALLOWLIST[@]+"${ALLOWLIST[@]}"}; do
  echo "$allowed" >> "$SECRETS"
done

TOTAL=$(grep -c . "$REFS" || true)
if [ "$TOTAL" -eq 0 ]; then
  echo "⚠️  No imagePullSecrets references found — nothing to check"
  exit 0
fi

echo ""
echo "==> Checking $TOTAL imagePullSecrets reference(s)..."
echo ""

FAILED=0
while read -r secret ref; do
  [ -z "$secret" ] && continue
  if grep -qxF "$secret" "$SECRETS"; then
    echo "✅ $ref → $secret"
  else
    echo "❌ $ref references pull secret \"$secret\", which no overlay creates"
    FAILED=1
  fi
done < <(sort -u "$REFS")

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "Declared dockerconfigjson secrets:"
  sort -u "$SECRETS" | sed 's/^/   - /'
  echo ""
  echo "Fix the reference, add a SOPS-encrypted Secret (docs/ghcr-auth.md),"
  echo "or add namespace/name to ALLOWLIST in this script if it is created"
  echo "imperatively."
  exit 1
fi

echo ""
echo "✅ All $TOTAL imagePullSecrets reference(s) resolve"
