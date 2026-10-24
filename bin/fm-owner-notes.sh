#!/usr/bin/env bash
# Keep the captain's own words from every ship and scout task in one durable
# file per project, so they outlive the task that heard them, and show where
# each one went.
# A worker saves the captain's words verbatim, dated, with what it did with
# them, to data/<task-id>/captain-notes-<YYYY-MM-DD>.md (bin/fm-brief.sh owns
# that instruction). Owner-words files in data/<task-id>/ are the *.md files
# that match one of these, brief.md, launch-brief.md, report.md and
# follow-ups.md never included:
#   captain-*.md (captain-notes-*, captain-answers-*, captain-feedback-*,
#     captain-words-*, captain-review-* and every other captain- file)
#   *-captain-words*.md
#   board-answers*.md
#   answers*.md whose first heading names the captain
#   any other file whose first heading says verbatim together with owner or
#     captain ("# Owner's words, verbatim")
# Board replies firstmate wrote (reply-*, *-reply*) match none of these.
# bin/fm-teardown.sh runs `collect` on cleanup, which appends every owner-words
# file of the task, in name order, to data/owner-notes/<project>.md under a
# "## <date> - <task-id>" heading. The date is the first YYYY-MM-DD in the file
# name, else the file's own modification date (UTC).
# Collection only ever appends: an earlier entry's words are never edited. Each
# entry carries a marker naming its task, file, and content hash,
#   <!-- fm-owner-notes task=<task-id> file=<name> sha256=<hash> -->
# so a repeated collection appends nothing, while a notes file that grew after
# it was collected lands again whole as a new entry. The task's own copy stays
# in data/<task-id>/. Appends to one project file are serialized under a lock.
# A task whose project is this firstmate home or code root collects into
# data/owner-notes/firstmate.md; any other project collects into
# data/owner-notes/<basename of its project path>.md. A project named "index"
# maps to project-index.md, because index.md is the index below.
# bin/fm-brief.sh names data/owner-notes/<repo-name>.md as required reading in
# every ship and scout brief for that project once it exists, using `file`.
# Usage: fm-owner-notes.sh collect <task-id> (--project <name> | --project-path <path>)
#        fm-owner-notes.sh file <project-name>
#        fm-owner-notes.sh backfill
#        fm-owner-notes.sh index
#        fm-owner-notes.sh place <project-name> <entry-hash> <file>:<line or heading>
#   collect   append the task's owner-words files to its project's owner notes.
#   file      print the owner-notes path for a project name; every character
#             outside A-Za-z0-9._- becomes "-" and leading dots are dropped,
#             so any project name maps to one file; exit 1 only when nothing
#             is left. `collect` uses the same mapping.
#   backfill  run by firstmate by hand after this lands and by the follow-up
#             per-project placement ships; once and idempotently, (1) run collect for every data/<task-id>/
#             holding an owner-words file, resolving each task's project from
#             its live state/<task-id>.meta, else its brief's "worktree of
#             <repo>" line (a relative repo path resolves from FM_HOME); a
#             task whose project cannot be resolved is listed and collected
#             into general; (2) append every dated entry of data/captain.md
#             dated 2026-09-01 or later, which it never rewrites. A dated entry
#             is a heading carrying a date (YYYY-MM-DD or "6 Oct 2026") with
#             its lines up to the next heading or dated bullet, or a top-level
#             "- " bullet whose first line carries a date, with its lines up to
#             the next heading or top-level bullet that starts another entry.
#             Each goes to the first registered project (data/projects.md, else
#             projects/) or firstmate that its text names, else that its
#             heading names, else data/owner-notes/general.md. A one-word name
#             matches capitalized ("Scout"); a hyphenated name matches in any
#             case with a hyphen or a space ("doc creator"). Its marker is
#             task=captain.md file=captain.md sha256=<hash of the entry>, and
#             an entry whose hash any owner-notes file holds is not appended.
#   index     write data/owner-notes/index.md: a summary of notes, placed, and
#             not yet placed per project; one table row per collected entry
#             (date, project, task or source, first 12 words of the note,
#             destination, entry hash); then every unplaced note grouped by
#             project, the worklist for placing them. The destination is every
#             placement marker of the entry, else "not yet placed". Prints
#             nothing to do when no owner notes exist.
#   place     record that an entry became a line in a charter or brief: insert
#             <!-- fm-owner-notes placed=<repo-relative file>:<line or heading> -->
#             right after the entry's marker (after any earlier placements).
#             <entry-hash> is the hash, or a prefix of it naming one entry, as
#             the index prints it. Placing the same destination again changes
#             nothing. This marker line is the only edit made inside an entry.
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data; the state
# directory is FM_STATE_OVERRIDE, else $FM_HOME/state.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

