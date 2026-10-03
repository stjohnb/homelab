#!/usr/bin/env bash
# Provision Claws' two Forgejo identities as gitops (#1289): user `clawsstjohn`
# in the org team `claws-bot` (write), user `claws-admin` in `Owners`, plus one
# API token each, in Secret `claws-forgejo-tokens`.
#
# Neither account is a site admin. Forgejo has no admin CLI for teams, and a
# migration holds no org-owner credential, so team membership is set through the
# API using a THROWAWAY site-admin user `migration-0034` that is deleted in the
# same shell (an EXIT trap covers the failure paths). Deleting the user drops its
# token, so no owner-level credential outlives this script. 0032 took the other
# route — a permanently site-admin bot — which claws#2965 rules out here.
#
# Everything runs inside one in-pod `sh -c`: no token is ever a kubectl argv (#902).
set -euo pipefail

NS="default"
SECRET_NAME="claws-forgejo-tokens"

# Idempotency guard. The `get` grant in migrations/rbac.yaml is load-bearing —
# without it this reports "missing" forever and re-runs `create` (#923).
if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

POD=$(kubectl get pod -n "$NS" -l app=forgejo \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD" ]; then
  echo "No forgejo pod found, will retry on next migration run"
  exit 1
fi

# The in-pod body is single-quoted, so it must contain no single quote at all,
# and it runs under the image's bare `sh` — no [[ ]], no arrays, no `local`.
OUT=$(kubectl exec -n "$NS" "$POD" -- sh -c '
set -eu
API="http://127.0.0.1:3000/api/v1"
ORG="St-John-Software"

# Both accounts may already exist (clawsstjohn since 2026-08-28, claws-admin
# since 2026-09-10) — the `|| true` makes this a no-op there and a real
# bootstrap on a fresh cluster. NO --admin on either.
forgejo admin user create --username clawsstjohn --fullname "Claws" \
  --email claws@bstjohn.net --random-password --random-password-length 32 \
  --must-change-password=false >/dev/null 2>&1 || true
forgejo admin user create --username claws-admin --fullname "Claws admin" \
  --email claws-admin@home.bstjohn.net --random-password --random-password-length 32 \
  --must-change-password=false >/dev/null 2>&1 || true

# Delete-then-create so a previous half-finished run cannot collide on the token
# name (Forgejo token names are unique per user and there is no delete-token CLI).
# Never pass --purge: that would delete repositories and organizations too.
forgejo admin user delete --username migration-0034 >/dev/null 2>&1 || true
forgejo admin user create --username migration-0034 --fullname "migration 0034" \
  --email migration-0034@home.bstjohn.net --admin \
  --random-password --random-password-length 32 \
  --must-change-password=false >/dev/null 2>&1
trap "forgejo admin user delete --username migration-0034 >/dev/null 2>&1 || true" EXIT INT TERM

MTOK=$(forgejo admin user generate-access-token --username migration-0034 \
  --token-name migration-0034 --scopes write:organization,read:organization \
  --raw 2>/dev/null | tr -d "[:space:]")
[ -n "$MTOK" ] || { echo "throwaway admin token was empty" >&2; exit 1; }

TEAMS=$(curl -sf -m 20 -H "Authorization: token $MTOK" "$API/orgs/$ORG/teams?limit=50")

# No jq and no python3 in this image. The teams array is flat (organization is
# null), so each object begins "id":N,"name":"X", once brace-split — a name
# match is unambiguous.
team_id() {
  printf "%s" "$TEAMS" | tr "{" "\n" \
    | sed -n "s/^\"id\":\([0-9][0-9]*\),\"name\":\"$1\",.*/\1/p" | head -n1
}
BOT_ID=$(team_id claws-bot)
OWN_ID=$(team_id Owners)
[ -n "$BOT_ID" ] || { echo "org team claws-bot not found" >&2; exit 1; }
[ -n "$OWN_ID" ] || { echo "org team Owners not found" >&2; exit 1; }

# PUT is idempotent: an existing member also answers 204.
for PAIR in "$BOT_ID clawsstjohn" "$OWN_ID claws-admin"; do
  set -- $PAIR
  CODE=$(curl -s -m 20 -o /dev/null -w "%{http_code}" -X PUT \
    -H "Authorization: token $MTOK" "$API/teams/$1/members/$2")
  case "$CODE" in
    2*) ;;
    *) echo "PUT /teams/$1/members/$2 returned $CODE" >&2; exit 1 ;;
  esac
done

# claws-k8s / claws-admin-k8s are new names: claws-service already exists on
# clawsstjohn (host-side) and Forgejo refuses a duplicate token name per user.
SVC=$(forgejo admin user generate-access-token --username clawsstjohn \
  --token-name claws-k8s --scopes write:repository,write:issue,read:user \
  --raw 2>/dev/null | tr -d "[:space:]")
ADM=$(forgejo admin user generate-access-token --username claws-admin \
  --token-name claws-admin-k8s --scopes write:repository,write:organization \
  --raw 2>/dev/null | tr -d "[:space:]")

printf "%s\n%s\n" "$SVC" "$ADM"
')

SVC_TOKEN=$(printf '%s\n' "$OUT" | sed -n '1p' | tr -d '[:space:]')
ADM_TOKEN=$(printf '%s\n' "$OUT" | sed -n '2p' | tr -d '[:space:]')

# Validate before writing: this migration short-circuits on "secret exists" and
# never re-runs, so a malformed capture writes a permanently broken Secret (0017).
# Forgejo access tokens are 40 lowercase hex characters.
if [[ ! "$SVC_TOKEN" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: clawsstjohn token is not a 40-char hex value" >&2
  exit 1
fi
if [[ ! "$ADM_TOKEN" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: claws-admin token is not a 40-char hex value" >&2
  exit 1
fi

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=service-token="$SVC_TOKEN" \
  --from-literal=admin-token="$ADM_TOKEN"
echo "Created $SECRET_NAME (clawsstjohn -> claws-bot, claws-admin -> Owners)"
