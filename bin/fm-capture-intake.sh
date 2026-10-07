#!/usr/bin/env bash
# fm-capture-intake.sh - durable filing primitives for authenticated phone captures.
#
# Usage:
#   fm-capture-intake.sh save --uid <imap-uid>
#   fm-capture-intake.sh file --uid <uid> --bucket <bucket> --text <text>
#       [--source <source>] [--project <project>] [--attachment <path>]
#       [--draft <text>] [--question <text>] [--time-bound]
#   fm-capture-intake.sh digest
#   fm-capture-intake.sh arm --to <email>
#   fm-capture-intake.sh check
#
# `save` reads through fm-mail, accepts only an authenticated BrainToss message
# addressed to the mailbox's +toss route, and stores the complete rendered mail
# at data/captures/mail-<uid>/capture.md. `file` performs one local filing action.
# Person captures move into data/captures/people/ and are excluded from every
# digest. Project ideas become queued idea-kind backlog items, never dispatched.
# Outward work is recorded only as a draft. The sole sends are `digest` and an
# explicitly time-bound notice, both sent only to the recipient stored by `arm`
# through the existing mail plane and its $FM_HOME/.env credentials.
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

single_line() {
  printf '%s' "$1" | tr '\r\n\t' '   ' | awk '{$1=$1; print}'
}

capture_path() { printf '%s/mail-%s' "$CAPTURES" "$1"; }

is_braintoss_capture() { # <rendered-mail-file>
  python3 -I - "$1" <<'PY'
import re, sys

header = []
with open(sys.argv[1], encoding='utf-8', errors='replace') as rendered:
    for line in rendered:
        if not line.strip():
            break
        header.append(line.rstrip('\n'))

def first(name):
    prefix = name.lower() + ':'
    for line in header:
        if line.lower().startswith(prefix):
            return line[len(prefix):]
    return None

def from_braintoss(value):
    domain = value.rsplit('@', 1)[-1].strip('<>;, ').lower()
    return re.search(r'(^|\.)braintoss\.(com|app)$', domain) is not None

to = first('To')
results = first('Authentication-Results')
if to is None or results is None:
    sys.exit(1)
if not any(addr.split('@')[0].lower().endswith('+toss')
           for addr in re.findall(r'[^\s<>,"]+@[^\s<>,"]+', to)):
    sys.exit(1)
for method in results.split(';')[1:]:
    fields = dict(f.split('=', 1) for f in method.split() if '=' in f)
    if fields.get('dkim') == 'pass' and any(from_braintoss(fields.get(k, '')) for k in ('header.d', 'header.i')):
        sys.exit(0)
    if fields.get('spf') == 'pass' and from_braintoss(fields.get('smtp.mailfrom', '')):
        sys.exit(0)
sys.exit(1)
PY
}

neutralize_title() {
  python3 -I -c '
import re, sys
t = sys.argv[1]
t = re.sub(r"((?:\(|,)\s*)(hold-kind|hold-until|hold|repo|kind|priority):", r"\1\2 -", t)
t = re.sub(r"((?:\(|,)\s*)(since|merged|reported|done)(\s)", r"\1\2-\3", t)
print(t.replace("blocked-by:", "blocked-by -"))
' "$1"
}

url_encode() {
  python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

discard_unaccepted() { # <capture-dir> <staged-file>
  rm -f -- "$2"
  [ -f "$1/.accepted" ] || rm -rf -- "$1"
}

save_capture() {
  local uid=$1 dir tmp
  case "$uid" in ''|*[!0-9]*) fail '--uid must be a positive IMAP uid' ;; esac
  [ "$uid" -gt 0 ] || fail '--uid must be a positive IMAP uid'
  [ -x "$MAIL_BIN" ] || fail "mail plane is not executable: $MAIL_BIN"
  dir=$(capture_path "$uid")
  [ ! -e "$CAPTURES/people/mail-$uid" ] || fail "capture $uid was already filed to the People lane"
  if [ -f "$dir/.filed" ]; then
    printf '%s\n' "$dir/capture.md"
    return 0
  fi
  private_mkdir "$dir"
  tmp=$(mktemp "$dir/.capture.XXXXXX") || fail 'could not stage capture'
  if ! "$MAIL_BIN" read --id "$uid" > "$tmp"; then
    discard_unaccepted "$dir" "$tmp"
    fail "mail uid $uid could not be read"
  fi
  if ! is_braintoss_capture "$tmp"; then
    discard_unaccepted "$dir" "$tmp"
    fail "mail uid $uid is not an authenticated BrainToss +toss capture"
  fi
  if ! FM_MAIL_SAVE_MEDIA=1 "$MAIL_BIN" read --id "$uid" > "$tmp"; then
    discard_unaccepted "$dir" "$tmp"
    fail "mail uid $uid could not be read"
  fi
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$dir/capture.md"
  : > "$dir/.accepted"
  chmod 0600 "$dir/.accepted"
  printf '%s\n' "$dir/capture.md"
}

