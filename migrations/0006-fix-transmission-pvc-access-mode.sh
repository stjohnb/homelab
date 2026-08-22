#!/usr/bin/env bash
set -euo pipefail

PVC_NAME="transmission-downloads-pvc"
PV_NAME="transmission-downloads-nfs-pv"
NS="default"

# No-op if PVC is already gone or already correct
if ! kubectl get pvc "$PVC_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "PVC $PVC_NAME not found, nothing to do"
  exit 0
fi

ACCESS_MODE=$(kubectl get pvc "$PVC_NAME" -n "$NS" \
  -o jsonpath='{.spec.accessModes[0]}')
if [ "$ACCESS_MODE" = "ReadWriteMany" ]; then
  echo "PVC $PVC_NAME already has ReadWriteMany, skipping"
  exit 0
fi

echo "PVC $PVC_NAME has accessMode '$ACCESS_MODE' — scaling down Transmission before deletion"

kubectl scale deployment transmission -n "$NS" --replicas=0
# Guard: skip wait if no pods exist (already at 0 replicas or pods already gone)
if kubectl get pods -l app=transmission -n "$NS" --no-headers 2>/dev/null | grep -q .; then
  kubectl wait --for=delete pod -l app=transmission -n "$NS" --timeout=60s
fi

echo "Deleting PVC $PVC_NAME so Flux can recreate with ReadWriteMany"

kubectl delete pvc "$PVC_NAME" -n "$NS"
echo "Deleted PVC $PVC_NAME"
kubectl wait --for=delete pvc "$PVC_NAME" -n "$NS" --timeout=60s
echo "PVC $PVC_NAME fully removed"

if kubectl get pv "$PV_NAME" >/dev/null 2>&1; then
  kubectl delete pv "$PV_NAME"
  echo "Deleted PV $PV_NAME"
  kubectl wait --for=delete pv "$PV_NAME" --timeout=120s || \
    echo "WARNING: PV may still be terminating; Flux reconciliation may need a retry"
else
  echo "PV $PV_NAME not found, skipping"
fi

echo "Done. Flux will recreate both resources with ReadWriteMany on next reconciliation."
