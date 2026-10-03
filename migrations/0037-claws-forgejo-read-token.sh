#!/usr/bin/env bash
# Provision a read/issue-only Forgejo identity for Claws cross-repo discovery
# (#1439 / claws#3152): user `claws-reader`, org team `claws-reader`, and one
# API token stored as key `read-token` in Secret `claws-forgejo-tokens`.
#
# The persistent account is not a site admin and never receives repository write
# or organization write. Team setup uses a throwaway site-admin user created and
# deleted inside one in-pod shell, mirroring 0034. Token material never appears
# as a kubectl exec argument (#902).
set -euo pipefail

NS="default"
SECRET_NAME="claws-forgejo-tokens"

ensure_claws_rollout() {
  STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '{"spec":{"template":{"metadata":{"annotations":{"migrations.fleet-infra.bstjohn.net/0037-claws-forgejo-read-token":"%s"}}}}}\n' "$STAMP" | \
    kubectl patch statefulset claws -n "$NS" --type=merge --patch-file=/dev/stdin
}

READ_TOKEN_B64=$(kubectl get secret "$SECRET_NAME" -n "$NS" \
  -o jsonpath="{.data['read-token']}" 2>/dev/null || true)
if [ -n "$READ_TOKEN_B64" ]; then
  ensure_claws_rollout
  echo "Secret $SECRET_NAME already has read-token, ensured claws rollout"
  exit 0
fi

if ! kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME missing, will retry after 0034 has created it"
  exit 1
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
TEAM="claws-reader"
USER="claws-reader"
TOKEN_NAME="claws-reader-k8s"

# Delete-then-create so a previous half-finished run cannot collide on the token
# name. Never pass --purge: that would delete repositories and organizations too.
forgejo admin user delete --username migration-0037 >/dev/null 2>&1 || true
forgejo admin user create --username migration-0037 --fullname "migration 0037" \
  --email migration-0037@home.bstjohn.net --admin \
  --random-password --random-password-length 32 \
  --must-change-password=false >/dev/null 2>&1
trap "forgejo admin user delete --username migration-0037 >/dev/null 2>&1 || true" EXIT INT TERM

user_in_list() {
  printf "%s\n" "$1" | grep -Eq "(^|[[:space:]])$2([[:space:]]|$)"
}

USERS=$(forgejo admin user list 2>/dev/null)
if ! user_in_list "$USERS" "$USER"; then
  forgejo admin user create --username "$USER" --fullname "Claws reader" \
    --email claws-reader@home.bstjohn.net --random-password --random-password-length 32 \
    --must-change-password=false >/dev/null 2>&1
  USERS=$(forgejo admin user list 2>/dev/null)
  user_in_list "$USERS" "$USER" || { echo "$USER was still missing after create" >&2; exit 1; }
fi

ADMIN_USERS=$(forgejo admin user list --admin 2>/dev/null)
if user_in_list "$ADMIN_USERS" "$USER"; then
  echo "$USER is a site admin; refusing to mint the read token" >&2
  exit 1
fi

MTOK=$(forgejo admin user generate-access-token --username migration-0037 \
  --token-name migration-0037 --scopes write:organization,read:organization \
  --raw 2>/dev/null | tr -d "[:space:]")
[ -n "$MTOK" ] || { echo "throwaway admin token was empty" >&2; exit 1; }

payload=$(cat <<EOF
{
  "name": "$TEAM",
  "description": "Read repository code and file issues for Claws cross-repo access",
  "permission": "read",
  "includes_all_repositories": true,
  "can_create_org_repo": false,
  "units": ["repo.code", "repo.issues"],
  "units_map": {
    "repo.code": "read",
    "repo.issues": "write",
    "repo.ext_issues": "none",
    "repo.pulls": "none",
    "repo.releases": "none",
    "repo.wiki": "none",
    "repo.ext_wiki": "none",
    "repo.projects": "none",
    "repo.packages": "none",
    "repo.actions": "none"
  }
}
EOF
)

TEAMS=$(curl -sf -m 20 -H "Authorization: token $MTOK" "$API/orgs/$ORG/teams?limit=50")
team_id() {
  printf "%s" "$TEAMS" | tr "{" "\n" \
    | sed -n "s/^\"id\":\([0-9][0-9]*\),\"name\":\"$1\",.*/\1/p" | head -n1
}
TEAM_ID=$(team_id "$TEAM")

if [ -z "$TEAM_ID" ]; then
  curl -sf -m 20 -o /dev/null -X POST -H "Authorization: token $MTOK" \
    -H "Content-Type: application/json" -d "$payload" "$API/orgs/$ORG/teams"
  TEAMS=$(curl -sf -m 20 -H "Authorization: token $MTOK" "$API/orgs/$ORG/teams?limit=50")
  TEAM_ID=$(team_id "$TEAM")
  [ -n "$TEAM_ID" ] || { echo "created team id was empty" >&2; exit 1; }
else
  CODE=$(curl -s -m 20 -o /dev/null -w "%{http_code}" -X PATCH \
    -H "Authorization: token $MTOK" -H "Content-Type: application/json" \
    -d "$payload" "$API/teams/$TEAM_ID")
  case "$CODE" in
    2*) ;;
    *) echo "PATCH /teams/$TEAM_ID returned $CODE" >&2; exit 1 ;;
  esac
fi

# PUT is idempotent: an existing member also answers 204.
CODE=$(curl -s -m 20 -o /dev/null -w "%{http_code}" -X PUT \
  -H "Authorization: token $MTOK" "$API/teams/$TEAM_ID/members/$USER")
case "$CODE" in
  2*) ;;
  *) echo "PUT /teams/$TEAM_ID/members/$USER returned $CODE" >&2; exit 1 ;;
esac

set +e
READ_OUT=$(forgejo admin user generate-access-token --username "$USER" \
  --token-name "$TOKEN_NAME" --scopes read:repository,write:issue,read:user \
  --raw 2>&1)
READ_RC=$?
set -e
if [ "$READ_RC" -ne 0 ]; then
  echo "failed to mint $TOKEN_NAME for $USER; delete only that stale token and retry" >&2
  printf "%s\n" "$READ_OUT" >&2
  exit "$READ_RC"
fi
READ=$(printf "%s" "$READ_OUT" | tr -d "[:space:]")

printf "%s\n" "$READ"
')

READ_TOKEN=$(printf '%s\n' "$OUT" | sed -n '1p' | tr -d '[:space:]')

# Validate before writing. Forgejo access tokens are 40 lowercase hex characters.
if [[ ! "$READ_TOKEN" =~ ^[0-9a-f]{40}$ ]]; then
  echo "ERROR: claws-reader token is not a 40-char hex value" >&2
  exit 1
fi

READ_TOKEN_B64=$(printf '%s' "$READ_TOKEN" | base64 | tr -d '\n')
printf '{"data":{"read-token":"%s"}}\n' "$READ_TOKEN_B64" | \
  kubectl patch secret "$SECRET_NAME" -n "$NS" --type=merge --patch-file=/dev/stdin

ensure_claws_rollout

echo "Added read-token to $SECRET_NAME and triggered claws rollout"
