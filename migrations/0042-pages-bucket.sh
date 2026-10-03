#!/usr/bin/env bash
# Create the Garage `pages` bucket (website mode, 20 GiB quota) and the
# `pages-publisher` key, and store the key in Secret `pages-s3-credentials`.
# See docs/pages.md.
#
# Rotation: delete Secret pages-s3-credentials AND the `0042-pages-bucket` key in
# the migration-state ConfigMap. The next run deletes every existing
# pages-publisher key and mints a fresh one; the bucket and its content survive.
#
# All calls go to Garage's admin API over HTTP from this pod. The admin token is
# only ever a curl header, never a `kubectl exec` argv (#902).
set -euo pipefail

NS="default"
SECRET_NAME="pages-s3-credentials"
ADMIN_SECRET="garage-secrets"
ADMIN="http://garage.default.svc.cluster.local:3903"
S3_INTERNAL="http://garage.default.svc.cluster.local:3900"
QUOTA_BYTES=21474836480 # 20 GiB

# Idempotency guard. The `get` grant in migrations/rbac.yaml is load-bearing (#923).
if kubectl get secret "$SECRET_NAME" -n "$NS" >/dev/null 2>&1; then
  echo "Secret $SECRET_NAME already exists, skipping"
  exit 0
fi

source "$(dirname "$0")/lib.sh"
wait_for_pod app=garage 120 >/dev/null || exit 1

TOKEN=$(kubectl get secret "$ADMIN_SECRET" -n "$NS" \
  -o jsonpath='{.data.GARAGE_ADMIN_TOKEN}' | base64 -d)
if [ -z "$TOKEN" ]; then
  echo "ERROR: $ADMIN_SECRET has no GARAGE_ADMIN_TOKEN" >&2
  exit 1
fi

api() {
  # api METHOD PATH [JSON_BODY]
  if [ $# -ge 3 ]; then
    curl -sf -m 20 -X "$1" -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" -d "$3" "$ADMIN$2"
  else
    curl -sf -m 20 -X "$1" -H "Authorization: Bearer $TOKEN" "$ADMIN$2"
  fi
}

# Bucket: reuse if it exists (a rotation rerun must keep published content).
BUCKET_ID=$(api GET "/v2/GetBucketInfo?globalAlias=pages" 2>/dev/null | jq -r '.id // empty' || true)
if [ -z "$BUCKET_ID" ]; then
  BUCKET_ID=$(api POST /v2/CreateBucket '{"globalAlias":"pages"}' | jq -r '.id')
  echo "Created bucket pages"
else
  echo "Bucket pages already exists"
fi
[ -n "$BUCKET_ID" ] && [ "$BUCKET_ID" != "null" ] || { echo "ERROR: no bucket id" >&2; exit 1; }

# Key: delete-then-create so a rerun always mints a fresh secret. This is the
# rotation trigger — the old key stops working immediately.
OLD_KEYS=$(api GET /v2/ListKeys | jq -r '.[] | select(.name == "pages-publisher") | .id')
for old in $OLD_KEYS; do
  api POST "/v2/DeleteKey?id=$old" >/dev/null
  echo "Deleted old pages-publisher key"
done
KEY_JSON=$(api POST /v2/CreateKey '{"name":"pages-publisher"}')
ACCESS_KEY_ID=$(printf '%s' "$KEY_JSON" | jq -r '.accessKeyId')
SECRET_ACCESS_KEY=$(printf '%s' "$KEY_JSON" | jq -r '.secretAccessKey')
unset KEY_JSON
if [ -z "$ACCESS_KEY_ID" ] || [ "$ACCESS_KEY_ID" = "null" ] \
  || [ -z "$SECRET_ACCESS_KEY" ] || [ "$SECRET_ACCESS_KEY" = "null" ]; then
  echo "ERROR: CreateKey returned no credentials" >&2
  exit 1
fi

api POST /v2/AllowBucketKey \
  "{\"bucketId\":\"$BUCKET_ID\",\"accessKeyId\":\"$ACCESS_KEY_ID\",\"permissions\":{\"read\":true,\"write\":true,\"owner\":true}}" \
  >/dev/null

api POST "/v2/UpdateBucket?id=$BUCKET_ID" \
  "{\"websiteAccess\":{\"enabled\":true,\"indexDocument\":\"index.html\",\"errorDocument\":null},\"quotas\":{\"maxSize\":$QUOTA_BYTES,\"maxObjects\":null}}" \
  >/dev/null
echo "Bucket pages: website mode on, quota $QUOTA_BYTES bytes"

kubectl create secret generic "$SECRET_NAME" -n "$NS" \
  --from-literal=access-key-id="$ACCESS_KEY_ID" \
  --from-literal=secret-access-key="$SECRET_ACCESS_KEY" \
  --from-literal=endpoint=https://s3.home.bstjohn.net \
  --from-literal=bucket=pages
echo "Created $SECRET_NAME"

# Best effort: a root index.html explaining the path convention. Its absence
# must never fail the migration.
if command -v aws >/dev/null 2>&1; then
  cat > /tmp/index.html <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>pages.home.bstjohn.net</title></head>
<body>
<h1>pages.home.bstjohn.net</h1>
<p>Private CI previews and rendered docs. There is no directory listing.</p>
<p>Content lives at <code>/&lt;repo&gt;/&lt;kind&gt;/&lt;ref&gt;/&lt;sha8&gt;/</code>, where
<code>&lt;kind&gt;</code> is <code>pr</code>, <code>issue</code> or <code>docs</code>.
See <code>docs/pages.md</code> in fleet-infra.</p>
</body>
</html>
HTML
  export AWS_CONFIG_FILE=/tmp/aws-config
  aws configure set default.s3.addressing_style path
  if AWS_ACCESS_KEY_ID="$ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$SECRET_ACCESS_KEY" \
    AWS_DEFAULT_REGION=garage \
    aws --endpoint-url "$S3_INTERNAL" s3 cp /tmp/index.html s3://pages/index.html \
    --content-type text/html; then
    echo "Uploaded root index.html"
  else
    echo "WARNING: root index.html upload failed, continuing"
  fi
else
  echo "aws CLI not in the migration image; skipping root index.html upload"
fi
