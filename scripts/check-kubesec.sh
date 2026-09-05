#!/usr/bin/env bash
# Security-scan every workload manifest under ./apps with kubesec and fail on a
# negative score, except for the workloads whitelisted below with justification.
#
# Usage: ./scripts/check-kubesec.sh
# Requires: kubesec, jq (both in flake.nix's `default` devShell)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.." || exit 1

echo "Running security scan..."

# Deployments allowed to have negative scores (with justification)
ALLOWED_EXCEPTIONS=(
  "./apps/servarr/transmission/deployment.yaml:Requires privileged mode for VPN functionality"
  "./apps/arpwatch/deployment.yaml:Requires hostNetwork to monitor ARP traffic on physical LAN"
  "./apps/containerd-gc/cronjob.yaml:Requires privileged access to containerd socket for image garbage collection"
  "./apps/forgejo-runner/deployment.yaml:Requires a privileged Docker-in-Docker sidecar to execute Forgejo Actions jobs"
  "./apps/forgejo-runner/deployment-ryzen.yaml:Requires a privileged Docker-in-Docker sidecar to execute Forgejo Actions jobs"
  "./apps/forgejo-runner/deployment-nas.yaml:Requires a privileged Docker-in-Docker sidecar to execute Forgejo Actions jobs"
)

# Discover workloads by CONTENT, not filename. The old
# `find ./apps -name 'deployment.yaml' -o -name 'cronjob.yaml' ...`
# matched exact filenames only, so it silently skipped all 8 suffixed
# workload files - including every Authentik Deployment (#857).
# The search root MUST be './apps' (not 'apps'): grep echoes the root
# verbatim, and ALLOWED_EXCEPTIONS above keys on './apps/...' paths.
mapfile -t WORKLOAD_FILES < <(
  grep -rlE '^kind: (Deployment|StatefulSet|DaemonSet|CronJob|Job)' ./apps --include='*.yaml' | sort
)
EXPECTED=${#WORKLOAD_FILES[@]}
echo "Discovered $EXPECTED workload files under ./apps"

if [ "$EXPECTED" -eq 0 ]; then
  echo "❌ No workload files matched - the discovery grep is broken, not the manifests"
  exit 1
fi

FAILED=0
SCANNED=0

for file in "${WORKLOAD_FILES[@]}"; do
  echo "Scanning $file..."
  RESULT=$(kubesec scan "$file" 2>&1)
  SCORE=$(echo "$RESULT" | jq -r '.[0].score // 0' 2>/dev/null)

  if ! [[ "$SCORE" =~ ^-?[0-9]+$ ]]; then
    echo "⚠️  Could not parse score from kubesec output for $file"
    echo "$RESULT"
    continue
  fi

  echo "Security score: $SCORE"
  SCANNED=$((SCANNED + 1))

  if [ "$SCORE" -lt 0 ]; then
    IS_EXCEPTION=false
    EXCEPTION_REASON=""
    for exception in "${ALLOWED_EXCEPTIONS[@]}"; do
      EXCEPTION_FILE="${exception%%:*}"
      if [ "$file" = "$EXCEPTION_FILE" ]; then
        IS_EXCEPTION=true
        EXCEPTION_REASON="${exception#*:}"
        break
      fi
    done

    if [ "$IS_EXCEPTION" = true ]; then
      echo "⚠️  Security issues found but ALLOWED (score: $SCORE)"
      echo "Reason: $EXCEPTION_REASON"
    else
      echo "❌ Critical security issues found (score: $SCORE)"
      echo "$RESULT" | jq -r '.[0].scoring.critical // empty' 2>/dev/null || echo "$RESULT"
      FAILED=1
    fi
  elif [ "$SCORE" -eq 0 ]; then
    echo "⚠️  Security warnings found (score: $SCORE)"
  else
    echo "✅ Security scan passed (score: $SCORE)"
  fi
done

echo "Scanned $SCANNED of $EXPECTED workload files"

if [ "$SCANNED" -ne "$EXPECTED" ]; then
  echo "❌ Expected $EXPECTED workload files but only scored $SCANNED"
  echo "   A file's kubesec output could not be parsed - see the ⚠️ lines above."
  FAILED=1
fi

if [ $FAILED -eq 1 ]; then
  echo "❌ Security scan failed - critical issues must be fixed"
  exit 1
fi
echo "✅ Security scan complete"
