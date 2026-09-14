#!/usr/bin/env bash
# Behavior tests for fm-env-sync.sh, the captain's vault-to-project env mirror.
#
# Every test drives the real script against a fake `av` on PATH, because the
# real one needs a human approval click that no test can answer. The fake logs
# each invocation, so the tests can assert the injection shape - one call per
# project, names only, never a value on a command line - as well as the file
# the mirror ends up with.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC="$ROOT/bin/fm-env-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-env-sync)

ALPHA_VALUE='alpha-value#with spaces'
BETA_VALUE='beta-value'

# Build a home with a fake `av` whose vault holds ALPHA_KEY and BETA_KEY.
# EMPTY_KEY is listed by the vault but injects nothing, which is how a saved
# name with no value reaches the script.
make_home() {
  local name=$1 home fakebin
  home="$TMP_ROOT/$name"
  mkdir -p "$home/config" "$home/projects"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/av" <<AV
#!/usr/bin/env bash
log="$home/av.log"
case "\$1" in
  list)
    printf 'call: list\n' >> "\$log"
    printf 'ALPHA_KEY\nBETA_KEY\nEMPTY_KEY\nNEWLINE_KEY\nTRAILING_NEWLINE_KEY\nDOUBLE_TRAILING_NEWLINE_KEY\n'
    ;;
  inject)
    shift
    printf 'call: inject %s\n' "\$*" >> "\$log"
    pairs=()
    while [ "\$1" != "--" ]; do
      case "\${1#+}" in
        ALPHA_KEY) pairs+=("ALPHA_KEY=$ALPHA_VALUE") ;;
        BETA_KEY) pairs+=("BETA_KEY=$BETA_VALUE") ;;
        NEWLINE_KEY) pairs+=("NEWLINE_KEY=first"\$'\n'"second") ;;
        TRAILING_NEWLINE_KEY) pairs+=("TRAILING_NEWLINE_KEY=last"\$'\n') ;;
        DOUBLE_TRAILING_NEWLINE_KEY) pairs+=("DOUBLE_TRAILING_NEWLINE_KEY=last"\$'\n\n') ;;
      esac
      shift
    done
    shift
    exec env "\${pairs[@]}" "\$@"
    ;;
  *)
    printf 'unexpected av call: %s\n' "\$*" >&2
    exit 64
    ;;
esac
AV
  chmod +x "$fakebin/av"
  printf '%s\n' "$home"
}

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

run_sync() {
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" "$SYNC" "$@"
}

test_projects_lists_configuration_without_touching_the_vault() {
  local home out status=0
  home=$(make_home projects-listing)
  mkdir -p "$home/projects/scout"
  cat > "$home/config/env-sync.toml" <<'TOML'
# a comment line is ignored
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY", "BETA_KEY"]

[bull]
path = "projects/bull"
file = ".envrc"
export = true
keys = [
  "ALPHA_KEY",
]
TOML
  out=$(run_sync "$home" projects 2>&1) || status=$?
  expect_code 0 "$status" "projects listing"
  assert_contains "$out" "scout	projects/scout/.env.local	2 keys" "scout row"
  assert_contains "$out" "bull	projects/bull/.envrc	1 keys" "bull row"
  assert_absent "$home/av.log" "projects listing called the vault"
  pass "projects lists the configured mirrors without reading the vault"
}

