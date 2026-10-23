#!/usr/bin/env bash
# Check that a PR body carries exactly one well-formed charter line:
#   Charter boxes: <ids or none>
# where the value is "none" or a comma-separated list of charter box ids such
# as "O1.1, O2.3" from the project's charter (docs/IDEAL_STATE.md by default).
# Every PR-raising ship brief (bin/fm-brief.sh) tells the worker to run this on
# its PR body before reporting done.
# Usage: fm-charter-line.sh [<body-file>]   (reads stdin without a file)
# Exits 0 and prints the line when it is well formed; otherwise exits 1 and
# names what is wrong on stderr.
set -eu

case "${1:-}" in
  -h|--help) sed -n '2,10{s/^# \{0,1\}//;p;}' "$0"; exit 0 ;;
esac

if [ "$#" -gt 0 ]; then
  [ -r "$1" ] || { echo "error: cannot read PR body file: $1" >&2; exit 1; }
  body=$(cat -- "$1")
else
  body=$(cat)
fi

lines=$(printf '%s\n' "$body" | grep -E '^Charter boxes:' || true)
count=$(printf '%s' "$lines" | grep -c '' || true)
if [ "$count" -eq 0 ]; then
  echo "error: the PR body has no 'Charter boxes: <ids or none>' line" >&2
  exit 1
fi
if [ "$count" -gt 1 ]; then
  echo "error: the PR body has $count 'Charter boxes:' lines; keep exactly one" >&2
  exit 1
fi
value=${lines#Charter boxes:}
value=$(printf '%s' "$value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
id='[A-Za-z][A-Za-z0-9._-]*'
if [ "$value" = none ] || printf '%s\n' "$value" | grep -Eq "^$id([[:space:]]*,[[:space:]]*$id)*$"; then
  printf '%s\n' "$lines"
  exit 0
fi
echo "error: the Charter boxes line must name box ids such as 'O1.1, O2.3' or 'none' (got '$value')" >&2
exit 1
