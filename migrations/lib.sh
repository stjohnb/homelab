# Shared helpers sourced by migration scripts. Not itself a migration — the
# runner's `[0-9]*.sh` glob never executes it directly.
#
# Guard against double-sourcing (a script could source it more than once).
if [ -n "${MIGRATIONS_LIB_SH_SOURCED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
MIGRATIONS_LIB_SH_SOURCED=1

# wait_for_pod LABEL_SELECTOR [TIMEOUT_SECONDS]
#
# Polls every 5s (namespace from ${NS:-default}) for a pod matching
# LABEL_SELECTOR that is not terminating, has status.phase Running, and has a
# Ready condition of status True. Prints the first matching pod's name to
# stdout and returns 0 on success. On timeout, prints a message to stderr and
# returns 1 — callers should treat that the same as their old "no pod found,
# will retry on next migration run" path.
#
# All progress output goes to stderr so callers can safely capture stdout.
wait_for_pod() {
  local selector="$1"
  local timeout="${2:-120}"
  local ns="${NS:-default}"
  local deadline=$((SECONDS + timeout))
  local pod=""

  while [ "$SECONDS" -lt "$deadline" ]; do
    pod=$(kubectl get pod -n "$ns" -l "$selector" -o json 2>/dev/null | jq -r '
      [.items[] | select(.metadata.deletionTimestamp == null)
        | select(.status.phase == "Running")
        | select([.status.conditions[]? | select(.type == "Ready" and .status == "True")] | length > 0)
      ] | .[0].metadata.name // empty
    ')
    if [ -n "$pod" ]; then
      printf '%s\n' "$pod"
      return 0
    fi
    echo "Waiting for a Ready pod matching '${selector}' in ${ns}..." >&2
    sleep 5
  done

  echo "No Ready pod matching '${selector}' in ${ns} after ${timeout}s, will retry on next migration run" >&2
  return 1
}
