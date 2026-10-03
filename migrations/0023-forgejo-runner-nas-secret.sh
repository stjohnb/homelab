#!/usr/bin/env bash
set -euo pipefail

NS="default"
SECRET_NAME="forgejo-runner-nas-secret"

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

# Generate AND register inside one in-pod shell. Passing the token as a kubectl
# exec argument would place it in the apiserver request URI (each argv becomes a
# `command=` query parameter), where audit logging captures it verbatim at any
# audit level. Only the results come back, over stdout. (#902)
OUT=$(kubectl exec -n "$NS" "$POD" -- sh -c '
  set -e
  S=$(forgejo forgejo-cli actions generate-secret)
  U=$(forgejo forgejo-cli actions register --name nas-runner --secret "$S")
  printf "%s\n%s\n" "$S" "$U"
')

SECRET=$(printf '%s\n' "$OUT" | sed -n '1p')
UUID=$(printf '%s\n' "$OUT" | sed -n '2p')

# The old code captured whatever stdout produced with no validation. Assert the
# shapes, because a malformed capture here writes a permanently broken Secret:
# this migration short-circuits on "secret already exists" and never re-runs.
if [[ ! "$SECRET" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: generate-secret did not return a 40-char hex token" >&2
  exit 1
fi
if [ -z "$UUID" ]; then
  echo "ERROR: register returned an empty runner UUID" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=uuid="$UUID" --from-literal=token="$SECRET"
echo "Successfully registered forgejo runner and created $SECRET_NAME"