journal_record() { # <uid> <location> <summary> <draft> <question>
  local path="$CAPTURES/digest/records"
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
    printf '# %s%s\n\n' "$(printf '%s' "${list%"${list#?}"}" | tr '[:lower:]' '[:upper:]')" "${list#?}" > "$path"
  fi
  printf '%s\n' "$line" >> "$path"
  chmod 0600 "$path"
}

file_capture() {
  local uid=$1 bucket=$2 text=$3 source=$4 project=$5 attachment=$6 draft=$7 question=$8
  local time_bound=$9 notify_to='' dir raw marker location line task_out title attachment_dir
  dir=$(capture_path "$uid")
  raw="$dir/capture.md"
  marker="$dir/.filed"
  [ -f "$dir/.accepted" ] && [ -f "$raw" ] || fail "capture $uid has not been accepted; run save first"
  if [ -f "$marker" ]; then
    printf 'already filed: %s\n' "$(cat "$marker")"
    return 0
  fi
  text=$(single_line "$text")
  [ -n "$text" ] || fail '--text must not be empty'
  case "$bucket" in
    book|place|idea|watch|name|research|calendar|outward|question|task|person) ;;
    *) fail '--bucket is not in the capture sorting table' ;;
  esac
  case "$bucket" in
    calendar|outward) [ -n "$draft" ] || fail "--bucket $bucket requires --draft; outward work always waits for a yes" ;;
    research) [ -x "$TASKS_BIN" ] || fail "tasks plane is not executable: $TASKS_BIN" ;;
    idea) [ -z "$project" ] || [ -x "$TASKS_BIN" ] || fail "tasks plane is not executable: $TASKS_BIN" ;;
    place)
      if [ -n "$attachment" ]; then
        [ -f "$attachment" ] && [ ! -L "$attachment" ] || fail "attachment does not exist: $attachment"
        attachment_dir=$(cd "$(dirname "$attachment")" && pwd -P)
        [ "$attachment_dir" = "$(cd "$dir" && pwd -P)" ] || fail '--attachment must be inside this capture directory'
      fi
      ;;
  esac
  if [ "$time_bound" = 1 ]; then
    [ "$bucket" != person ] || fail 'a People capture cannot be time-bound'
    notify_to=$(armed_recipient)
    printf 'A phone capture may need action soon.\n\n%s\n' "$text" \
      | FM_HOME="$FM_HOME" "$MAIL_BIN" send "$notify_to" 'Time-bound phone capture' -
  fi
  title=$(neutralize_title "$text")
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
        line="$line ([picture](../captures/mail-$uid/$(url_encode "$(basename "$attachment")")))"
      fi
      append_list places "$line"
      location='Places'
      ;;
    idea)
      if [ -n "$project" ]; then
        task_out=$(FM_HOME="$FM_HOME" "$TASKS_BIN" add "Idea: $title" --mint --kind idea --repo "$project" --body "Captured from BrainToss uid $uid; raw: data/captures/mail-$uid/capture.md")
        location="parked $project backlog idea"
        printf '%s\n' "$task_out"
      else
        append_list ideas "- $text ([capture](../captures/mail-$uid/capture.md))"
        location='Ideas'
      fi
      ;;
    watch)
      line="- $text"
      [ -z "$source" ] || line="$line (Source: $(single_line "$source"))"
      append_list watching "$line ([capture](../captures/mail-$uid/capture.md))"
      location='Watching'
      ;;
    name)
      append_list names "- $text ([capture](../captures/mail-$uid/capture.md))"
      location='Names'
      ;;
    research)
      [ -n "$project" ] || project=firstmate
      task_out=$(FM_HOME="$FM_HOME" "$TASKS_BIN" add "Research: $title" --mint --kind scout --repo "$project" --body "Captured from BrainToss uid $uid; raw: data/captures/mail-$uid/capture.md")
      location="queued $project research"
      printf '%s\n' "$task_out"
      ;;
    calendar|outward)
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
  esac
  if [ -n "$question" ] && [ "$bucket" != question ]; then
    append_list questions "- $(single_line "$question") ([capture](../captures/mail-$uid/capture.md))"
  fi
  printf '%s\n' "$location" > "$marker"
  chmod 0600 "$marker"
  journal_record "$uid" "$location" "$text" "$draft" "$question"
  printf 'filed: %s\n' "$location"
}

