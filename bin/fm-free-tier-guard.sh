#!/usr/bin/env bash
# Decide whether one brief may be dispatched to a free-tier provider.
# Usage: fm-free-tier-guard.sh --repo <name> (--brief-file <path> | --brief-stdin)
# Exit 0 prints "eligible: <repo>" only when the repo is listed in the
# allowlist AND the brief text matches no deny term; exit 1 prints
# "refused: <reason>" on stderr; exit 2 is a usage error.
# The allowlist is FM_CONFIG_OVERRIDE (else FM_HOME/config)/free-tier-repos,
# one repo name per line, blank lines and #-comments ignored. An absent,
# empty, or unreadable allowlist refuses every repo, so free-tier routing is
# off until a home opts a repo in by name.
# Deny terms are matched case-insensitively at word boundaries, with an
# optional plural suffix, so "Credentials" and "candidates" refuse while
# "bulletin" does not. Over-refusal is the intended bias: a refusal costs one
# fallback to the paid tier, a miss publishes content to a vendor.
# docs/free-tier-routing.md owns the operator procedure this guard enforces.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ALLOWLIST="$CONFIG/free-tier-repos"

# Single owner of the deny set. Each term is matched with an optional plural
# suffix; "article 9" also matches "article-9" and "article9".
DENY_WORDS='credential|secret|token|candidate|pii|bull|strategy|strategies'
DENY_PHRASE='article[^a-z0-9]*9'

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
}

REPO=''
BRIEF_FILE=''
BRIEF_STDIN=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -gt 1 ] || { echo "error: --repo requires a name" >&2; exit 2; }
      REPO=$2
      shift 2
      ;;
    --brief-file)
      [ "$#" -gt 1 ] || { echo "error: --brief-file requires a path" >&2; exit 2; }
      BRIEF_FILE=$2
      shift 2
      ;;
    --brief-stdin)
      BRIEF_STDIN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument '$1'" >&2
      exit 2
      ;;
  esac
done

if [ -z "$REPO" ] || { [ -z "$BRIEF_FILE" ] && [ "$BRIEF_STDIN" -eq 0 ]; } \
  || { [ -n "$BRIEF_FILE" ] && [ "$BRIEF_STDIN" -eq 1 ]; }; then
  echo "error: need --repo <name> and exactly one of --brief-file <path> or --brief-stdin" >&2
  exit 2
fi

if [ "$BRIEF_STDIN" -eq 1 ]; then
  BRIEF=$(cat)
elif [ -r "$BRIEF_FILE" ] && [ -f "$BRIEF_FILE" ]; then
  BRIEF=$(cat -- "$BRIEF_FILE")
else
  echo "refused: brief text is unreadable" >&2
  exit 1
fi

if [ ! -f "$ALLOWLIST" ] || [ ! -r "$ALLOWLIST" ]; then
  echo "refused: no free-tier repo allowlist at $ALLOWLIST" >&2
  exit 1
fi

if ! sed 's/#.*//' "$ALLOWLIST" | tr -d '[:blank:]' | grep -Fxq -- "$REPO"; then
  echo "refused: repo '$REPO' is not on the free-tier allowlist" >&2
  exit 1
fi

if printf '%s\n' "$BRIEF" \
  | grep -qiE "(^|[^a-z0-9])($DENY_WORDS)(s|es)?([^a-z0-9]|\$)|$DENY_PHRASE"; then
  echo "refused: brief text matches a free-tier deny term" >&2
  exit 1
fi

printf 'eligible: %s\n' "$REPO"