project_slug() {  # <project-name>
  local slug
  slug=$(printf '%s' "${1-}" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | sed 's/^\.*//')
  [ -n "$slug" ] || return 1
  [ "$slug" != index ] || slug="project-index"
  printf '%s\n' "$slug"
}

owner_notes_file() {  # <project-name>
  local slug
  slug=$(project_slug "$1") || return 1
  printf '%s/owner-notes/%s.md\n' "$DATA" "$slug"
}

canonical_dir() {
  (CDPATH='' cd -- "$1" 2>/dev/null && pwd -P)
}

# A project path that is this home or its code root is firstmate itself.
project_name_for_path() {  # <project-path>
  local path=$1 abs home
  abs=$(canonical_dir "$path" || printf '%s' "$path")
  for home in "$FM_HOME" "$FM_ROOT" "$(dirname "$DATA")"; do
    [ "$abs" != "$(canonical_dir "$home" || true)" ] || { printf 'firstmate\n'; return 0; }
  done
  basename "$path"
}

notes_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

notes_date() {  # <file>
  local name
  name=$(basename "$1")
  if [[ $name =~ ([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    date -u -r "$1" +%Y-%m-%d
  fi
}

# True when <file> is one of the owner-words files the header lists.
owner_words_file() {  # <file>
  local name heading
  name=$(basename "$1")
  case "$name" in
    brief.md|launch-brief.md|report.md|follow-ups.md) return 1 ;;
    captain-*.md|*-captain-words*.md|board-answers*.md) return 0 ;;
  esac
  heading=$(grep -m 1 '^#' -- "$1" 2>/dev/null | LC_ALL=C tr '[:upper:]' '[:lower:]' || true)
  case "$name" in
    answers*.md) case "$heading" in *captain*) return 0 ;; esac ;;
  esac
  case "$heading" in *verbatim*) case "$heading" in *owner*|*captain*) return 0 ;; esac ;; esac
  return 1
}

# Appends one entry to the project's owner notes under its lock.
# Returns 0 when appended, 1 when that marker is already there.
append_entry() {  # <project> <date> <task> <file-name> <sha256> <source> <body-file>
  local project=$1 date=$2 task=$3 name=$4 sha=$5 source=$6 body=$7 dest marker rc=1
  dest=$(owner_notes_file "$project") || { echo "error: invalid project name: $project" >&2; return 2; }
  marker="<!-- fm-owner-notes task=$task file=$name sha256=$sha -->"
  mkdir -p "$DATA/owner-notes"
  OWNER_NOTES_LOCK="$dest.lock"
  fm_lock_acquire_wait "$OWNER_NOTES_LOCK"
  trap 'fm_lock_release "$OWNER_NOTES_LOCK" || true' EXIT
  if [ ! -e "$dest" ]; then
    printf '%s\n' "# Owner notes: $(basename "$dest" .md)" '' \
      "The captain's own words on $project, verbatim, collected from Firstmate tasks at cleanup and from dated entries of data/captain.md." \
      "Entries are appended in collection order and their words are never edited; bin/fm-owner-notes.sh place adds where each one went." > "$dest"
  fi
  if ! grep -Fqx -- "$marker" "$dest"; then
    [ -z "$(tail -c 1 -- "$dest")" ] || printf '\n' >> "$dest"
    {
      printf '\n## %s - %s\n%s\nSource: %s\n\n' "$date" "$task" "$marker" "$source"
      cat -- "$body"
    } >> "$dest"
    rc=0
  fi
  fm_lock_release "$OWNER_NOTES_LOCK" || true
  trap - EXIT
  return "$rc"
}