armed_recipient() {
  local recipient="$FM_HOME/state/.capture-digest-to"
  [ -s "$recipient" ] || fail 'mail recipient is missing; run arm --to <email>'
  cat "$recipient"
}

unreported_range() { # prints "<reported-count> <record-count>"
  local cursor=0 total=0
  [ ! -s "$CAPTURES/digest/reported" ] || cursor=$(cat "$CAPTURES/digest/reported")
  [ ! -s "$CAPTURES/digest/records" ] || total=$(wc -l < "$CAPTURES/digest/records" | tr -d ' ')
  printf '%s %s\n' "$cursor" "$total"
}

digest() {
  local to today records cursor_file cursor total sent body uid location summary draft question
  to=$(armed_recipient)
  today=$(date +%F)
  records="$CAPTURES/digest/records"
  cursor_file="$CAPTURES/digest/reported"
  sent="$CAPTURES/digest/$today.sent"
  [ ! -e "$sent" ] || fail "the $today digest was already sent"
  read -r cursor total <<< "$(unreported_range)"
  [ "$total" -gt "$cursor" ] || fail 'no filed captures are waiting for the evening digest'
  body=$'Phone captures filed since the last digest:\n'
  while IFS=$'\x1f' read -r uid location summary draft question; do
    body+=$'\n- '"$summary -> $location"
    [ -z "$draft" ] || body+=$'\n  Drafts waiting for a yes: '"$draft"
    [ -z "$question" ] || body+=$'\n  Question: '"$question"
  done < <(sed -n "$((cursor + 1)),${total}p" "$records")
  printf '%s\n' "$body" | FM_HOME="$FM_HOME" "$MAIL_BIN" send "$to" 'Phone capture digest' -
  printf '%s\n' "$total" > "$cursor_file"
  printf 'sent=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$sent"
  chmod 0600 "$cursor_file" "$sent"
}

arm_digest() {
  local to=$1 state="$FM_HOME/state" recipient shim tmp
  recipient="$state/.capture-digest-to"
  shim="$state/capture-digest.check.sh"
  [ -n "$to" ] && [[ "$to" == *@* ]] && [[ "$to" != *$'\n'* ]] || fail 'arm requires a single --to email address'
  if [ -s "$recipient" ] && [ "$(cat "$recipient")" != "$to" ]; then
    fail "a recipient is already armed; the captain must delete $recipient to change it"
  fi
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
  local now cursor total
  now=$(date +%H)
  [ "$((10#$now))" -ge 19 ] || return 0
  armed_recipient >/dev/null
  [ ! -e "$CAPTURES/digest/$(date +%F).sent" ] || return 0
  read -r cursor total <<< "$(unreported_range)"
  [ "$total" -gt "$cursor" ] || return 0
  digest >/dev/null
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
to=''
time_bound=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --uid|--bucket|--text|--source|--project|--attachment|--draft|--question|--to)
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
    file_capture "$uid" "$bucket" "$text" "$source" "$project" "$attachment" "$draft" "$question" "$time_bound"
    ;;
  digest) digest ;;
  arm) arm_digest "$to" ;;
  check) check_digest ;;
  -h|--help|'') usage ;;
  *) fail "unknown command: $command" ;;
esac
