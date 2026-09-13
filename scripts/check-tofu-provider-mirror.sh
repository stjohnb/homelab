#!/usr/bin/env bash
# Guard the offline provider mirror that lets the tf-runner NetworkPolicy deny
# all public egress (#1247).
#
#   1. The mirror Job's PROVIDER_VERSION must equal the version pinned in
#      tofu/unifi/versions.tf, or the mirror holds a package the runner's
#      lockfile rejects and every plan fails offline.
#   2. The Job's name must encode that version. Jobs are immutable: without a
#      rename Flux never re-runs the Job and the mirror silently stays stale.
#   3. The Job's image tag must equal the tofu-controller chart version, so the
#      mirror is written by the same tofu the runner uses.
#   4. The NetworkPolicy must never regain a 0.0.0.0/0 egress rule.
#
# Usage: ./scripts/check-tofu-provider-mirror.sh
# Requires: yq (mikefarah/yq, in flake.nix's `default` devShell)
set -uo pipefail

VERSIONS=tofu/unifi/versions.tf
MIRROR=clusters/my-cluster/tofu/provider-mirror.yaml
RELEASE=clusters/my-cluster/infrastructure/tofu-controller/release.yaml
NETPOL=clusters/my-cluster/tofu/networkpolicy.yaml

PROV=$(awk '/unifi *= *\{/,/^  \}/' "$VERSIONS" | sed -n 's/.*version *= *"\([^"]*\)".*/\1/p' | head -1)
[ -n "$PROV" ] || { echo "❌ could not read the provider version from $VERSIONS"; exit 1; }
CHART=$(yq -r '.spec.chart.spec.version' "$RELEASE")
JOB_NAME=$(yq -r 'select(.kind == "Job") | .metadata.name' "$MIRROR")
JOB_IMG=$(yq -r 'select(.kind == "Job") | .spec.template.spec.containers[0].image' "$MIRROR")
JOB_VER=$(yq -r 'select(.kind == "Job") | .spec.template.spec.containers[0].env[] | select(.name == "PROVIDER_VERSION") | .value' "$MIRROR")

WANT_NAME="tofu-provider-mirror-${PROV//./-}"
WANT_IMG="ghcr.io/flux-iac/tf-runner:v${CHART}"
FAILED=0

[ "$JOB_VER" = "$PROV" ] || { echo "❌ mirror Job PROVIDER_VERSION=$JOB_VER but $VERSIONS pins $PROV"; FAILED=1; }
[ "$JOB_NAME" = "$WANT_NAME" ] || { echo "❌ mirror Job is named '$JOB_NAME'; rename it to '$WANT_NAME' so Flux re-runs it"; FAILED=1; }
[ "$JOB_IMG" = "$WANT_IMG" ] || { echo "❌ mirror Job image '$JOB_IMG' does not match chart $CHART (want $WANT_IMG)"; FAILED=1; }
if grep -q '0\.0\.0\.0/0' "$NETPOL"; then
  echo "❌ $NETPOL has a 0.0.0.0/0 egress rule again — the runner must have no public egress (#1247)"
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "A provider bump is four edits in one PR: versions.tf, .terraform.lock.hcl, the Job name, PROVIDER_VERSION."
  exit 1
fi
echo "✅ tofu provider mirror consistent (provider $PROV, runner v$CHART)"
