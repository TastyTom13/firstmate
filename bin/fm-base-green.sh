#!/usr/bin/env bash
# fm-base-green.sh - read-only CI verdict for a project's base branch.
#
# Usage: fm-base-green.sh <project> [<branch>]
#
# <project> is a clone under this home's projects dir ($FM_HOME/projects, or
# $FM_PROJECTS_OVERRIDE). <branch> defaults to the clone's origin HEAD branch
# (the forge's default branch); pass an integration branch to check that
# instead. The script never fetches, writes, or reruns anything.
#
# Prints exactly one line and exits with the matching status:
#   green <branch> <run-url>                                  exit 0
#   red <branch> <run-url> (<failing job>, ...)[; <run-url> (...)]  exit 1
#   unknown <branch|-> <reason>                               exit 2
#   usage error                                               exit 64
#
# The verdict: list the branch's completed runs (`gh run list --status
# completed`) once for event push and once for event pull_request, which is
# exactly what a PR rebased on the branch inherits, so other events never use up
# those two lists' run limit. Runs from schedule, workflow_dispatch, release, deploy,
# workflow_run (such as an automatic retry helper) and every other event never
# gate a PR, so none of them can turn the verdict red. Merge the two lists newest
# first, drop runs whose conclusion says nothing about the code (skipped,
# cancelled, neutral, stale), then take the newest remaining run of each
# workflow.
#
# Staleness: one case lets a schedule run count. A workflow's failed gating run
# is replaced by a successful run only when all of these hold: its head commit is
# not the branch head (`gh api .../branches`); the same workflow's newest
# meaningful completed schedule run on the branch head is newer and succeeded;
# and every job that failed in the gating run succeeded in that schedule run.
# Otherwise, including when any of this cannot be read, the failed gating run
# stands. A successful gating run is never replaced.
#
# Red when any workflow's failed run (failure, timed_out, startup_failure, or
# action_required) was not replaced; green when every workflow's run succeeded or
# was replaced; unknown when no gating run remains (the project has no push or
# pull_request CI on that branch), gh is missing, or listing the gating runs
# fails. Unknown is never reported as green, and green always comes from a run
# that succeeded.
#
# Consumers: firstmate at ship intake (AGENTS.md section 7: a red base is a
# blocker fixed first), and bin/fm-bootstrap.sh's network phase, which lists
# every registered project's verdict in the session-start digest.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
RUN_LIMIT=${FM_BASE_GREEN_RUN_LIMIT:-50}

usage() {
  echo "usage: fm-base-green.sh <project> [<branch>]" >&2
  exit 64
}

