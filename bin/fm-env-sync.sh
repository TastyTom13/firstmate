#!/usr/bin/env bash
# fm-env-sync.sh - mirror shared keys from Automic Vault into each project's
# gitignored env file, so one vault entry serves every project and unattended
# workers keep working.
#
# THIS IS THE CAPTAIN'S COMMAND, NEVER A WORKER'S. Every `av inject` costs one
# human approval pop-up, so a crewmate, a scout, a watcher poll or any other
# unattended process that runs this hangs on a dialog nobody is there to click.
# Unattended work is exactly what the mirror exists to keep running: a worker
# reads the mirrored file and never calls the vault at all.
#
# Usage:
#   fm-env-sync.sh check [--project <name>]...
#   fm-env-sync.sh apply [--project <name>]... [--dry-run]
#   fm-env-sync.sh projects
#
#   check      Report, names only, which mirrored lines are missing or differ
#              from the vault. Writes nothing.
#   apply      Rewrite only the configured lines in each project's env file,
#              creating the file at mode 600 when absent and leaving every other
#              line untouched.
#   projects   List the configured projects, their env files and key counts
#              without calling the vault at all.
#
# Options:
#   --project <name>   Restrict the run to this configured project; repeatable.
#                      Each project costs one approval pop-up, so a one-project
#                      run is the cheap way to re-sync a single mirror.
#   --dry-run          apply only: report exactly what apply would change and
#                      write nothing. It still reads the vault, so it still
#                      costs its approval pop-up.
#
# Exit codes:
#   0  every configured key is mirrored and matches the vault
#   1  usage error, unreadable configuration, or a failed vault read or write
#   3  the run completed but the mirrors are not fully in sync: a configured
#      name is not in the vault, a value cannot be carried by an env line, or
#      (check and --dry-run) a mirrored line is missing or differs
#
# Configuration: config/env-sync.toml in this home. docs/configuration.md
# "Project env mirrors (config/env-sync.toml)" owns the file's schema. An absent
# file is a refusal naming the path to write, never a silent no-op, because an
# empty run and a synced fleet would otherwise look identical.
#
# NO VALUE IS EVER PRINTED. Output names keys and reports one verdict per key.
# Vault values reach this script through a mode-600 file inside a private
# mode-700 temp directory removed on every exit path, because only the child
# process `av inject` starts ever holds them.
#
# Environment:
#   FM_HOME              operational home whose config/ and projects/ are used
#   FM_CONFIG_OVERRIDE   alternate config dir, mainly for tests
#   FM_ENV_SYNC_AV       av executable to run, mainly for tests (default: av)
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF_ABS="$SELF_DIR/$(basename "${BASH_SOURCE[0]}")"
FM_ROOT="$(cd "$SELF_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
CONFIG_FILE="$CONFIG/env-sync.toml"
AV="${FM_ENV_SYNC_AV:-av}"

die() {
  printf 'fm-env-sync: %s\n' "$1" >&2
  exit "${2:-1}"
}

usage() {
  cat <<'EOF'
fm-env-sync.sh - mirror shared keys from Automic Vault into project env files.
This is the captain's command, never a worker's: every vault read costs one
human approval pop-up, which no unattended process can answer.

  fm-env-sync.sh check [--project <name>]...
  fm-env-sync.sh apply [--project <name>]... [--dry-run]
  fm-env-sync.sh projects

  check      report, names only, which mirrored lines are missing or differ
  apply      rewrite only the configured lines, creating the file at mode 600
  projects   list configured projects without reading the vault

  --project <name>   restrict to one configured project; repeatable
  --dry-run          apply only: report the changes and write nothing

Exit 0 in sync, 1 usage or hard failure, 3 completed but not in sync.
Configuration: config/env-sync.toml (docs/configuration.md).
EOF
}

