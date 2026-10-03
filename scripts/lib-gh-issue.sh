# shellcheck shell=bash
# Shared GitHub-issue find / upsert / close helpers for the workflow that
# auto-files one tracking issue per exact title (trivyignore-expiry.yml).
# Single source of truth for the dedup key.
#
# Main-branch build failures are NOT handled here: Claws' main-build-monitor
# files and bumps `Build failure: <workflow>` issues centrally.
#
# All functions require REPO set in the environment and GH_TOKEN available to gh.

# Echo the number of the first open issue whose title exactly equals $1,
# or nothing if none exists.
gh_issue_find() {
  gh issue list --repo "${REPO}" --state open --limit 100 --json number,title \
    | jq -r --arg t "$1" '[.[] | select(.title == $t)] | .[0].number // empty'
}

# Create the issue if none is open with this title, else replace its body.
# Regenerate-the-body semantics (drift reports): NO occurrence counters.
# Usage: gh_issue_upsert <title> <body> [extra gh issue create args...]
gh_issue_upsert() {
  local title="$1" body="$2" n
  shift 2
  n=$(gh_issue_find "${title}")
  if [ -n "${n}" ]; then
    gh issue edit "${n}" --repo "${REPO}" --body "${body}"
  else
    gh issue create --repo "${REPO}" --title "${title}" --body "${body}" "$@"
  fi
}

# Close the open issue titled $1 (if any), leaving comment $2.
gh_issue_close() {
  local n
  n=$(gh_issue_find "$1")
  if [ -n "${n}" ]; then
    gh issue close "${n}" --repo "${REPO}" --comment "$2"
  fi
}