collect() {  # <task-id> <project-name>
  local id=$1 project=$2 file name appended=0 rc
  fm_task_id_path_safe "$id" || { echo "error: invalid task id: $id" >&2; return 2; }
  for file in "$DATA/$id"/*.md; do
    [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || continue
    owner_words_file "$file" || continue
    name=$(basename "$file")
    if append_entry "$project" "$(notes_date "$file")" "$id" "$name" "$(notes_sha256 "$file")" "$name" "$file"; then
      appended=$((appended + 1))
    else
      rc=$?
      [ "$rc" -eq 1 ] || return "$rc"
    fi
  done
  [ "$appended" -eq 0 ] || echo "collected $appended owner-words file(s) from $id into $(owner_notes_file "$project")"
}

fm_meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

task_has_owner_words() {  # <task-dir>
  local file
  for file in "$1"/*.md; do
    [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || continue
    ! owner_words_file "$file" || return 0
  done
  return 1
}

backfill() {
  local dir id project path repo
  for dir in "$DATA"/*/; do
    dir=${dir%/}
    id=$(basename "$dir")
    [ "$id" != owner-notes ] || continue
    task_has_owner_words "$dir" || continue
    if ! fm_task_id_path_safe "$id"; then
      echo "skipped $id: not a task id" >&2
      continue
    fi
    project=
    if [ -f "$STATE/$id.meta" ]; then
      path=$(fm_meta_value "$STATE/$id.meta" project)
      [ -z "$path" ] || project=$(project_name_for_path "$path")
    fi
    if [ -z "$project" ] && [ -f "$dir/brief.md" ]; then
      repo=$(sed -n 's/^You are in a disposable git worktree of \([^,]*\), at a detached HEAD.*/\1/p' "$dir/brief.md" | head -n 1)
      case "$repo" in
        '') ;;
        /*) project=$(project_name_for_path "$repo") ;;
        *) project=$(cd "$FM_HOME" 2>/dev/null && project_name_for_path "$repo") ;;
      esac
    fi
    if [ -z "$project" ] || ! project_slug "$project" >/dev/null; then
      echo "no project could be resolved for $id; collecting into general" >&2
      project=general
    fi
    collect "$id" "$project"
  done
  sweep_captain_md
}

CAPTAIN_SINCE=2026-09-01

# Splits data/captain.md into its dated entries (header: backfill): one file
# per entry under <dir>, plus <dir>/manifest lines "<n><TAB><date><TAB><heading>".
# shellcheck disable=SC2016 # awk program text, expanded by awk.
CAPTAIN_ENTRIES_AWK='
function iso(s,    best, pos, t, n, p, mon) {
  best = ""; pos = 0
  if (match(s, /20[0-9][0-9]-[01][0-9]-[0-3][0-9]/)) { best = substr(s, RSTART, 10); pos = RSTART }
  if (match(s, /[0-9][0-9]? (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]* 20[0-9][0-9]/) && (pos == 0 || RSTART < pos)) {
    t = substr(s, RSTART, RLENGTH); n = split(t, p, " ")
    mon = (index("JanFebMarAprMayJunJulAugSepOctNovDec", substr(p[2], 1, 3)) + 2) / 3
    best = sprintf("%s-%02d-%02d", p[n], mon, p[1])
  }
  return best
}
function flush(    i, f, h) {
  if (open) {
    while (n > 0 && lines[n] ~ /^[ \t]*$/) n--
    if (n > 0 && entry_date >= since) {
      count++
      f = sprintf("%s/%05d", dir, count)
      for (i = 1; i <= n; i++) print lines[i] > f
      close(f)
      h = heading; gsub(/\t/, " ", h)
      printf "%05d\t%s\t%s\n", count, entry_date, h > (dir "/manifest")
    }
  }
  open = 0; n = 0
}
BEGIN { printf "" > (dir "/manifest") }
/^#/ {
  flush()
  heading = $0; sub(/^#+[ \t]*/, "", heading)
  d = iso($0)
  if (d != "") { open = 1; entry_date = d; lines[++n] = $0 }
  next
}
/^- / {
  d = iso($0)
  if (d != "") { flush(); open = 1; entry_date = d; lines[++n] = $0; next }
}
{ if (open) lines[++n] = $0 }
END { flush() }
'

