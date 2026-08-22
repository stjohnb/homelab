#!/usr/bin/env bash
# Runs numbered migration scripts from a migrations/ directory, tracking execution
# state in a Kubernetes ConfigMap. Completed scripts are never re-run; failed
# scripts are retried on the next invocation.
#
# Usage: run-migrations.sh [MIGRATIONS_DIR]
#   MIGRATIONS_DIR defaults to migrations/ relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATIONS_DIR="${1:-${SCRIPT_DIR}/migrations}"
STATE_CM="migration-state"
NS="default"

# Ensure state ConfigMap exists
kubectl get configmap "$STATE_CM" -n "$NS" >/dev/null 2>&1 || \
  kubectl create configmap "$STATE_CM" -n "$NS" >/dev/null 2>&1 || \
  echo "WARNING: state ConfigMap create failed (may already exist), continuing"

# --- Discover and run pending scripts ---
TOTAL=0
SKIPPED=0
RAN=0
FAILED=0

for script in "$MIGRATIONS_DIR"/[0-9]*.sh; do
  [ -f "$script" ] || continue
  TOTAL=$((TOTAL + 1))
  name="$(basename "$script")"
  # Strip extension: JSONPath dot notation cannot handle dots or hyphens in key names
  key="${name%.sh}"

  # Check current state — use bracket notation to handle hyphens in key names
  state=$(kubectl get configmap "$STATE_CM" -n "$NS" \
    -o jsonpath="{.data['${key}']}" 2>/dev/null || true)

  case "$state" in
    completed:*)
      SKIPPED=$((SKIPPED + 1))
      continue
      ;;
  esac

  # Mark as running (log after patch so the migration name appears only if patch succeeds)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  kubectl patch configmap "$STATE_CM" -n "$NS" --type=merge \
    -p="{\"data\":{\"${key}\":\"running:${NOW}\"}}"
  echo "==> Running migration: ${name}"

  # Execute and capture exit code
  set +e
  bash "$script" 2>&1
  rc=$?
  set -e

  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if [ $rc -eq 0 ]; then
    kubectl patch configmap "$STATE_CM" -n "$NS" --type=merge \
      -p="{\"data\":{\"${key}\":\"completed:${NOW}:${rc}\"}}" || \
      echo "WARNING: failed to record completed state for ${name} — will retry on next run"
    RAN=$((RAN + 1))
    echo "--- OK: ${name} ---"
  else
    kubectl patch configmap "$STATE_CM" -n "$NS" --type=merge \
      -p="{\"data\":{\"${key}\":\"failed:${NOW}:${rc}\"}}" || \
      echo "WARNING: failed to record failed state for ${name} — state remains running:"
    FAILED=$((FAILED + 1))
    echo "--- FAILED: ${name} (exit code ${rc}) ---"
    # Continue running remaining migrations even after failure — each migration
    # is idempotent and independent. Failed migrations are retried on next invocation.
  fi
  echo ""
done

echo "Migration run complete: ${TOTAL} total, ${SKIPPED} skipped, ${RAN} succeeded, ${FAILED} failed"

if [ $FAILED -gt 0 ]; then
  exit 1
fi