# --- internal value transport ----------------------------------------------
#
# Runs as the child of `av inject`, the only process that ever holds the vault
# values. Writes KEY<TAB>base64(value) for every injected key that is set and
# non-empty, to the named file only - never to stdout, which the parent relays
# to the terminal.
if [ "${1:-}" = "emit-values" ]; then
  shift
  [ "$#" -ge 1 ] || die "emit-values requires an output path"
  emit_out=$1
  shift
  umask 077
  : > "$emit_out" || die "cannot write $emit_out"
  for emit_key in "$@"; do
    emit_val=${!emit_key:-}
    [ -n "$emit_val" ] || continue
    printf '%s\t%s\n' "$emit_key" "$(printf '%s' "$emit_val" | base64 | tr -d '\n')" >> "$emit_out"
  done
  exit 0
fi

# --- configuration ----------------------------------------------------------

# Parse config/env-sync.toml into one TSV record per project:
#   <name><TAB><path><TAB><file><TAB>export|plain<TAB><space-separated key names>
# No column is ever empty, because tab is IFS whitespace and bash's `read`
# collapses a run of it, which would silently shift every later field.
# The accepted subset is deliberately small and every other construction is a
# refusal naming the line, because a TOML feature this parser silently
# mis-reads would mirror the wrong name into a real project's secrets file.
parse_config() {
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function bad(msg) { printf "line %d: %s\n", NR, msg > "/dev/stderr"; exit 2 }
    function add_item(item,   name) {
      name = trim(item)
      if (name == "") return
      if (name !~ /^"[A-Za-z_][A-Za-z0-9_]*"$/) bad("keys entry must be a quoted variable name: " name)
      name = substr(name, 2, length(name) - 2)
      if (index(" " keys[project] " ", " " name " ") > 0) bad("duplicate key " name " in [" project "]")
      keys[project] = (keys[project] == "" ? name : keys[project] " " name)
    }
    function consume_items(rest,   n, i, parts) {
      n = split(rest, parts, ",")
      for (i = 1; i <= n; i++) add_item(parts[i])
    }
    {
      line = trim($0)
      if (line == "" || line ~ /^#/) next
      if (in_keys) {
        if (index(line, "]") > 0) {
          consume_items(substr(line, 1, index(line, "]") - 1))
          if (trim(substr(line, index(line, "]") + 1)) != "") bad("trailing text after ]")
          in_keys = 0
        } else {
          consume_items(line)
        }
        next
      }
      if (line ~ /^\[/) {
        if (line !~ /^\[[A-Za-z0-9._-]+\]$/) bad("expected a [project] table header: " line)
        project = substr(line, 2, length(line) - 2)
        if (project in seen) bad("duplicate project [" project "]")
        seen[project] = 1
        order[++count] = project
        next
      }
      if (project == "") bad("value outside any [project] table: " line)
      if (line !~ /^[A-Za-z_]+[ \t]*=/) bad("expected name = value: " line)
      field = trim(substr(line, 1, index(line, "=") - 1))
      rest = trim(substr(line, index(line, "=") + 1))
      if (field == "path" || field == "file") {
        if (rest !~ /^"[^"]*"$/) bad(field " must be a double-quoted string")
        value = substr(rest, 2, length(rest) - 2)
        if (value == "") bad(field " must not be empty")
        if (field == "path") {
          if (project in path) bad("duplicate path in [" project "]")
          path[project] = value
        } else {
          if (project in envfile) bad("duplicate file in [" project "]")
          if (value ~ /\//) bad("file must be a bare filename, not a path")
          envfile[project] = value
        }
        next
      }
      if (field == "export") {
        if (rest != "true" && rest != "false") bad("export must be true or false")
        if (project in exported) bad("duplicate export in [" project "]")
        exported[project] = (rest == "true")
        next
      }
      if (field == "keys") {
        if (keys[project] != "") bad("duplicate keys in [" project "]")
        if (substr(rest, 1, 1) != "[") bad("keys must be an array")
        rest = substr(rest, 2)
        if (index(rest, "]") > 0) {
          consume_items(substr(rest, 1, index(rest, "]") - 1))
          if (trim(substr(rest, index(rest, "]") + 1)) != "") bad("trailing text after ]")
        } else {
          consume_items(rest)
          in_keys = 1
        }
        next
      }
      bad("unknown field " field)
    }
    END {
      if (in_keys) bad("unterminated keys array")
      if (count == 0) bad("no [project] table configured")
      for (i = 1; i <= count; i++) {
        p = order[i]
        if (!(p in path)) { printf "[%s] has no path\n", p > "/dev/stderr"; exit 2 }
        if (keys[p] == "") { printf "[%s] has no keys\n", p > "/dev/stderr"; exit 2 }
        printf "%s\t%s\t%s\t%s\t%s\n", p, path[p], (p in envfile ? envfile[p] : ".env.local"), ((p in exported) && exported[p] ? "export" : "plain"), keys[p]
      }
    }
  ' "$1"
}

load_config() {
  [ -f "$CONFIG_FILE" ] \
    || die "no mirror configuration; write $CONFIG_FILE (see docs/configuration.md \"Project env mirrors\")"
  RECORDS=$(parse_config "$CONFIG_FILE") || die "cannot read $CONFIG_FILE"
  [ -n "$RECORDS" ] || die "no [project] table configured in $CONFIG_FILE"
}

# Echo the absolute env-file path for a configured project path and filename. A
# relative path resolves against FM_HOME so one configuration works in every
# home; an absolute path is taken as given.
target_path() {
  local proj_path=$1 env_file=$2
  case "$proj_path" in
    /*) printf '%s/%s\n' "${proj_path%/}" "$env_file" ;;
    *) printf '%s/%s/%s\n' "$FM_HOME" "${proj_path%/}" "$env_file" ;;
  esac
}

# --- vault reads ------------------------------------------------------------

# The names the vault holds. Read once per run: `av list` prints names only and
# costs no approval, so it is what keeps a name the vault does not hold out of
# an injection that would fail only after the captain clicked.
vault_names() {
  "$AV" list 2>/dev/null || die "cannot read the vault with '$AV list'"
}

# Fetch the named keys into one values file through a single `av inject`. One
# call per project, because each one costs the captain an approval pop-up.
fetch_values() {
  local out=$1
  shift
  local plus=() key
  for key in "$@"; do
    plus+=("+$key")
  done
  "$AV" inject "${plus[@]}" -- "${BASH:-bash}" "$SELF_ABS" emit-values "$out" "$@"
}

# Echo the decoded value for one key from a values file, or return 1 when the
# injection delivered no value for it.
value_of() {
  local file=$1 key=$2 encoded
  encoded=$(awk -F '\t' -v k="$key" '$1 == k { print $2; found = 1; exit } END { exit found ? 0 : 1 }' "$file") \
    || return 1
  printf '%s' "$encoded" | base64 -d
}

# Echo the value the mirror currently carries for one key, or return 1 when the
# file has no line for it. One layer of matching surrounding quotes is stripped,
# because `KEY="value"` and `KEY=value` carry the same value to every env-file
# reader and must not be reported as a difference.
mirror_value() {
  local file=$1 prefix=$2 key=$3 line value
  [ -f "$file" ] || return 1
  line=$(awk -v k="$prefix$key=" '
    index($0, k) == 1 {
      count++
      if (count == 1) line = $0
    }
    END {
      if (count > 1) exit 2
      if (count == 1) { print line; exit 0 }
      exit 1
    }
  ' "$file") || return $?
  value=${line#"$prefix$key="}
  if [ ${#value} -ge 2 ]; then
    case "$value" in
      '"'*'"') value=${value:1:${#value}-2} ;;
      "'"*"'") value=${value:1:${#value}-2} ;;
    esac
  fi
  printf '%s' "$value"
}

# A bare `KEY=value` line cannot carry a line break or edge whitespace, so a
# value needing one is refused rather than written back mangled.
value_is_writable() {
  case "$1" in
    *$'\n'* | *$'\r'* | ' '* | *' ' | $'\t'* | *$'\t') return 1 ;;
  esac
  return 0
}

# --- mirror rewrite ---------------------------------------------------------

# Rewrite only the named lines of one env file. Every other line - comments,
# blanks, ordering, unrelated keys - survives byte for byte, and a configured
# key with no line yet is appended. The new content is built in a temp file in
# the same directory and always lands at mode 600.
rewrite_mirror() {
  local file=$1 prefix=$2 values=$3
  shift 3
  local dir tmp next key value rc=0
  dir=$(dirname "$file")
  [ -d "$dir" ] || return 1
  (
    umask 077
    tmp=$(mktemp "$dir/.fm-env-sync.XXXXXX") || exit 1
    next="$tmp.next"
    trap 'rm -f "$tmp" "$next"' EXIT
    if [ -f "$file" ]; then
      cat "$file" > "$tmp" || exit 1
    fi
    for key in "$@"; do
      value=$(value_of "$values" "$key") || exit 1
      FM_ENV_SYNC_LHS="$prefix$key" FM_ENV_SYNC_VALUE="$value" \
        LC_ALL=C perl -0777 -e '
          local $/;
          open my $fh, "<", $ARGV[0] or exit 1;
          binmode $fh;
          my $text = <$fh> // "";
          close $fh or exit 1;
          my ($lhs, $value) = @ENV{qw(FM_ENV_SYNC_LHS FM_ENV_SYNC_VALUE)};
          my $line = qr/^\Q$lhs\E=[^\r\n]*(\r?\n|\z)/m;
          if ($text =~ $line) {
            $text =~ s/$line/$lhs . "=" . $value . $1/e;
          } else {
            $text .= "\n" if length($text) && substr($text, -1) ne "\n";
            $text .= $lhs . "=" . $value . "\n";
          }
          binmode STDOUT;
          print $text;
        ' "$tmp" > "$next" || exit 1
      mv "$next" "$tmp" || exit 1
    done
    chmod 600 "$tmp" || exit 1
    mv "$tmp" "$file" || exit 1
    trap - EXIT
  ) || rc=1
  [ "$rc" -eq 0 ] || return 1
  chmod 600 "$file"
}

# --- run --------------------------------------------------------------------

report() {
  printf '  %-28s %s\n' "$1" "$2"
}

# Run one project through check or apply and print its report. Returns 0 in
# sync, 1 out of sync, 4 on a hard vault or write failure.
run_project() {
  local mode=$1 name=$2 proj_path=$3 env_file=$4 line_form=$5 key_list=$6
  local prefix=''
  if [ "$line_form" = export ]; then
    prefix='export '
  fi
  local target keys=() key want have have_status
  local absent=() present=() pending=()
  local mirrorable=0
  local gap=0
  local values="$WORK/values.tsv"
  read -r -a keys <<< "$key_list"
  target=$(target_path "$proj_path" "$env_file")

  printf '%s (%s)\n' "$name" "$target"

  # A mirror reached through a symlink is refused rather than rewritten: the
  # rewrite lands its temp file over the target, which would replace the link
  # with a regular file and silently detach it from whatever it pointed at.
  if [ -L "$target" ]; then
    report "(mirror)" "symlinked-target-refused"
    return 1
  fi

  for key in "${keys[@]}"; do
    if printf '%s\n' "$VAULT_NAMES" | grep -qxF -- "$key"; then
      present+=("$key")
    else
      absent+=("$key")
    fi
  done

  for key in ${absent[@]+"${absent[@]}"}; do
    report "$key" "not-in-vault"
    gap=1
  done

  if [ "${#present[@]}" -eq 0 ]; then
    return "$gap"
  fi

  rm -f "$values"
  if ! fetch_values "$values" ${present[@]+"${present[@]}"}; then
    printf 'fm-env-sync: vault read failed for %s\n' "$name" >&2
    return 4
  fi
  [ -f "$values" ] || : > "$values"

  for key in "${present[@]}"; do
    if ! want=$(value_of "$values" "$key"); then
      report "$key" "vault-value-unset"
      gap=1
      continue
    fi
    if ! value_is_writable "$want"; then
      report "$key" "value-not-mirrorable"
      gap=1
      continue
    fi
    have_status=0
    have=$(mirror_value "$target" "$prefix" "$key") || have_status=$?
    if [ "$have_status" -eq 2 ]; then
      report "$key" "duplicate-key-lines"
      gap=1
      continue
    fi
    mirrorable=1
    if [ "$have_status" -eq 0 ]; then
      if [ "$have" = "$want" ]; then
        report "$key" "in-sync"
        continue
      fi
      if [ "$mode" = apply ] && [ "$DRY_RUN" -eq 0 ]; then
        report "$key" "updated"
      else
        report "$key" "differs"
      fi
    else
      if [ "$mode" = apply ] && [ "$DRY_RUN" -eq 0 ]; then
        report "$key" "added"
      else
        report "$key" "missing"
      fi
    fi
    pending+=("$key")
  done

  if [ "${#pending[@]}" -eq 0 ]; then
    if [ "$mode" = apply ] && [ "$DRY_RUN" -eq 0 ] && [ "$mirrorable" -eq 1 ] && [ -f "$target" ]; then
      chmod 600 "$target" || return 4
    fi
    return "$gap"
  fi

  if [ "$mode" != apply ] || [ "$DRY_RUN" -eq 1 ]; then
    [ "$mode" = apply ] && report "(dry run)" "nothing written"
    return 1
  fi

  if ! rewrite_mirror "$target" "$prefix" "$values" "${pending[@]}"; then
    printf 'fm-env-sync: cannot write %s\n' "$target" >&2
    return 4
  fi
  return "$gap"
}

main() {
  local mode=${1:-}
  case "$mode" in
    check | apply | projects) shift ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    '')
      usage >&2
      exit 1
      ;;
    *) die "unknown command: $mode" ;;
  esac

  DRY_RUN=0
  local wanted=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --project)
        [ "$#" -gt 1 ] || die "--project requires a name"
        wanted+=("$2")
        shift 2
        ;;
      --project=*)
        wanted+=("${1#--project=}")
        shift
        ;;
      --dry-run)
        [ "$mode" = apply ] || die "--dry-run applies to apply only"
        DRY_RUN=1
        shift
        ;;
      *) die "unknown option: $1" ;;
    esac
  done

  load_config

  local selected=$RECORDS name
  if [ "${#wanted[@]}" -gt 0 ]; then
    for name in "${wanted[@]}"; do
      printf '%s\n' "$RECORDS" \
        | awk -F '\t' -v n="$name" '$1 == n { found = 1 } END { exit found ? 0 : 1 }' \
        || die "no project named '$name' in $CONFIG_FILE"
    done
    selected=$(printf '%s\n' "$RECORDS" | awk -F '\t' -v list="${wanted[*]}" '
      BEGIN { n = split(list, w, " "); for (i = 1; i <= n; i++) want[w[i]] = 1 }
      $1 in want { print }
    ')
  fi

  if [ "$mode" = projects ]; then
    printf '%s\n' "$selected" \
      | awk -F '\t' 'NF { printf "%s\t%s/%s\t%d keys\n", $1, $2, $3, split($5, k, " ") }'
    exit 0
  fi

  command -v "$AV" >/dev/null 2>&1 || die "'$AV' not found; Automic Vault provides it"

  WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-env-sync.XXXXXX") || die "cannot create a private work directory"
  chmod 700 "$WORK"
  trap 'rm -rf "$WORK"' EXIT INT TERM

  VAULT_NAMES=$(vault_names)

  local status=0 rc proj_path env_file line_form key_list
  while IFS=$'\t' read -r name proj_path env_file line_form key_list; do
    [ -n "$name" ] || continue
    rc=0
    run_project "$mode" "$name" "$proj_path" "$env_file" "$line_form" "$key_list" || rc=$?
    case "$rc" in
      0) ;;
      1)
        if [ "$status" -eq 0 ]; then
          status=3
        fi
        ;;
      *) status=1 ;;
    esac
  done <<< "$selected"

  exit "$status"
}

main "$@"
