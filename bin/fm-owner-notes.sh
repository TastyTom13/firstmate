#!/usr/bin/env bash
# Keep the captain's own words from every ship and scout task in one durable
# file per project, so they outlive the task that heard them.
# A worker saves the captain's words verbatim, dated, with what it did with
# them, to data/<task-id>/captain-notes-<YYYY-MM-DD>.md (bin/fm-brief.sh owns
# that instruction). bin/fm-teardown.sh runs `collect` on cleanup, which appends
# every data/<task-id>/captain-notes-*.md, in name order, to
# data/owner-notes/<project>.md under a "## <date> - <task-id>" heading. The
# date comes from the file name, else the file's own modification date (UTC).
# Collection only ever appends: an earlier entry is never edited. Each entry
# carries a marker naming its task, file, and content hash, so a repeated
# collection appends nothing, while a notes file that grew after it was
# collected lands again whole as a new entry. The task's own copy stays in
# data/<task-id>/. Appends to one project file are serialized under a lock.
# A task whose project is this firstmate home or code root collects into
# data/owner-notes/firstmate.md; any other project collects into
# data/owner-notes/<basename of its project path>.md.
# bin/fm-brief.sh names data/owner-notes/<repo-name>.md as required reading in
# every ship and scout brief for that project once it exists, using `file`.
# Usage: fm-owner-notes.sh collect <task-id> (--project <name> | --project-path <path>)
#        fm-owner-notes.sh file <project-name>
#        fm-owner-notes.sh backfill
#   collect   append the task's captain-notes files to its project's owner notes.
#   file      print the owner-notes path for a project name; exit 1 when the
#             name is not a plain file-name-safe project name.
#   backfill  run collect once for every data/*/captain-notes-*.md already
#             present, resolving each task's project from its live
#             state/<task-id>.meta, else its brief's "worktree of <repo>" line.
#             A task whose project cannot be resolved is listed and skipped.
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

project_name_valid() {
  fm_task_id_path_safe "${1-}"
}

owner_notes_file() {  # <project-name>
  project_name_valid "$1" || return 1
  printf '%s/owner-notes/%s.md\n' "$DATA" "$1"
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
  case "$name" in
    captain-notes-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      printf '%s\n' "${name:14:10}" ;;
    *) date -u -r "$1" +%Y-%m-%d ;;
  esac
}

collect() {  # <task-id> <project-name>
  local id=$1 project=$2 dest file name marker sha appended=0
  local -a files=()
  fm_task_id_path_safe "$id" || { echo "error: invalid task id: $id" >&2; return 2; }
  dest=$(owner_notes_file "$project") || { echo "error: invalid project name: $project" >&2; return 2; }
  for file in "$DATA/$id"/captain-notes-*.md; do
    [ -f "$file" ] && [ ! -L "$file" ] && [ -s "$file" ] || continue
    files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 0
  mkdir -p "$DATA/owner-notes"
  OWNER_NOTES_LOCK="$dest.lock"
  fm_lock_acquire_wait "$OWNER_NOTES_LOCK"
  trap 'fm_lock_release "$OWNER_NOTES_LOCK" || true' EXIT
  if [ ! -e "$dest" ]; then
    printf '%s\n' "# Owner notes: $project" '' \
      "The captain's own words from Firstmate tasks on $project, verbatim, collected at each task's cleanup." \
      "Entries are appended in collection order and never edited." > "$dest"
  fi
  for file in "${files[@]}"; do
    name=$(basename "$file")
    sha=$(notes_sha256 "$file")
    marker="<!-- fm-owner-notes task=$id file=$name sha256=$sha -->"
    ! grep -Fqx -- "$marker" "$dest" || continue
    [ -z "$(tail -c 1 -- "$dest")" ] || printf '\n' >> "$dest"
    {
      printf '\n## %s - %s\n%s\nSource: %s\n\n' "$(notes_date "$file")" "$id" "$marker" "$name"
      cat -- "$file"
    } >> "$dest"
    appended=$((appended + 1))
  done
  fm_lock_release "$OWNER_NOTES_LOCK" || true
  trap - EXIT
  [ "$appended" -eq 0 ] || echo "collected $appended captain-notes file(s) from $id into $dest"
}

fm_meta_value() {  # <meta> <key>
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

backfill() {
  local dir id project path repo
  for dir in "$DATA"/*/; do
    dir=${dir%/}
    id=$(basename "$dir")
    [ "$id" != owner-notes ] || continue
    compgen -G "$dir/captain-notes-*.md" >/dev/null || continue
    project=
    if [ -f "$STATE/$id.meta" ]; then
      path=$(fm_meta_value "$STATE/$id.meta" project)
      [ -z "$path" ] || project=$(project_name_for_path "$path")
    fi
    if [ -z "$project" ] && [ -f "$dir/brief.md" ]; then
      repo=$(sed -n 's/^You are in a disposable git worktree of \([^,]*\), at a detached HEAD.*/\1/p' "$dir/brief.md" | head -n 1)
      [ -z "$repo" ] || project=$repo
    fi
    if [ -z "$project" ] || ! project_name_valid "$project"; then
      echo "skipped $id: no project could be resolved; run: $0 collect $id --project <name>" >&2
      continue
    fi
    collect "$id" "$project"
  done
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
  *) usage >&2; exit 2 ;;
esac
