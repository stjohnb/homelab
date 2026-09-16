#!/usr/bin/env bash
# Check that every subdirectory containing a kustomization.yaml is listed
# in its "governing" kustomization.yaml — the nearest ancestor directory
# that also contains a kustomization.yaml.
#
# This allows multi-level structures where a directory manages its own
# subdirectories (e.g., monitoring/kustomization.yaml manages
# monitoring/grafana-github-alerts) without requiring every nested entry
# to appear in the root kustomization.yaml.
#
# NOTE: This script only checks one direction — directories that exist on
# disk but are missing from their parent kustomization.yaml. It does NOT
# check for stale entries in kustomization.yaml that point to nonexistent
# directories (the "phantom entries" direction). A dangling reference left
# after deleting a service directory will not be caught here; however,
# `kustomize build` in CI will still fail on such a reference.
#
# Usage: scripts/check-completeness.sh [dir ...]
#   Defaults to: apps migrations clusters/my-cluster/infrastructure clusters/my-cluster/config
#
# Requires: yq (https://github.com/mikefarah/yq)

set -uo pipefail

if [ $# -gt 0 ]; then
  DIRS=("$@")
else
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mapfile -t DIRS < <("$SCRIPT_DIR/overlays.sh" | cut -d: -f1)
  if [ "${#DIRS[@]}" -eq 0 ]; then
    echo "❌ scripts/overlays.sh produced no overlays"
    exit 1
  fi
fi

FAILED=0

# nearest_kustom_ancestor <dir> <base_dir>
# Prints the nearest ancestor of <dir> (exclusive) that contains kustomization.yaml,
# stopping at <base_dir>. Returns non-zero if none found within base_dir.
nearest_kustom_ancestor() {
  local dir="$1"
  local base="$2"
  local current
  current=$(dirname "$dir")
  while [ "$current" != "$base" ] && [ "$current" != "." ] && [ "$current" != "/" ]; do
    if [ -f "$current/kustomization.yaml" ]; then
      echo "$current"
      return 0
    fi
    current=$(dirname "$current")
  done
  # base_dir itself
  if [ -f "$base/kustomization.yaml" ]; then
    echo "$base"
    return 0
  fi
  return 1
}

for base_dir in "${DIRS[@]}"; do
  echo "Checking $base_dir/kustomization.yaml..."
  dir_failed_before=$FAILED

  # For every directory with a kustomization.yaml under base_dir (excluding base_dir),
  # check that it is listed in its nearest ancestor kustomization.yaml.
  while IFS= read -r kustom_dir <&3; do
    [ "$kustom_dir" = "$base_dir" ] && continue

    ancestor=$(nearest_kustom_ancestor "$kustom_dir" "$base_dir")
    relative="${kustom_dir#"$ancestor"/}"

    resources=$(yq '.resources[]' "$ancestor/kustomization.yaml" 2>/dev/null || true)
    if ! echo "$resources" | grep -qxF "$relative"; then
      echo "❌ Directory with kustomization.yaml NOT listed in $ancestor/kustomization.yaml:"
      echo "  - $relative"
      FAILED=1
    fi
  done 3< <(find "$base_dir" -name kustomization.yaml -exec dirname {} \; | sort)

  if [ "$FAILED" -eq "$dir_failed_before" ]; then
    echo "✅ $base_dir OK"
  fi
done

if [ $FAILED -ne 0 ]; then
  echo ""
  echo "❌ Kustomization completeness check failed"
  echo "Ensure every directory with a kustomization.yaml is listed in its parent kustomization.yaml"
  exit 1
fi

echo ""
echo "✅ Kustomization completeness check passed"
