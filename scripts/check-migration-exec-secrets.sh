#!/usr/bin/env bash
# Guard: migration scripts must never pass secret material as `kubectl exec`
# arguments. The exec API encodes every argv as a `command=` query parameter, so
# the value appears in the apiserver requestURI and is captured by Kubernetes
# audit logging at any audit level. Feed secrets over stdin instead, or generate
# and consume them entirely inside a single in-pod `sh -c`. (#902)
#
# Usage: ./scripts/check-migration-exec-secrets.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/../migrations"
SECRET_FLAGS='--secret|--token|--password|--client-secret|--admin-token'

FAILED=0
CHECKED=0

for f in "$MIGRATIONS_DIR"/[0-9]*.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"
  # Join backslash continuations so each shell command is one logical line
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in \#*) continue ;; esac
    case "$line" in *"kubectl exec"*) ;; *) continue ;; esac
    args="${line#*" -- "}"
    [ "$args" = "$line" ] && continue
    case "$args" in "sh -c"*|"bash -c"*|"/bin/sh -c"*) continue ;; esac
    CHECKED=$((CHECKED + 1))
    if printf '%s\n' "$args" | grep -Eq -- "(^|[[:space:]])(${SECRET_FLAGS})([[:space:]]|=)"; then
      echo "❌ $name: secret-bearing flag passed as a kubectl exec argument"
      echo "     $line"
      FAILED=1
    fi
  done < <(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' "$f")
done

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "Pipe the value in and read it inside the pod instead:"
  echo "  printf '%s\\n' \"\$SECRET\" | kubectl exec -i -n ns pod -- sh -c 'IFS= read -r S; cmd --secret \"\$S\"'"
  exit 1
fi

echo "✅ No migration passes secret material as a kubectl exec argument (${CHECKED} exec call(s) inspected)"
