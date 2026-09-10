# shellcheck shell=bash
# Single owner of the branch-name shape Firstmate accepts from an operator.
# Usage: . bin/fm-branch-name-lib.sh
#
# Three callers hand an operator-supplied branch name straight to git or to a
# forge, and two of them also persist it into private task metadata:
#   - bin/fm-spawn.sh --base <branch>       resolves origin/<branch> and records base=
#   - bin/fm-brief.sh --base <branch>       records it in the generated ship brief
#   - bin/fm-pr-merge.sh --expect-base <branch>  compares it with the forge's own base
# The accepted shape is a deliberately conservative subset of what
# git check-ref-format would allow, because git is not required to be present to
# reject an input and a name that survives this predicate must also be safe to
# write as one `key=value` metadata line and to print inside a refusal.
# Accepted: one or more of A-Z a-z 0-9 . _ - /, with no leading dash, no leading
# or trailing slash, no empty path component, no '..', and no component that
# begins with a dot or ends in '.lock'.

fm_branch_name_valid() {  # <name>
  local name=$1 component rest
  case "$name" in
    ''|-*|/*|*/) return 1 ;;
    *[!A-Za-z0-9._/-]*) return 1 ;;
    *..*|*//*) return 1 ;;
  esac
  rest=$name
  while [ -n "$rest" ]; do
    component=${rest%%/*}
    case "$rest" in
      */*) rest=${rest#*/} ;;
      *) rest= ;;
    esac
    case "$component" in
      ''|.*|*.lock) return 1 ;;
    esac
  done
  return 0
}
