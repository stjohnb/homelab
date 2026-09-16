#!/usr/bin/env bash
# Check that every Grafana provisioned UID in the kube-prometheus-stack
# HelmRelease is present, unique, and <= 40 characters.
#
# Grafana's UID validator rejects anything longer than 40 characters. The
# manifest is still valid YAML, so kustomize and kubeconform pass it — the
# violation only surfaces at runtime, where the alerting provisioner fails
# and takes the whole Grafana process down with it (CrashLoopBackOff, and
# with Alertmanager disabled that means no alerting at all). See #1081.
#
# Usage: ./scripts/check-grafana-alert-uids.sh
# Requires: yq (https://github.com/mikefarah/yq)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${1:-$REPO_ROOT/apps/monitoring/kube-prometheus-stack.yaml}"
MAX_LEN=40

if [ ! -f "$FILE" ]; then
  echo "❌ $FILE not found"
  exit 1
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

# " :: " separator — UIDs never contain spaces, so field 1 is always the UID.
yq -N '.spec.values.grafana.alerting."rules.yaml".groups[].rules[] |
  (.uid // "<missing>") + " :: alert rule " + (.title // "<untitled>")' "$FILE" > "$TMP" || {
  echo "❌ failed to read alert rules from $FILE"
  exit 1
}

yq -N '.spec.values.grafana.alerting."contactpoints.yaml".contactPoints[].receivers[] |
  (.uid // "<missing>") + " :: contact point (" + (.type // "untyped") + ")"' "$FILE" >> "$TMP" || {
  echo "❌ failed to read contact points from $FILE"
  exit 1
}

TOTAL=$(grep -c . "$TMP")
if [ "$TOTAL" -eq 0 ]; then
  echo "❌ no Grafana UIDs extracted from $FILE — the values structure changed, fix this script"
  exit 1
fi

echo "==> Checking $TOTAL Grafana UID(s) (max $MAX_LEN characters)..."

FAILED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  uid=${line%% :: *}
  what=${line#* :: }
  if [ "$uid" = "<missing>" ]; then
    echo "❌ $what has no uid"
    FAILED=1
  elif [ "${#uid}" -gt "$MAX_LEN" ]; then
    echo "❌ uid \"$uid\" is ${#uid} characters (max $MAX_LEN) — $what"
    FAILED=1
  fi
done < "$TMP"

while IFS= read -r dupe; do
  [ -z "$dupe" ] && continue
  echo "❌ uid \"$dupe\" is used more than once"
  FAILED=1
done < <(cut -d' ' -f1 "$TMP" | sort | uniq -d)

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "❌ Grafana UID check failed — Grafana refuses to start on an invalid provisioned UID"
  exit 1
fi

echo "✅ $TOTAL Grafana UID(s) valid"