test_apply_rewrites_only_configured_lines() {
  local home target out status=0 mode
  home=$(make_home apply-surgical)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  cat > "$target" <<'ENV'
# scout local environment
OTHER_SECRET=keep-me
ALPHA_KEY=stale

DATABASE_URL=postgres://keep
ENV
  chmod 644 "$target"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY", "BETA_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 0 "$status" "apply exit"
  assert_contains "$out" "ALPHA_KEY                    updated" "updated verdict"
  assert_contains "$out" "BETA_KEY                     added" "added verdict"

  assert_exact_line "$target" "# scout local environment" "comment line lost"
  assert_exact_line "$target" "OTHER_SECRET=keep-me" "unrelated key lost"
  assert_exact_line "$target" "DATABASE_URL=postgres://keep" "unrelated key lost"
  assert_exact_line "$target" "ALPHA_KEY=$ALPHA_VALUE" "configured key not rewritten in place"
  assert_exact_line "$target" "BETA_KEY=$BETA_VALUE" "absent configured key not appended"
  assert_no_grep "ALPHA_KEY=stale" "$target" "stale value survived the rewrite"
  [ "$(awk 'NR == 4 { print }' "$target")" = "" ] || fail "the blank line moved"

  mode=$(file_mode "$target")
  [ "$mode" = "600" ] || fail "apply left mode $mode, not 600"

  assert_grep "call: inject +ALPHA_KEY +BETA_KEY --" "$home/av.log" "one inject with both names"
  [ "$(grep -c 'call: inject' "$home/av.log")" = "1" ] \
    || fail "apply used more than one injection for one project"
  assert_no_grep "$ALPHA_VALUE" "$home/av.log" "a value reached the av command line"
  pass "apply rewrites only the configured lines and lands the file at mode 600"
}

test_apply_tightens_an_already_synced_mirror_in_place() {
  local home target before out status=0 mode
  home=$(make_home tighten-mode)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  printf 'ALPHA_KEY=%s\nOTHER=keep\n' "$ALPHA_VALUE" > "$target"
  chmod 644 "$target"
  before=$(cksum "$target")
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 0 "$status" "already-synced apply exit"
  assert_contains "$out" "ALPHA_KEY                    in-sync" "already-synced verdict"
  mode=$(file_mode "$target")
  [ "$mode" = "600" ] || fail "already-synced apply left mode $mode"
  [ "$(cksum "$target")" = "$before" ] || fail "mode tightening rewrote content"
  pass "apply tightens an already-synced mirror without rewriting it"
}

test_apply_preserves_an_unterminated_unrelated_line() {
  local home target expected status=0
  home=$(make_home unterminated-line)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  expected="$home/expected.env"
  printf 'ALPHA_KEY=%s\nOTHER=keep' "$ALPHA_VALUE" > "$target"
  printf 'ALPHA_KEY=%s\nOTHER=keep' "$ALPHA_VALUE" > "$expected"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY"]
TOML
  run_sync "$home" apply >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "unterminated-line apply exit"
  cmp -s "$target" "$expected" || fail "untouched unterminated line changed"
  pass "apply preserves an unrelated final line without a newline"
}

test_duplicate_configured_lines_are_refused() {
  local home target out status=0
  home=$(make_home duplicate-lines)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  printf 'ALPHA_KEY=first\nALPHA_KEY=second\n' > "$target"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 3 "$status" "duplicate-line apply exit"
  assert_contains "$out" "ALPHA_KEY                    duplicate-key-lines" "duplicate-line verdict"
  assert_exact_line "$target" "ALPHA_KEY=first" "duplicate mirror was rewritten"
  assert_exact_line "$target" "ALPHA_KEY=second" "duplicate mirror was rewritten"
  pass "apply refuses ambiguous duplicate configured lines"
}

test_apply_creates_an_absent_mirror_at_mode_600() {
  local home target status=0 mode
  home=$(make_home apply-create)
  mkdir -p "$home/projects/fresh"
  target="$home/projects/fresh/.env.local"
  cat > "$home/config/env-sync.toml" <<'TOML'
[fresh]
path = "projects/fresh"
keys = ["BETA_KEY"]
TOML
  run_sync "$home" apply >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "apply exit for a new mirror"
  assert_present "$target" "apply did not create the absent mirror"
  assert_exact_line "$target" "BETA_KEY=$BETA_VALUE" "created mirror has no key line"
  mode=$(file_mode "$target")
  [ "$mode" = "600" ] || fail "created mirror is mode $mode, not 600"
  pass "apply creates an absent mirror at mode 600"
}