# Registered project names (data/projects.md, else projects/), then firstmate.
project_names() {
  local names='' dir
  [ ! -f "$DATA/projects.md" ] || names=$(awk '$1 == "-" && $2 != "" {print $2}' "$DATA/projects.md")
  if [ -z "$names" ]; then
    for dir in "$FM_HOME/projects"/*/; do
      [ -d "$dir" ] || continue
      names=$(printf '%s\n%s' "$names" "$(basename "$dir")")
    done
  fi
  printf '%s\nfirstmate\n' "$names" | sed '/^$/d'
}

# Prints the first project named by the entry text, else by the heading, else nothing.
route_project() {  # <names-file> <entry-file> <heading>
  FM_ROUTE_HEADING=$3 awk '
    function first(s,    i, nm, re, lc, best, bestpos) {
      best = ""; bestpos = 0; lc = tolower(s)
      for (i = 1; i <= k; i++) {
        nm = names[i]
        if (nm ~ /-/ || nm == "firstmate") {
          re = tolower(nm); gsub(/\./, "[.]", re); gsub(/-/, "[- ]", re)
          if (match(lc, "(^|[^a-z0-9])" re "([^a-z0-9]|$)") && (bestpos == 0 || RSTART < bestpos)) { best = nm; bestpos = RSTART }
        } else {
          re = toupper(substr(nm, 1, 1)) substr(nm, 2); gsub(/\./, "[.]", re)
          if (match(s, "(^|[^A-Za-z0-9])" re "([^A-Za-z0-9]|$)") && (bestpos == 0 || RSTART < bestpos)) { best = nm; bestpos = RSTART }
        }
      }
      return best
    }
    FNR == NR { names[++k] = $0; next }
    { text = text " " $0 }
    END { p = first(text); if (p == "") p = first(ENVIRON["FM_ROUTE_HEADING"]); print p }
  ' "$1" "$2"
}

sweep_captain_md() {
  local src="$DATA/captain.md" tmp num date heading project sha source appended=0 rc
  [ -f "$src" ] || return 0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-owner-notes.XXXXXX")
  awk -v dir="$tmp" -v since="$CAPTAIN_SINCE" "$CAPTAIN_ENTRIES_AWK" "$src"
  project_names > "$tmp/names"
  while IFS=$'\t' read -r num date heading; do
    sha=$(notes_sha256 "$tmp/$num")
    ! grep -Fqs -- "file=captain.md sha256=$sha -->" "$DATA"/owner-notes/*.md || continue
    project=$(route_project "$tmp/names" "$tmp/$num" "$heading")
    [ -n "$project" ] || project=general
    source='captain.md'
    [ -z "$heading" ] || source="captain.md, under \"$heading\""
    if append_entry "$project" "$date" captain.md captain.md "$sha" "$source" "$tmp/$num"; then
      appended=$((appended + 1))
    else
      rc=$?
      [ "$rc" -eq 1 ] || { rm -rf "$tmp"; return "$rc"; }
    fi
  done < "$tmp/manifest"
  rm -rf "$tmp"
  [ "$appended" -eq 0 ] || echo "collected $appended dated captain.md entries into $DATA/owner-notes"
}

# One TSV line per collected entry across every owner-notes file:
# date, project, task, first 12 words, placements ("" when none), sha256.
index_rows() {
  local file
  local -a files=()
  for file in "$DATA/owner-notes"/*.md; do
    [ -f "$file" ] && [ "$(basename "$file")" != index.md ] || continue
    files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '
    function emit() {
      if (sha != "") print date "\t" project "\t" task "\t" words "\t" placed "\t" sha
      sha = ""
    }
    FNR == 1 { emit(); project = FILENAME; sub(/^.*\//, "", project); sub(/\.md$/, "", project); prev = "" }
    /^<!-- fm-owner-notes task=[^ ]* file=.* sha256=[0-9a-f]+ -->$/ {
      emit()
      date = prev; sub(/^## /, "", date); sub(/ - .*$/, "", date)
      task = $0; sub(/^<!-- fm-owner-notes task=/, "", task); sub(/ file=.*$/, "", task)
      sha = $0; sub(/^.* sha256=/, "", sha); sub(/ -->$/, "", sha)
      words = ""; nwords = 0; placed = ""; head = 1; prev = $0; next
    }
    sha != "" && head && /^<!-- fm-owner-notes placed=.* -->$/ {
      p = $0; sub(/^<!-- fm-owner-notes placed=/, "", p); sub(/ -->$/, "", p)
      placed = placed (placed == "" ? "" : ", ") p
      prev = $0; next
    }
    sha != "" && head && /^Source: / { head = 0; prev = $0; next }
    sha != "" && nwords < 12 && $0 !~ /^[ \t]*(#|<!--|$)/ {
      head = 0
      n = split($0, w)
      for (i = 1; i <= n && nwords < 12; i++) { words = words (nwords ? " " : "") w[i]; nwords++ }
    }
    { prev = $0 }
    END { emit() }
  ' "${files[@]}" | tr -d '\r'
}

write_index() {
  local out tmp rows
  rows=$(index_rows)
  [ -n "$rows" ] || { echo "no owner notes yet; nothing to index"; return 0; }
  out="$DATA/owner-notes/index.md"
  if [ -L "$out" ] || { [ -e "$out" ] && [ ! -f "$out" ]; }; then
    echo "error: $out is not a regular file; move it aside and rerun: $0 index" >&2
    return 1
  fi
  tmp="$out.tmp.$$"
  printf '%s\n' "$rows" | LC_ALL=C sort -s -t "$(printf '\t')" -k1,1 -k2,2 -k3,3 | awk -F '\t' '
    function cell(s) { gsub(/\|/, "\\|", s); return s }
    {
      n++; date[n] = $1; proj[n] = $2; task[n] = $3; words[n] = $4; placed[n] = $5; short[n] = substr($6, 1, 12)
      if (!(proj[n] in total)) projects[++np] = proj[n]
      total[proj[n]]++
      if (placed[n] != "") done[proj[n]]++
    }
    END {
      for (i = 1; i <= np; i++) for (j = i + 1; j <= np; j++) if (projects[j] < projects[i]) { t = projects[i]; projects[i] = projects[j]; projects[j] = t }
      print "# Owner notes index"
      print ""
      print "Generated by `bin/fm-owner-notes.sh index`; do not edit by hand."
      print "Record where a note went with `bin/fm-owner-notes.sh place <project> <entry> <file>:<line or heading>`, then run `index` again."
      print ""
      print "## Summary"
      print ""
      print "| Project | Notes | Placed | Not yet placed |"
      print "| --- | ---: | ---: | ---: |"
      for (i = 1; i <= np; i++) {
        p = projects[i]; d = done[p] + 0
        print "| " cell(p) " | " total[p] " | " d " | " total[p] - d " |"
        all += total[p]; alld += d
      }
      print "| Total | " all " | " alld " | " all - alld " |"
      print ""
      print "## Notes"
      print ""
      print "| Date | Project | Source | First words | Destination | Entry |"
      print "| --- | --- | --- | --- | --- | --- |"
      for (i = 1; i <= n; i++)
        print "| " cell(date[i]) " | " cell(proj[i]) " | " cell(task[i]) " | " cell(words[i]) " | " (placed[i] == "" ? "not yet placed" : cell(placed[i])) " | `" short[i] "` |"
      print ""
      print "## Not yet placed"
      for (i = 1; i <= np; i++) {
        p = projects[i]
        if (done[p] + 0 == total[p]) continue
        print ""
        print "### " p
        print ""
        for (j = 1; j <= n; j++) if (proj[j] == p && placed[j] == "") print "- " date[j] ", " task[j] ", `" short[j] "`: " words[j]
      }
    }
  ' > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$out" || { rm -f "$tmp"; return 1; }
  echo "indexed $(printf '%s\n' "$rows" | wc -l | tr -d ' ') owner note(s) into $out"
}

place() {  # <project> <entry-hash> <file>:<line or heading>
  local project=$1 hash=$2 where=$3 dest full count tmp rc=0
  dest=$(owner_notes_file "$project") || { echo "error: invalid project name: $project" >&2; return 2; }
  [ -f "$dest" ] || { echo "error: no owner notes for $project at $dest" >&2; return 1; }
  [[ $hash =~ ^[0-9a-f]{6,64}$ ]] || { echo "error: the entry hash must be 6 to 64 lowercase hex characters, as the index prints it: $hash" >&2; return 2; }
  case "$where" in
    /*|*'-->'*|*'<!--'*|*$'\n'*|*$'\r'*)
      echo "error: the destination must be a repo-relative <file>:<line or heading> on one line, with no comment marks: $where" >&2
      return 2 ;;
  esac
  [[ $where =~ ^[^:]+:.+$ ]] || { echo "error: the destination must be <repo-relative file>:<line or heading>: $where" >&2; return 2; }
  OWNER_NOTES_LOCK="$dest.lock"
  fm_lock_acquire_wait "$OWNER_NOTES_LOCK"
  trap 'fm_lock_release "$OWNER_NOTES_LOCK" || true; rm -f "${tmp:-}"' EXIT
  full=$(sed -n "s/^<!-- fm-owner-notes task=[^ ]* file=.* sha256=\\(${hash}[0-9a-f]*\\) -->\$/\\1/p" "$dest" | sort -u)
  count=$(printf '%s' "$full" | grep -c . || true)
  if [ "$count" -ne 1 ]; then
    fm_lock_release "$OWNER_NOTES_LOCK" || true
    trap - EXIT
    if [ "$count" -eq 0 ]; then
      echo "error: no entry in $dest has the hash $hash; run: $0 index" >&2
    else
      echo "error: $count entries in $dest start with $hash; give more of the hash" >&2
    fi
    return 1
  fi
  tmp="$dest.place.$$"
  FM_PLACE_SHA=$full FM_PLACE_LINE="<!-- fm-owner-notes placed=$where -->" awk '
    BEGIN { sha = ENVIRON["FM_PLACE_SHA"]; want = ENVIRON["FM_PLACE_LINE"] }
    {
      if (pending) {
        if ($0 ~ /^<!-- fm-owner-notes placed=.* -->$/) { if ($0 "" == want "") seen = 1; print; next }
        if (!seen) { print want; added++ }
        pending = 0
      }
      print
      if ($0 ~ /^<!-- fm-owner-notes task=/ && index($0, " sha256=" sha " -->")) { pending = 1; seen = 0 }
    }
    END { if (pending && !seen) { print want; added++ }; exit(added ? 0 : 3) }
  ' "$dest" > "$tmp" || rc=$?
  case "$rc" in
    0) mv -f "$tmp" "$dest"; echo "placed ${full:0:12} in $dest at $where" ;;
    3) rm -f "$tmp"; echo "${full:0:12} in $dest is already placed at $where" ;;
    *) rm -f "$tmp"; fm_lock_release "$OWNER_NOTES_LOCK" || true; trap - EXIT
       echo "error: could not write the placement into $dest" >&2; return 1 ;;
  esac
  fm_lock_release "$OWNER_NOTES_LOCK" || true
  trap - EXIT
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  file)
    [ "$#" -eq 2 ] || { echo "usage: fm-owner-notes.sh file <project-name>" >&2; exit 2; }
    owner_notes_file "$2"
    ;;
  collect)
    [ "$#" -eq 4 ] || { echo "usage: fm-owner-notes.sh collect <task-id> (--project <name> | --project-path <path>)" >&2; exit 2; }
    case "$3" in
      --project) collect "$2" "$4" ;;
      --project-path) collect "$2" "$(project_name_for_path "$4")" ;;
      *) echo "usage: fm-owner-notes.sh collect <task-id> (--project <name> | --project-path <path>)" >&2; exit 2 ;;
    esac
    ;;
  backfill)
    [ "$#" -eq 1 ] || { echo "usage: fm-owner-notes.sh backfill" >&2; exit 2; }
    backfill
    ;;
  index)
    [ "$#" -eq 1 ] || { echo "usage: fm-owner-notes.sh index" >&2; exit 2; }
    write_index
    ;;
  place)
    [ "$#" -eq 4 ] || { echo "usage: fm-owner-notes.sh place <project-name> <entry-hash> <file>:<line or heading>" >&2; exit 2; }
    place "$2" "$3" "$4"
    ;;
  *) usage >&2; exit 2 ;;
esac