[ $# -ge 1 ] && [ $# -le 2 ] && [ -n "$1" ] || usage
PROJECT=$1
CLONE="$PROJECTS/$PROJECT"
BRANCH=${2:-}

unknown() {  # <branch|-> <reason>
  printf 'unknown %s %s\n' "$1" "$2"
  exit 2
}

[ -d "$CLONE" ] || unknown "${BRANCH:--}" "no clone at $CLONE"
if [ -z "$BRANCH" ]; then
  BRANCH=$(git -C "$CLONE" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null) || BRANCH=
  BRANCH=${BRANCH#origin/}
  [ -n "$BRANCH" ] || unknown - "no origin HEAD in $CLONE; pass the branch"
fi
command -v gh >/dev/null 2>&1 || unknown "$BRANCH" "gh unavailable"
command -v jq >/dev/null 2>&1 || unknown "$BRANCH" "jq unavailable"

# gh resolves the repository from the clone's remotes, so run it there.
gh_in_clone() {
  (cd "$CLONE" && gh "$@")
}

err=$(mktemp "${TMPDIR:-/tmp}/fm-base-green.XXXXXX") || unknown "$BRANCH" "mktemp failed"
trap 'rm -f "$err"' EXIT

FIELDS=databaseId,conclusion,url,workflowName,workflowDatabaseId,createdAt,headSha
runs=
for event in push pull_request; do
  part=$(gh_in_clone run list --branch "$BRANCH" --event "$event" --status completed --limit "$RUN_LIMIT" \
    --json "$FIELDS" 2>"$err") \
    || unknown "$BRANCH" "gh run list failed: $(head -n 1 "$err")"
  runs="$runs$part"
done

# The newest meaningful run of each workflow, as a JSON object keyed by name.
# shellcheck disable=SC2016 # $c and $r are jq variables, not shell ones.
NEWEST='
  [ (add // [])
    | sort_by(.createdAt) | reverse | .[]
    | select(.conclusion as $c | ["skipped","cancelled","neutral","stale",""] | index($c) | not) ]
  | reduce .[] as $r ({}; if has($r.workflowName) then . else .[$r.workflowName] = $r end)'
gating=$(printf '%s' "$runs" | jq -cs "$NEWEST" 2>"$err") \
  || unknown "$BRANCH" "unreadable gh run list output: $(head -n 1 "$err")"
[ "$gating" != "{}" ] || unknown "$BRANCH" "no completed CI runs"

# shellcheck disable=SC2016 # $c is a jq variable, not a shell one.
FAILED_JOBS='[ .jobs[] | select(.conclusion as $c
  | ["failure","timed_out","startup_failure","action_required"] | index($c)) | .name ]'

# Prints the URL of the head schedule run that replaces a failed gating run.
head_pass_url() {  # <gating run JSON> <its failed job names JSON>
  local head stale list run jobs
  [ "$2" != '[]' ] || return 1
  head=$(gh_in_clone api "repos/{owner}/{repo}/branches/$BRANCH" --jq .commit.sha 2>"$err") && [ -n "$head" ] || return 1
  stale=$(printf '%s' "$1" | jq -r --arg head "$head" \
    'select(.headSha != $head) | "\(.workflowDatabaseId) \(.createdAt)"') && [ -n "$stale" ] || return 1
  list=$(gh_in_clone run list --branch "$BRANCH" --workflow "${stale%% *}" --event schedule --commit "$head" \
    --status completed --limit "$RUN_LIMIT" --json "$FIELDS" 2>"$err") || return 1
  run=$(printf '%s' "$list" | jq -rs --arg since "${stale#* }" "($NEWEST)"' | .[]
    | select(.conclusion == "success" and .createdAt > $since) | "\(.databaseId) \(.url)"') && [ -n "$run" ] || return 1
  jobs=$(gh_in_clone run view "${run%% *}" --json jobs 2>"$err") || return 1
  printf '%s' "$jobs" | jq -es --argjson failed "$2" '.[0].jobs as $jobs
    | all($failed[]; . as $name | [ $jobs[] | select(.name == $name) | .conclusion ]
        | length > 0 and all(. == "success"))' >/dev/null 2>&1 || return 1
  printf '%s\n' "${run#* }"
}

green_url=
red=
while IFS= read -r run; do
  IFS=$'\t' read -r conclusion id url <<< "$(printf '%s' "$run" | jq -r '[.conclusion, .databaseId, .url] | @tsv')"
  case "$conclusion" in
    success) ;;
    *)
      failed=$(gh_in_clone run view "$id" --json jobs 2>"$err" | jq -c "$FAILED_JOBS" 2>/dev/null) && [ -n "$failed" ] \
        || failed='[]'
      if pass_url=$(head_pass_url "$run" "$failed"); then
        url=$pass_url
      else
        names=$(printf '%s' "$failed" | jq -r 'join(", ")')
        red="${red:+$red; }$url (${names:-jobs unread})"
        continue
      fi
      ;;
  esac
  [ -n "$green_url" ] || green_url=$url
done <<< "$(printf '%s' "$gating" | jq -c '.[]')"

if [ -n "$red" ]; then
  printf 'red %s %s\n' "$BRANCH" "$red"
  exit 1
fi
printf 'green %s %s\n' "$BRANCH" "$green_url"
exit 0
