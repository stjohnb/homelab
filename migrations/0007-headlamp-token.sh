#!/usr/bin/env bash
set -euo pipefail

SECRET_NAME="headlamp-token"
NS="default"

# Check if secret already exists
if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

# Ensure the headlamp SA exists before creating the token secret
if ! kubectl get serviceaccount headlamp -n "$NS" >/dev/null 2>&1; then
  echo "ERROR: ServiceAccount 'headlamp' not found in namespace '$NS'. Deploy Headlamp first." >&2
  exit 1
fi

# Create a long-lived service account token secret for Headlamp.
# Kubernetes token controller will automatically populate the token field.
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NS}
  annotations:
    kubernetes.io/service-account.name: headlamp
type: kubernetes.io/service-account-token
EOF

echo "Created ${SECRET_NAME} — Kubernetes will populate the token automatically"
