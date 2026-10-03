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
# It also checks the reverse direction: every Secret name granted `get` in
# rbac.yaml must be mentioned by at least one migration script. A grant whose
# migration has been deleted silently widens the migration-runner SA's blast
# radius — the SA already holds namespace-wide `secrets: create` and
# `pods/exec: create`, so every named Secret it can read is real exposure.
# (#1161: `vaultwarden-admin` outlived migration 0014 by four months.)
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

# Reverse direction: no granted Secret name may be orphaned. A literal
# substring match over every migration script is intentionally loose — it can
# only produce false negatives (a stale grant that happens to share a prefix
# with a live one), never a false positive that blocks a legitimate grant.
ORPHANS=0
for g in "${GRANTED[@]}"; do
  [ "$g" = "*" ] && continue
  if ! grep -qF -- "$g" "$MIGRATIONS_DIR"/*.sh; then
    echo "❌ rbac.yaml grants 'get' on Secret '$g' but no migration references it"
    ORPHANS=$((ORPHANS + 1))
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo ""
  if [ "$ORPHANS" -ne 0 ]; then
    echo "Remove orphaned resourceNames entries from migrations/rbac.yaml — a grant"
    echo "whose migration is gone only widens the migration-runner SA's blast radius."
  fi
  echo "Add any missing name to a resourceNames list with verb 'get' in migrations/rbac.yaml."
  echo "Without it the script's existence check is silently inoperative."
  exit 1
fi

echo "✅ Every Secret read by a migration has a matching 'get' grant (${CHECKED} read(s) inspected); no orphaned grants (${#GRANTED[@]} grant(s) inspected)"
