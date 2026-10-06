#!/usr/bin/env bash
# fm-capture-intake.sh - durable filing primitives for authenticated phone captures.
#
# Usage:
#   fm-capture-intake.sh save --uid <imap-uid>
#   fm-capture-intake.sh file --uid <uid> --bucket <bucket> --text <text>
#       [--source <source>] [--project <project>] [--attachment <path>]
#       [--draft <text>] [--question <text>] [--time-bound --notify-to <email>]
#   fm-capture-intake.sh digest --to <email>
#   fm-capture-intake.sh arm --to <email>
#   fm-capture-intake.sh check
#
# `save` reads through fm-mail, accepts only an authenticated BrainToss message
# addressed to the mailbox's +toss route, and stores the complete rendered mail
# at data/captures/mail-<uid>/capture.md. `file` performs one local filing action.
# Person captures move into data/captures/people/ and are excluded from every
# digest. Project ideas become queued idea-kind backlog items, never dispatched.
# Outward work is recorded only as a draft. The sole sends are `digest` and an
# explicitly time-bound notice to --notify-to, both through the existing mail
# plane and its $FM_HOME/.env credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
DATA="$FM_HOME/data"
CAPTURES="$DATA/captures"
PERSONAL="$DATA/personal"
MAIL_BIN="${FM_CAPTURE_MAIL_BIN:-$SCRIPT_DIR/fm-mail.sh}"
TASKS_BIN="${FM_CAPTURE_TASKS_BIN:-$SCRIPT_DIR/fm-tasks-axi.sh}"

fail() {
  printf 'fm-capture-intake: %s\n' "$*" >&2
  exit 1
}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

private_mkdir() {
  mkdir -p "$1"
  chmod 0700 "$1"
}

private_append() { # <path> <line>
  local path=$1 line=$2
  private_mkdir "$(dirname "$path")"
  printf '%s\n' "$line" >> "$path"
  chmod 0600 "$path"
}

single_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | awk '{$1=$1; print}'
}

capture_path() { printf '%s/mail-%s' "$CAPTURES" "$1"; }

save_capture() {
  local uid=$1 dir tmp
  case "$uid" in ''|*[!0-9]*) fail '--uid must be a positive IMAP uid' ;; esac
  [ "$uid" -gt 0 ] || fail '--uid must be a positive IMAP uid'
  [ -x "$MAIL_BIN" ] || fail "mail plane is not executable: $MAIL_BIN"
  dir=$(capture_path "$uid")
  private_mkdir "$dir"
  tmp=$(mktemp "$dir/.capture.XXXXXX") || fail 'could not stage capture'
  if ! "$MAIL_BIN" read --id "$uid" > "$tmp"; then
    rm -f -- "$tmp"
    fail "mail uid $uid could not be read"
  fi
  if ! grep -Eiq '^To: .*\+toss@' "$tmp" \
      || ! grep -Eiq '^(Authentication-Results|ARC-Authentication-Results):.*(dkim|spf)=pass.*braintoss' "$tmp"; then
    rm -f -- "$tmp"
    fail "mail uid $uid is not an authenticated BrainToss +toss capture"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$dir/capture.md"
  printf '%s\n' "$dir/capture.md"
}

journal_record() { # <uid> <location> <summary> <draft> <question>
  local today path
  today=$(date +%F)
  path="$CAPTURES/digest/$today.records"
  private_mkdir "$(dirname "$path")"
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\n' \
    "$(single_line "$1")" "$(single_line "$2")" "$(single_line "$3")" \
    "$(single_line "$4")" "$(single_line "$5")" >> "$path"
  chmod 0600 "$path"
}

append_list() { # <list-name> <line>
  local list=$1 line=$2 path
  path="$PERSONAL/$list.md"
  private_mkdir "$PERSONAL"
  if [ ! -s "$path" ]; then
    printf '# %s\n\n' "${list^}" > "$path"
  fi
  printf '%s\n' "$line" >> "$path"
  chmod 0600 "$path"
}

