#!/usr/bin/env bash
# Drop the leftover pgvecto.rs (`vectors`) extension and schema from the immich
# database (#996). Immich reindexes its CLIP and face embeddings onto VectorChord
# on the first start against the shared instance; once `vchord` is installed the
# old `vectors` objects are dead weight, and they must be gone before the shared
# image drops the pgvecto.rs layer in the next PR.
#
# One-shot, and deliberately gated: if the reindex has not finished the script
# exits non-zero and is retried on the next reconcile rather than removing an
# extension the database still depends on.
set -euo pipefail

NS="default"

NEW_POD=$(kubectl get pod -n "$NS" -l app=postgres \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$NEW_POD" ]; then
  echo "No running postgres pod yet, will retry on next migration run"
  exit 1
fi

# Inside the pod use TCP + password rather than the unix socket: the immich-app
# entrypoint rewrites postgresql.conf, so local `trust` cannot be assumed.
#
# Neither DROP carries CASCADE. If any object still depends on `vectors` the
# statement must fail loudly under ON_ERROR_STOP and be retried once the reindex
# has actually finished — silently dropping dependent columns would destroy the
# embeddings this migration exists to preserve.
kubectl exec -n "$NS" "$NEW_POD" -- sh -c '
  set -eu
  export PGPASSWORD="$POSTGRES_PASSWORD"
  P="psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U $POSTGRES_USER -d immich -tAc"
  if [ "$($P "select count(*) from pg_extension where extname='"'"'vchord'"'"'")" != 1 ]; then
    echo "VectorChord reindex not complete yet, will retry on next migration run"
    exit 1
  fi
  $P "drop extension if exists vectors"
  $P "drop schema if exists vectors"
'

echo "Dropped the pgvecto.rs vectors extension and schema from the immich database"
