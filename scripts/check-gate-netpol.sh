#!/usr/bin/env bash
# Check that every service fronted by truenas-gate allows ingress from it.
# The gate's Ingress backend is truenas-gate:80, not the service directly, so
# a NetworkPolicy that omits app=truenas-gate from its ingress peers makes
# the ingress serve the "The NAS is asleep" wake page forever (see #771).
#
# Usage: ./scripts/check-gate-netpol.sh
# Requires: kustomize, yq (https://github.com/mikefarah/yq)

set -uo pipefail

MANIFESTS=$(kustomize build apps) || {
  echo "❌ kustomize build apps failed"
  exit 1
}

NGINX_CONF=$(echo "$MANIFESTS" | yq -N '
  select(.kind == "ConfigMap" and .metadata.name == "truenas-gate-nginx-config") |
  .data["nginx.conf"]')

if [ -z "$NGINX_CONF" ]; then
  echo "❌ truenas-gate-nginx-config ConfigMap not found"
  exit 1
fi

UPSTREAMS=$(echo "$NGINX_CONF" \
  | grep -oE 'server[[:space:]]+[a-z0-9-]+:[0-9]+;' \
  | sed -E 's/server[[:space:]]+([a-z0-9-]+):[0-9]+;/\1/' | sort -u)

if [ -z "$UPSTREAMS" ]; then
  echo "⚠️  No upstream backends found in truenas-gate nginx config — nothing to check"
  exit 0
fi

FAILED=0

for svc in $UPSTREAMS; do
  POLICY=$(echo "$MANIFESTS" | yq -N "
    select(.kind == \"NetworkPolicy\") |
    select(.spec.podSelector.matchLabels.app == \"$svc\")")

  if [ -z "$POLICY" ]; then
    echo "ℹ️  $svc: no NetworkPolicy (allow-all) — OK"
    continue
  fi

  PEERS=$(echo "$POLICY" | yq -N -o=json '[.spec.ingress[]?.from[]?]')

  if echo "$PEERS" | grep -q '"truenas-gate"'; then
    echo "✅ $svc: NetworkPolicy permits truenas-gate"
  else
    echo "❌ $svc: fronted by truenas-gate but its NetworkPolicy does not allow"
    echo "   ingress from app=truenas-gate. The ingress will serve the wake page"
    echo "   permanently. Add truenas-gate to the podSelector peer list."
    FAILED=1
  fi
done

exit "$FAILED"