file_capture() {
  local uid=$1 bucket=$2 text=$3 source=$4 project=$5 attachment=$6 draft=$7 question=$8
  local time_bound=$9 notify_to=${10} dir raw marker location line task_out
  dir=$(capture_path "$uid")
  raw="$dir/capture.md"
  marker="$dir/.filed"
  [ -f "$raw" ] || fail "capture $uid has not been accepted; run save first"
  if [ -f "$marker" ]; then
    printf 'already filed: %s\n' "$(cat "$marker")"
    return 0
  fi
  text=$(single_line "$text")
  [ -n "$text" ] || fail '--text must not be empty'
  case "$bucket" in
    book)
      line="- $text"
      [ -z "$source" ] || line="$line (Source: $(single_line "$source"))"
      line="$line ([capture](../captures/mail-$uid/capture.md))"
      append_list reading "$line"
      location='Reading'
      ;;
    place)
      line="- $text ([capture](../captures/mail-$uid/capture.md))"
      if [ -n "$attachment" ]; then
        case "$attachment" in "$dir"/*) ;; *) fail '--attachment must be inside this capture directory' ;; esac
        [ -f "$attachment" ] || fail "attachment does not exist: $attachment"
        line="$line ([picture](../captures/mail-$uid/$(basename "$attachment")))"
      fi
      append_list places "$line"
      location='Places'
      ;;
    idea)
      if [ -n "$project" ]; then
        [ -x "$TASKS_BIN" ] || fail "tasks plane is not executable: $TASKS_BIN"
        task_out=$(FM_HOME="$FM_HOME" "$TASKS_BIN" add "Idea: $text" --mint --kind idea --repo "$project" --body "Captured from BrainToss uid $uid; raw: data/captures/mail-$uid/capture.md")
        location="parked $project backlog idea"
        printf '%s\n' "$task_out"
      else
        append_list ideas "- $text ([capture](../captures/mail-$uid/capture.md))"
        location='Ideas'
      fi
      ;;
    watch)
      append_list watching "- $text ([capture](../captures/mail-$uid/capture.md))"
      location='Watching'
      ;;
    name)
      append_list names "- $text ([capture](../captures/mail-$uid/capture.md))"
      location='Names'
      ;;
    research)
      [ -n "$project" ] || project=firstmate
      [ -x "$TASKS_BIN" ] || fail "tasks plane is not executable: $TASKS_BIN"
      task_out=$(FM_HOME="$FM_HOME" "$TASKS_BIN" add "Research: $text" --mint --kind scout --repo "$project" --body "Captured from BrainToss uid $uid; raw: data/captures/mail-$uid/capture.md")
      location="queued $project research"
      printf '%s\n' "$task_out"
      ;;
    calendar|outward)
      [ -n "$draft" ] || fail "--bucket $bucket requires --draft; outward work always waits for a yes"
      append_list drafts "- $(single_line "$draft") ([capture](../captures/mail-$uid/capture.md))"
      location='Drafts waiting for a yes'
      ;;
    question)
      [ -n "$question" ] || question=$text
      append_list questions "- $(single_line "$question") ([capture](../captures/mail-$uid/capture.md))"
      location='Questions'
      ;;
    task)
      if [ -n "$draft" ]; then
        append_list drafts "- $(single_line "$draft") ([capture](../captures/mail-$uid/capture.md))"
        location='Drafts waiting for a yes'
      else
        append_list tasks "- $text ([capture](../captures/mail-$uid/capture.md))"
        location='Tasks'
      fi
      ;;
    person)
      private_mkdir "$CAPTURES/people"
      [ ! -e "$CAPTURES/people/mail-$uid" ] || fail "People capture already exists: $uid"
      mv -- "$dir" "$CAPTURES/people/mail-$uid"
      chmod 0700 "$CAPTURES/people/mail-$uid"
      printf 'People lane\n' > "$CAPTURES/people/mail-$uid/.filed"
      chmod 0600 "$CAPTURES/people/mail-$uid/.filed"
      printf 'filed: People lane\n'
      return 0
      ;;
    *) fail '--bucket is not in the capture sorting table' ;;
  esac
  if [ -n "$question" ] && [ "$bucket" != question ]; then
    append_list questions "- $(single_line "$question") ([capture](../captures/mail-$uid/capture.md))"
  fi
  printf '%s\n' "$location" > "$marker"
  chmod 0600 "$marker"
  journal_record "$uid" "$location" "$text" "$draft" "$question"
  if [ "$time_bound" = 1 ]; then
    [ -n "$notify_to" ] || fail '--time-bound requires --notify-to'
    printf 'A phone capture may need action soon.\n\n%s\n\nFiled in: %s\n' "$text" "$location" \
      | FM_HOME="$FM_HOME" "$MAIL_BIN" send "$notify_to" 'Time-bound phone capture' -
  fi
  printf 'filed: %s\n' "$location"
}

digest() {
  local to=$1 today journal sent body uid location summary draft question
  today=$(date +%F)
  journal="$CAPTURES/digest/$today.records"
  sent="$CAPTURES/digest/$today.sent"
  [ -n "$to" ] || fail 'digest requires --to'
  [ -s "$journal" ] || fail 'no filed captures are waiting for the evening digest'
  [ ! -e "$sent" ] || fail "the $today digest was already sent"
  body=$'Phone captures filed today:\n'
  while IFS=$'\x1f' read -r uid location summary draft question; do
    body+=$'\n- '"$summary -> $location"
    [ -z "$draft" ] || body+=$'\n  Drafts waiting for a yes: '"$draft"
    [ -z "$question" ] || body+=$'\n  Question: '"$question"
  done < "$journal"
  printf '%s\n' "$body" | FM_HOME="$FM_HOME" "$MAIL_BIN" send "$to" 'Phone capture digest' -
  private_mkdir "$(dirname "$sent")"
  printf 'sent=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$sent"
  chmod 0600 "$sent"
}

arm_digest() {
  local to=$1 state="$FM_HOME/state" recipient shim tmp
  recipient="$state/.capture-digest-to"
  shim="$state/capture-digest.check.sh"
  [ -n "$to" ] && [[ "$to" == *@* ]] && [[ "$to" != *$'\n'* ]] || fail 'arm requires a single --to email address'
  private_mkdir "$state"
  tmp=$(mktemp "$state/.capture-digest-to.XXXXXX") || fail 'could not stage digest recipient'
  printf '%s\n' "$to" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$recipient"
  tmp=$(mktemp "$state/.capture-digest-check.XXXXXX") || fail 'could not stage digest check'
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'exec env FM_HOME=%q %q check\n' "$FM_HOME" "$SCRIPT_DIR/fm-capture-intake.sh"
  } > "$tmp"
  chmod 0700 "$tmp"
  mv -f -- "$tmp" "$shim"
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-check-register.sh" capture-digest
}

check_digest() {
  local hour=${FM_CAPTURE_DIGEST_HOUR:-18} now recipient="$FM_HOME/state/.capture-digest-to"
  case "$hour" in ''|*[!0-9]*) fail 'FM_CAPTURE_DIGEST_HOUR must be 0 through 23' ;; esac
  [ "$hour" -le 23 ] || fail 'FM_CAPTURE_DIGEST_HOUR must be 0 through 23'
  now=$(date +%H)
  now=$((10#$now))
  [ "$now" -ge "$hour" ] || return 0
  [ -s "$recipient" ] || fail 'evening digest recipient is missing; run arm --to <email>'
  [ -s "$CAPTURES/digest/$(date +%F).records" ] || return 0
  [ ! -e "$CAPTURES/digest/$(date +%F).sent" ] || return 0
  digest "$(cat "$recipient")" >/dev/null
}

command=${1:-}
shift || true
uid=''
bucket=''
text=''
source=''
project=''
attachment=''
draft=''
question=''
notify_to=''
to=''
time_bound=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --uid|--bucket|--text|--source|--project|--attachment|--draft|--question|--notify-to|--to)
      [ "$#" -ge 2 ] || fail "$1 requires a value"
      key=${1#--}; key=${key//-/_}; printf -v "$key" '%s' "$2"; shift 2 ;;
    --time-bound) time_bound=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $1" ;;
  esac
done

case "$command" in
  save) [ -n "$uid" ] || fail 'save requires --uid'; save_capture "$uid" ;;
  file)
    [ -n "$uid" ] && [ -n "$bucket" ] && [ -n "$text" ] || fail 'file requires --uid, --bucket, and --text'
    file_capture "$uid" "$bucket" "$text" "$source" "$project" "$attachment" "$draft" "$question" "$time_bound" "$notify_to"
    ;;
  digest) digest "$to" ;;
  arm) arm_digest "$to" ;;
  check) check_digest ;;
  -h|--help|'') usage ;;
  *) fail "unknown command: $command" ;;
esac
