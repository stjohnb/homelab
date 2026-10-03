#!/usr/bin/env bash
# Runs numbered migration scripts from a migrations/ directory, tracking execution
# state in a Kubernetes ConfigMap. Completed scripts are never re-run; failed
# scripts are retried on the next invocation.
#
# Each script runs under a per-script `timeout`, capped at
# DEFAULT_MIGRATION_TIMEOUT seconds unless it declares a longer or shorter
# budget with a `# migration: timeout <seconds>` marker line in its first 20
# lines (same convention as `# migration: repeatable`). This keeps a single
# hung script from consuming the whole Job activeDeadlineSeconds. The `timeout`
# on this image (alpine/k8s, busybox coreutils) reports a killed command as rc
# 124, 137 or 143 depending on signal timing — all three are treated as a
# timeout here, not a script failure.
#
# Scripts that need to wait on another pod becoming Ready (e.g. a dependency
# behind a `Recreate` rollout) should `source lib.sh` and call `wait_for_pod`
# rather than polling `kubectl get pod` themselves.
#
# Usage: run-migrations.sh [MIGRATIONS_DIR]
#   MIGRATIONS_DIR defaults to migrations/ relative to this script.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MIGRATIONS_DIR="${1:-${SCRIPT_DIR}/migrations}"
STATE_CM="migration-state"
NS="default"
DEFAULT_MIGRATION_TIMEOUT=600

# Ensure state ConfigMap exists
kubectl get configmap "$STATE_CM" -n "$NS" >/dev/null 2>&1 || \
  kubectl create configmap "$STATE_CM" -n "$NS" >/dev/null 2>&1 || \
  echo "WARNING: state ConfigMap create failed (may already exist), continuing"

# --- Discover and run pending scripts ---
TOTAL=0
SKIPPED=0
RAN=0
FAILED=0
FAILED_NAMES=()

for script in "$MIGRATIONS_DIR"/[0-9]*.sh; do
  [ -f "$script" ] || continue
  TOTAL=$((TOTAL + 1))
  name="$(basename "$script")"
  # Strip extension: JSONPath dot notation cannot handle dots or hyphens in key names
  key="${name%.sh}"

  # Check current state — use bracket notation to handle hyphens in key names
  state=$(kubectl get configmap "$STATE_CM" -n "$NS" \
    -o jsonpath="{.data['${key}']}" 2>/dev/null || true)

  # A script carrying the marker line `# migration: repeatable` in its first 20
  # lines is never skipped. State is keyed by *filename*, so editing an
  # already-`completed:` script is otherwise a silent no-op: #963 was exactly
  # that — a new key appended to 0004's KEYS array was never generated, and
  # 0021 failed every reconcile for want of it. Only mark a script repeatable
  # if it is a pure "ensure these values exist" reconciler that short-circuits
  # on every item it has already done. Destructive or one-way migrations
  # (0006, 0012) must stay one-shot.
  repeatable=false
  if head -20 "$script" | grep -q '^# migration: repeatable$'; then
    repeatable=true
  fi

  # Optional `# migration: timeout <seconds>` marker overrides the per-script
  # cap. Falls back to the default (with a warning) if the value present isn't
  # a positive integer.
  budget="$DEFAULT_MIGRATION_TIMEOUT"
  marker=$(head -20 "$script" | grep -m1 '^# migration: timeout ' || true)
  if [ -n "$marker" ]; then
    candidate="${marker#\# migration: timeout }"
    if [[ "$candidate" =~ ^[1-9][0-9]*$ ]]; then
      budget="$candidate"
    else
      echo "WARNING: ${name} has an invalid '# migration: timeout' marker (${candidate}), using default ${DEFAULT_MIGRATION_TIMEOUT}s"
    fi
  fi

  case "$state" in
    completed:*)
      if [ "$repeatable" = false ]; then
        SKIPPED=$((SKIPPED + 1))
        continue
      fi
      ;;
  esac

  # Mark as running (log after patch so the migration name appears only if patch succeeds)
  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  kubectl patch configmap "$STATE_CM" -n "$NS" --type=merge \
    -p="{\"data\":{\"${key}\":\"running:${NOW}\"}}"
  echo "==> Running migration: ${name}"

  # Execute under a per-script cap and capture exit code. Positional busybox
  # `timeout` form: SIGTERM at ${budget}s, SIGKILL 10s later if still running.
  set +e
  timeout -k 10 "$budget" bash "$script" 2>&1
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
    case "$rc" in
      124|137|143) reason="timed out after ${budget}s" ;;
      *) reason="exit code ${rc}" ;;
    esac
    kubectl patch configmap "$STATE_CM" -n "$NS" --type=merge \
      -p="{\"data\":{\"${key}\":\"failed:${NOW}:${rc}\"}}" || \
      echo "WARNING: failed to record failed state for ${name} — state remains running:"
    FAILED=$((FAILED + 1))
    FAILED_NAMES+=("${name}: ${reason}")
    echo "--- FAILED: ${name} (${reason}) ---"
    # Continue running remaining migrations even after failure — each migration
    # is idempotent and independent. Failed migrations are retried on next invocation.
  fi
  echo ""
done

SUMMARY="Migration run complete: ${TOTAL} total, ${SKIPPED} skipped, ${RAN} succeeded, ${FAILED} failed"
if [ ${#FAILED_NAMES[@]} -gt 0 ]; then
  joined=$(IFS=', '; echo "${FAILED_NAMES[*]}")
  SUMMARY="${SUMMARY} (${joined})"
fi
echo "$SUMMARY"

if [ $FAILED -gt 0 ]; then
  exit 1
fi
