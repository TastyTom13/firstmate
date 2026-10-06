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
# exactly what a PR rebased on the branch inherits, so the run limit applies to
# gating runs only. Runs from schedule, workflow_dispatch, release, deploy,
# workflow_run (such as an automatic retry helper) and every other event never
# gate a PR, so they never decide the verdict. Merge the two lists newest first,
# drop runs whose conclusion says nothing about the code (skipped, cancelled,
# neutral, stale), then take the newest remaining run of each workflow. Red when
# any of those concluded failure, timed_out, startup_failure, or
# action_required; green when every one succeeded; unknown when none remains
# (the project has no push or pull_request CI on that branch), gh is missing, or
# a gh call fails. Unknown is never reported as green.
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

runs=
for event in push pull_request; do
  part=$(gh_in_clone run list --branch "$BRANCH" --event "$event" --status completed --limit "$RUN_LIMIT" \
    --json databaseId,conclusion,url,workflowName,createdAt 2>"$err") \
    || unknown "$BRANCH" "gh run list failed: $(head -n 1 "$err")"
  runs="$runs$part"
done

# One "<conclusion>\t<id>\t<url>" row per workflow: its newest meaningful run.
latest=$(printf '%s' "$runs" | jq -rs '
  [ (add // [])
    | sort_by(.createdAt) | reverse | .[]
    | select(.conclusion as $c | ["skipped","cancelled","neutral","stale",""] | index($c) | not) ]
  | reduce .[] as $r ({}; if has($r.workflowName) then . else .[$r.workflowName] = $r end)
  | to_entries[] | .value | [.conclusion, (.databaseId | tostring), .url] | @tsv
' 2>"$err") || unknown "$BRANCH" "unreadable gh run list output: $(head -n 1 "$err")"
[ -n "$latest" ] || unknown "$BRANCH" "no completed CI runs"

green_url=
red=
while IFS=$'\t' read -r conclusion id url; do
  case "$conclusion" in
    success) [ -n "$green_url" ] || green_url=$url ;;
    *)
      jobs=$(gh_in_clone run view "$id" --json jobs 2>"$err" | jq -r '
        [ .jobs[] | select(.conclusion as $c
            | ["failure","timed_out","startup_failure","action_required"] | index($c)) | .name ]
        | join(", ")' 2>/dev/null) || jobs=
      [ -n "$jobs" ] || jobs="jobs unread"
      red="${red:+$red; }$url ($jobs)"
      ;;
  esac
done <<< "$latest"

if [ -n "$red" ]; then
  printf 'red %s %s\n' "$BRANCH" "$red"
  exit 1
fi
printf 'green %s %s\n' "$BRANCH" "$green_url"
exit 0
