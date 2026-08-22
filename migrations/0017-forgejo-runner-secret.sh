#!/usr/bin/env bash
set -euo pipefail

NS="default"
SECRET_NAME="forgejo-runner-secret"

# Skip if the runner is already registered
if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

# Deployment pod names change across rollouts, so look the pod up by label
POD=$(kubectl get pod -n "$NS" -l app=forgejo \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}')
if [ -z "$POD" ]; then
  echo "No forgejo pod found, will retry on next migration run"
  exit 1
fi

SECRET=$(kubectl exec -n "$NS" "$POD" -- forgejo forgejo-cli actions generate-secret)
UUID=$(kubectl exec -n "$NS" "$POD" -- forgejo forgejo-cli actions register --name k3s-runner --secret "$SECRET")

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=uuid="$UUID" --from-literal=token="$SECRET"
echo "Successfully registered forgejo runner and created $SECRET_NAME"
