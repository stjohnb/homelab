#!/usr/bin/env bash
# Check that every Grafana alert rule built on absent() uses noDataState: OK.
#
# absent(v) returns 1 only when v is EMPTY, and returns nothing when v has
# samples. For an `absent(up{job="x"} == 1)` target-down rule that means:
#   target healthy   -> up == 1 matches -> absent() empty -> Grafana NoData
#   target down/gone -> up == 1 empty   -> absent() == 1  -> rule fires
# NoData is therefore the HEALTHY state and noDataState MUST be OK. Setting it
# to Alerting inverts the rule so it fires `for:` after every Grafana restart
# with the target perfectly up. postgres-exporter-target-down did exactly that
# twice on 2026-09-09 (#1244, #1260): Grafana rolled at 22:27:57Z, the rule
# fired at 22:43:20Z, and up{job="postgres-exporter"} had been 1 unbroken for
# eight hours. kustomize and kubeconform cannot see it -- the YAML is valid.
#
# Usage: ./scripts/check-grafana-nodata-state.sh [file]
# Requires: yq (https://github.com/mikefarah/yq)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="${1:-$REPO_ROOT/apps/monitoring/kube-prometheus-stack.yaml}"

if [ ! -f "$FILE" ]; then
  echo "❌ $FILE not found"
  exit 1
fi

SELECT='.spec.values.grafana.alerting."rules.yaml".groups[].rules[] | select([.data[]?.model.expr // ""] | join(" ") | test("absent"))'

# " :: " separator — uid never contains spaces, so field 1 is always the uid.
PAIRS=$(yq -N "$SELECT | (.uid // \"<missing>\") + \" :: \" + (.noDataState // \"<unset>\")" "$FILE") || {
  echo "❌ failed to read alert rules from $FILE"
  exit 1
}

TOTAL=$(grep -c . <<< "$PAIRS")
if [ "$TOTAL" -eq 0 ]; then
  echo "❌ no absent()-based alert rules found in $FILE — the values structure changed, fix this script"
  exit 1
fi

echo "==> Checking $TOTAL absent()-based Grafana alert rule(s) for noDataState: OK..."

FAILED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  uid=${line%% :: *}
  state=${line#* :: }
  if [ "$state" != "OK" ]; then
    echo "❌ alert rule \"$uid\" uses absent() but sets noDataState: $state — must be OK, NoData is the healthy state for absent()"
    FAILED=1
  fi
done <<< "$PAIRS"

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "❌ Grafana noDataState check failed — an absent() rule with noDataState != OK fires whenever its target is healthy"
  exit 1
fi

echo "✅ $TOTAL absent()-based alert rule(s) use noDataState: OK"
