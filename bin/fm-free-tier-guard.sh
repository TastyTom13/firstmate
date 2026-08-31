#!/usr/bin/env bash
# Decide whether one brief may be dispatched to a free-tier provider.
# Usage: fm-free-tier-guard.sh --repo <name> (--brief-file <path> | --brief-stdin)
# Exit 0 prints "eligible: <repo>" only when the repo is listed in the
# allowlist AND the brief text matches no deny term, and is the only state
# in which the free-tier profile may be selected. Exit 1 prints
# "refused: <reason>" on stderr. Exit 2 means the check did not run at all,
# which covers a usage error and --help, and is never permission to
# dispatch.
# An empty or whitespace-only brief refuses, because no text was checked.
# The allowlist is FM_CONFIG_OVERRIDE (else FM_HOME/config)/free-tier-repos,
# one repo name per line, blank lines and #-comments ignored. An absent,
# empty, or unreadable allowlist refuses every repo, so free-tier routing is
# off until a home opts a repo in by name. The repo name must equal one whole
# allowlist line, so a multi-line value can never be eligible.
# Deny terms are matched case-insensitively at word boundaries, with an
# optional plural suffix, so "Credentials" and "candidates" refuse while
# "bulletin" does not. "article 9" also matches "article-9" and "article9",
# "env" also matches ".env" and "environment", and "user data" also matches
# "userdata". Both the brief as written and a camel-hump-split copy of it are
# scanned, so "secretKey" and "dataBase" refuse too. The split also breaks the
# acronym-prefix form, so "APIKey" and "DBConnection" refuse. The scan runs under
# LC_ALL=C, so a brief that is not valid UTF-8 is compared byte by byte.
# Over-refusal is the intended bias: a refusal costs one fallback to the paid
# tier, a miss publishes content to a vendor. The exact terms in force are
# printed at the end of this help text.
# This is a mechanical backstop for obvious mis-scoping only, not a
# classifier: firstmate's own judgement at intake remains the real gate.
# docs/free-tier-routing.md owns the operator procedure this guard supports.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ALLOWLIST="$CONFIG/free-tier-repos"

# Single owner of the deny set; the header above owns the matching rules.
DENY_WORDS='credential|secret|token|candidate|pii|bull|strategy|strategies|environment|env|key|database|db|email'
DENY_PHRASE='article[^a-z0-9]*9|user[^a-z0-9]*data'

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) { exit } sub(/^# ?/, ""); print }' "$0"
  printf '\nDeny words: %s\n' "$DENY_WORDS"
  printf 'Deny phrases: %s\n' "$DENY_PHRASE"
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
      exit 2
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

if [ -z "$(printf '%s' "$BRIEF" | LC_ALL=C tr -d '[:space:]')" ]; then
  echo "refused: brief text is empty" >&2
  exit 1
fi

if [ ! -f "$ALLOWLIST" ] || [ ! -r "$ALLOWLIST" ]; then
  echo "refused: no free-tier repo allowlist at $ALLOWLIST" >&2
  exit 1
fi

if ! sed 's/#.*//' "$ALLOWLIST" | tr -d '[:blank:]' \
  | FM_FREE_TIER_REPO="$REPO" awk 'BEGIN { repo = ENVIRON["FM_FREE_TIER_REPO"] }
    $0 == repo { found = 1 }
    END { exit found ? 0 : 1 }'; then
  echo "refused: repo '$REPO' is not on the free-tier allowlist" >&2
  exit 1
fi

if ! SPLIT_BRIEF=$(printf '%s\n' "$BRIEF" \
  | LC_ALL=C sed -e 's/\([a-z0-9]\)\([A-Z]\)/\1 \2/g' \
    -e 's/\([A-Z]\)\([A-Z][a-z]\)/\1 \2/g'); then
  echo "refused: deny-term scan could not normalise the brief text" >&2
  exit 1
fi

DENY_STATUS=0
printf '%s\n%s\n' "$BRIEF" "$SPLIT_BRIEF" \
  | LC_ALL=C grep -qiE "(^|[^a-z0-9])($DENY_WORDS)(s|es)?([^a-z0-9]|\$)|$DENY_PHRASE" \
  || DENY_STATUS=$?

if [ "$DENY_STATUS" -eq 0 ]; then
  echo "refused: brief text matches a free-tier deny term" >&2
  exit 1
elif [ "$DENY_STATUS" -ne 1 ]; then
  echo "refused: deny-term scan failed with status $DENY_STATUS" >&2
  exit 1
fi

printf 'eligible: %s\n' "$REPO"