test_no_value_is_ever_printed() {
  local home out status=0
  home=$(make_home no-value-printed)
  mkdir -p "$home/projects/scout"
  printf 'ALPHA_KEY=stale\n' > "$home/projects/scout/.env.local"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY", "BETA_KEY"]
TOML
  out=$(run_sync "$home" check 2>&1) || status=$?
  assert_not_contains "$out" "$ALPHA_VALUE" "check printed a vault value"
  assert_not_contains "$out" "$BETA_VALUE" "check printed a vault value"
  assert_not_contains "$out" "stale" "check printed a mirrored value"
  out=$(run_sync "$home" apply --dry-run 2>&1) || status=$?
  assert_not_contains "$out" "$ALPHA_VALUE" "dry run printed a vault value"
  out=$(run_sync "$home" apply 2>&1) || status=$?
  assert_not_contains "$out" "$ALPHA_VALUE" "apply printed a vault value"
  assert_not_contains "$out" "$BETA_VALUE" "apply printed a vault value"
  pass "no run prints a vault or mirrored value"
}

test_check_reports_names_only_and_writes_nothing() {
  local home target before out status=0
  home=$(make_home check-report)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  printf 'ALPHA_KEY=stale\nOTHER=keep\n' > "$target"
  before=$(cat "$target")
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY", "BETA_KEY", "GONE_KEY"]
TOML
  out=$(run_sync "$home" check 2>&1) || status=$?
  expect_code 3 "$status" "check exit when mirrors are out of sync"
  assert_contains "$out" "ALPHA_KEY                    differs" "differs verdict"
  assert_contains "$out" "BETA_KEY                     missing" "missing verdict"
  assert_contains "$out" "GONE_KEY                     not-in-vault" "not-in-vault verdict"
  [ "$(cat "$target")" = "$before" ] || fail "check modified the mirror"

  run_sync "$home" apply >/dev/null 2>&1
  status=0
  out=$(run_sync "$home" check 2>&1) || status=$?
  expect_code 3 "$status" "check still reports the name the vault does not hold"
  assert_contains "$out" "ALPHA_KEY                    in-sync" "in-sync verdict after apply"
  assert_contains "$out" "BETA_KEY                     in-sync" "in-sync verdict after apply"
  pass "check reports names only, writes nothing, and exits 3 while out of sync"
}

test_dry_run_reports_the_same_work_and_writes_nothing() {
  local home target before out status=0
  home=$(make_home dry-run)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  printf 'ALPHA_KEY=stale\n' > "$target"
  before=$(cat "$target")
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY", "BETA_KEY"]
TOML
  out=$(run_sync "$home" apply --dry-run 2>&1) || status=$?
  expect_code 3 "$status" "dry run exit"
  assert_contains "$out" "ALPHA_KEY                    differs" "dry run differs verdict"
  assert_contains "$out" "BETA_KEY                     missing" "dry run missing verdict"
  assert_contains "$out" "nothing written" "dry run did not say it wrote nothing"
  [ "$(cat "$target")" = "$before" ] || fail "dry run modified the mirror"
  assert_absent "$home/projects/scout/.env.local.next" "dry run left a scratch file"
  pass "--dry-run reports the pending work and writes nothing"
}

