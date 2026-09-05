#!/usr/bin/env bash
# Guard: every Secret a migration reads with `kubectl get secret` must appear in a
# `resourceNames` list on a secrets rule with verb `get` in migrations/rbac.yaml.
#
# Why: migrations use `kubectl get secret X >/dev/null 2>&1` as their idempotency
# guard and branch only on exit status. RBAC denial returns Forbidden (non-zero),
# not NotFound, so a missing `get` grant makes the guard permanently report
# "does not exist". The script then re-runs `kubectl create secret`, which fails
# AlreadyExists under `set -e` — failing the Job on every 1m Flux reconcile with
# no in-cluster remedy short of hand-editing the migration-state ConfigMap. (#923)
#
# Usage: ./scripts/check-migration-secret-rbac.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATIONS_DIR="$SCRIPT_DIR/../migrations"
RBAC="$MIGRATIONS_DIR/rbac.yaml"

# A rule with no resourceNames is namespace-wide; emit "*" for it.
mapfile -t GRANTED < <(yq eval-all '
  select(.kind == "Role" and .metadata.name == "migration-runner")
  | .rules[]
  | select(.resources | contains(["secrets"]))
  | select(.verbs | contains(["get"]))
  | (.resourceNames // ["*"])[]
' "$RBAC")

granted() {
  local want="$1" g
  for g in "${GRANTED[@]}"; do
    [ "$g" = "*" ] && return 0
    [ "$g" = "$want" ] && return 0
  done
  return 1
}

FAILED=0
CHECKED=0

for f in "$MIGRATIONS_DIR"/[0-9]*.sh; do
  [ -f "$f" ] || continue
  name="$(basename "$f")"

  declare -A VARS=()
  # Join backslash continuations so each shell command is one logical line
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in \#*|"") continue ;; esac

    # Track simple literal assignments so "$SECRET_NAME" can be resolved
    if [[ "$trimmed" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\"?([A-Za-z0-9._-]+)\"?$ ]]; then
      VARS["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
      continue
    fi

    [[ "$trimmed" == *"kubectl get secret"* ]] || continue

    arg="${trimmed#*kubectl get secret }"
    arg="${arg%% *}"
    arg="${arg//\"/}"

    if [[ "$arg" == \$* ]]; then
      var="${arg#\$}"; var="${var#\{}"; var="${var%\}}"
      resolved="${VARS[$var]:-}"
    else
      resolved="$arg"
    fi

    if [ -z "$resolved" ]; then
      echo "❌ $name: cannot resolve the Secret name in: $trimmed"
      echo "     Use a literal name, or a top-level VAR=\"literal\" assignment."
      FAILED=1
      continue
    fi

    CHECKED=$((CHECKED + 1))
    if ! granted "$resolved"; then
      echo "❌ $name: reads Secret '$resolved' but migration-runner has no 'get' grant for it"
      FAILED=1
    fi
  done < <(sed -e :a -e '/\\$/N; s/\\\n/ /; ta' "$f")
  unset VARS
done

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "Add the name to a resourceNames list with verb 'get' in migrations/rbac.yaml."
  echo "Without it the script's existence check is silently inoperative."
  exit 1
fi

echo "✅ Every Secret read by a migration has a matching 'get' grant (${CHECKED} read(s) inspected)"