test_name_the_vault_does_not_hold_is_never_injected() {
  local home out status=0
  home=$(make_home not-in-vault)
  mkdir -p "$home/projects/scout"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["GONE_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 3 "$status" "apply exit with no mirrorable name"
  assert_contains "$out" "GONE_KEY                     not-in-vault" "not-in-vault verdict"
  assert_no_grep "call: inject" "$home/av.log" "a name the vault lacks was still injected"
  assert_absent "$home/projects/scout/.env.local" "a mirror was created with nothing to write"
  pass "a name the vault does not hold costs no injection and no file"
}

test_vault_name_with_no_value_is_reported_not_mirrored() {
  local home out status=0
  home=$(make_home empty-value)
  mkdir -p "$home/projects/scout"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["EMPTY_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 3 "$status" "apply exit for an unset vault value"
  assert_contains "$out" "EMPTY_KEY                    vault-value-unset" "unset verdict"
  assert_absent "$home/projects/scout/.env.local" "an unset value still created a mirror"
  pass "a saved name that injects no value is reported, not mirrored"
}

test_trailing_newline_value_is_refused() {
  local home target out status=0
  home=$(make_home trailing-newline)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  printf 'OTHER=keep\n' > "$target"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["TRAILING_NEWLINE_KEY", "DOUBLE_TRAILING_NEWLINE_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 3 "$status" "trailing-newline apply exit"
  assert_contains "$out" "TRAILING_NEWLINE_KEY" "trailing-newline key verdict"
  assert_contains "$out" "DOUBLE_TRAILING_NEWLINE_KEY" "double-trailing-newline key verdict"
  assert_contains "$out" "value-not-mirrorable" "trailing-newline refusal verdict"
  assert_no_grep "TRAILING_NEWLINE_KEY" "$target" "trailing-newline value was mirrored"
  assert_no_grep "DOUBLE_TRAILING_NEWLINE_KEY" "$target" "double-trailing-newline value was mirrored"
  assert_exact_line "$target" "OTHER=keep" "trailing-newline refusal disturbed the mirror"
  pass "a vault value ending in a newline is refused"
}

test_value_an_env_line_cannot_carry_is_refused() {
  local home target out status=0
  home=$(make_home unsafe-value)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  printf 'OTHER=keep\n' > "$target"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["NEWLINE_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 3 "$status" "apply exit for a value no env line can carry"
  assert_contains "$out" "NEWLINE_KEY                  value-not-mirrorable" "unmirrorable verdict"
  assert_no_grep "NEWLINE_KEY" "$target" "a multi-line value was written into the mirror"
  assert_exact_line "$target" "OTHER=keep" "the refusal disturbed the rest of the mirror"
  pass "a value a bare env line cannot carry is refused, not mangled"
}

test_quoted_mirror_value_matches_the_vault() {
  local home target before out status=0
  home=$(make_home quoted-value)
  mkdir -p "$home/projects/scout"
  target="$home/projects/scout/.env.local"
  printf 'ALPHA_KEY="%s"\n' "$ALPHA_VALUE" > "$target"
  before=$(cat "$target")
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 0 "$status" "apply exit for an already-quoted match"
  assert_contains "$out" "ALPHA_KEY                    in-sync" "quoted match verdict"
  [ "$(cat "$target")" = "$before" ] || fail "a quoted but equal value was needlessly rewritten"
  pass "a quoted mirror value equal to the vault is left alone"
}

test_export_style_mirror_keeps_its_prefix() {
  local home target status=0
  home=$(make_home export-style)
  mkdir -p "$home/projects/bull"
  target="$home/projects/bull/.envrc"
  printf 'export ALPHA_KEY=stale\nexport OTHER=keep\n' > "$target"
  cat > "$home/config/env-sync.toml" <<'TOML'
[bull]
path = "projects/bull"
file = ".envrc"
export = true
keys = ["ALPHA_KEY", "BETA_KEY"]
TOML
  run_sync "$home" apply >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "apply exit for an export-style mirror"
  assert_exact_line "$target" "export ALPHA_KEY=$ALPHA_VALUE" "export line not rewritten in place"
  assert_exact_line "$target" "export BETA_KEY=$BETA_VALUE" "appended line lost its export prefix"
  assert_exact_line "$target" "export OTHER=keep" "unrelated export line lost"
  assert_no_grep "export ALPHA_KEY=stale" "$target" "stale export value survived"
  pass "an export-style mirror keeps the prefix on rewritten and appended lines"
}

# Regression: the per-project record travels as tab-separated fields, and tab is
# IFS whitespace, so bash's `read` collapses a run of it. A project without the
# optional `export` field must not lose its key list to that collapse.
test_project_without_optional_fields_still_syncs() {
  local home out status=0
  home=$(make_home optional-fields)
  mkdir -p "$home/projects/scout" "$home/projects/bull"
  printf 'export ALPHA_KEY=stale\n' > "$home/projects/bull/.envrc"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY"]

[bull]
path = "projects/bull"
file = ".envrc"
export = true
keys = ["ALPHA_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 0 "$status" "apply exit with mixed optional fields"
  assert_contains "$out" "ALPHA_KEY                    added" "the plain project reported no key work"
  assert_exact_line "$home/projects/scout/.env.local" "ALPHA_KEY=$ALPHA_VALUE" \
    "the project without an export field was skipped"
  assert_exact_line "$home/projects/bull/.envrc" "export ALPHA_KEY=$ALPHA_VALUE" \
    "the export project was skipped"
  pass "a project that omits the optional fields still gets its keys"
}

test_project_filter_selects_one_mirror() {
  local home out status=0
  home=$(make_home project-filter)
  mkdir -p "$home/projects/scout" "$home/projects/forge"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY"]

[forge]
path = "projects/forge"
keys = ["BETA_KEY"]
TOML
  out=$(run_sync "$home" apply --project forge 2>&1) || status=$?
  expect_code 0 "$status" "filtered apply exit"
  assert_contains "$out" "forge" "filtered run skipped the named project"
  assert_not_contains "$out" "scout" "filtered run touched an unnamed project"
  assert_present "$home/projects/forge/.env.local" "filtered run wrote no mirror"
  assert_absent "$home/projects/scout/.env.local" "filtered run wrote an unnamed project"
  [ "$(grep -c 'call: inject' "$home/av.log")" = "1" ] \
    || fail "filtered run paid more than one approval"

  status=0
  out=$(run_sync "$home" apply --project nosuch 2>&1) || status=$?
  expect_code 1 "$status" "unknown project exit"
  assert_contains "$out" "no project named 'nosuch'" "unknown project refusal"
  pass "--project runs exactly one mirror and refuses an unknown name"
}

test_absent_configuration_refuses_with_the_path() {
  local home out status=0
  home=$(make_home no-config)
  out=$(run_sync "$home" check 2>&1) || status=$?
  expect_code 1 "$status" "absent configuration exit"
  assert_contains "$out" "$home/config/env-sync.toml" "refusal did not name the path to write"
  assert_absent "$home/av.log" "absent configuration still called the vault"
  pass "an absent configuration refuses with the path to write"
}

test_malformed_configuration_refuses_naming_the_line() {
  local home out status=0
  home=$(make_home bad-config)
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY", ALPHA_KEY]
TOML
  out=$(run_sync "$home" check 2>&1) || status=$?
  expect_code 1 "$status" "malformed configuration exit"
  assert_contains "$out" "line 3" "refusal did not name the offending line"
  assert_absent "$home/av.log" "malformed configuration still called the vault"

  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
TOML
  status=0
  out=$(run_sync "$home" check 2>&1) || status=$?
  expect_code 1 "$status" "keyless project exit"
  assert_contains "$out" "has no keys" "keyless project refusal"
  pass "a malformed configuration refuses naming the problem"
}

test_symlinked_mirror_is_refused() {
  local home target real out status=0
  home=$(make_home symlinked-mirror)
  mkdir -p "$home/projects/scout"
  real="$home/projects/real.env"
  target="$home/projects/scout/.env.local"
  printf 'ALPHA_KEY=stale\n' > "$real"
  ln -s "$real" "$target"
  cat > "$home/config/env-sync.toml" <<'TOML'
[scout]
path = "projects/scout"
keys = ["ALPHA_KEY"]
TOML
  out=$(run_sync "$home" apply 2>&1) || status=$?
  expect_code 3 "$status" "apply exit for a symlinked mirror"
  assert_contains "$out" "symlinked-target-refused" "symlink refusal verdict"
  [ -L "$target" ] || fail "apply replaced the symlink with a regular file"
  assert_exact_line "$real" "ALPHA_KEY=stale" "apply wrote through the refused symlink"
  assert_no_grep "call: inject" "$home/av.log" "a refused mirror still cost an approval"
  pass "a mirror reached through a symlink is refused, not replaced"
}

test_projects_lists_configuration_without_touching_the_vault
test_apply_rewrites_only_configured_lines
test_apply_tightens_an_already_synced_mirror_in_place
test_apply_preserves_an_unterminated_unrelated_line
test_duplicate_configured_lines_are_refused
test_apply_creates_an_absent_mirror_at_mode_600
test_no_value_is_ever_printed
test_check_reports_names_only_and_writes_nothing
test_dry_run_reports_the_same_work_and_writes_nothing
test_name_the_vault_does_not_hold_is_never_injected
test_vault_name_with_no_value_is_reported_not_mirrored
test_value_an_env_line_cannot_carry_is_refused
test_trailing_newline_value_is_refused
test_quoted_mirror_value_matches_the_vault
test_export_style_mirror_keeps_its_prefix
test_project_without_optional_fields_still_syncs
test_project_filter_selects_one_mirror
test_absent_configuration_refuses_with_the_path
test_malformed_configuration_refuses_naming_the_line
test_symlinked_mirror_is_refused
