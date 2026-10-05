#!/usr/bin/env bash
# Tests for bin/fm-base-green.sh: the read-only base-branch CI verdict
# firstmate takes at every ship intake and the session-start digest lists.
# Each case runs the real script against a fake `gh` that replays recorded
# `gh run list` and `gh run view` output, so the verdict is pinned without a
# network.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

BASE_GREEN="$ROOT/bin/fm-base-green.sh"
TMP_ROOT=$(fm_test_tmproot fm-base-green-tests)

# make_case <name> builds a home with one project clone whose origin HEAD is
# `dev`, plus a fakebin dir. Echoes the case dir.
make_case() {
  local case_dir="$TMP_ROOT/$1"
  mkdir -p "$case_dir/home/projects" "$case_dir/fakebin"
  fm_git_init_commit "$case_dir/home/projects/demo" >/dev/null
  git -C "$case_dir/home/projects/demo" update-ref refs/remotes/origin/dev HEAD
  git -C "$case_dir/home/projects/demo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/dev
  printf '%s\n' "$case_dir"
}

# write_gh <case_dir> installs a fake gh that answers `run list` from
# runs.json and `run view <id>` from jobs-<id>.json, and records its argv.
write_gh() {
  cat > "$1/fakebin/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$1/gh.argv"
case "\$1 \$2" in
  'run list') cat "$1/runs.json" ;;
  'run view') cat "$1/jobs-\$3.json" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/fakebin/gh"
}

run_check() {  # <case_dir> [args...]
  local case_dir=$1
  shift
  FM_HOME="$case_dir/home" PATH="$case_dir/fakebin:$PATH" \
    bash "$BASE_GREEN" "$@" 2>"$case_dir/stderr"
}

test_green() {
  local c out rc
  c=$(make_case green)
  write_gh "$c"
  cat > "$c/runs.json" <<'EOF'
[{"databaseId":3,"conclusion":"success","url":"https://github.com/o/r/actions/runs/3","workflowName":"CI","event":"push"},
 {"databaseId":2,"conclusion":"failure","url":"https://github.com/o/r/actions/runs/2","workflowName":"CI","event":"push"},
 {"databaseId":1,"conclusion":"failure","url":"https://github.com/o/r/actions/runs/1","workflowName":"CI retry","event":"workflow_run"}]
EOF
  out=$(run_check "$c" demo); rc=$?
  [ "$rc" -eq 0 ] || fail "green: exit $rc, want 0 ($out)"
  [ "$out" = "green dev https://github.com/o/r/actions/runs/3" ] || fail "green: got '$out'"
  grep -q -- '--branch dev' "$c/gh.argv" || fail "green: did not ask gh for the origin HEAD branch dev"
  pass "latest completed run per workflow green reads green; an older red and a workflow_run helper are ignored"
}

test_red() {
  local c out rc
  c=$(make_case red)
  write_gh "$c"
  cat > "$c/runs.json" <<'EOF'
[{"databaseId":9,"conclusion":"skipped","url":"https://github.com/o/r/actions/runs/9","workflowName":"CI","event":"push"},
 {"databaseId":8,"conclusion":"failure","url":"https://github.com/o/r/actions/runs/8","workflowName":"CI","event":"push"},
 {"databaseId":7,"conclusion":"success","url":"https://github.com/o/r/actions/runs/7","workflowName":"Lint","event":"push"}]
EOF
  cat > "$c/jobs-8.json" <<'EOF'
{"jobs":[{"name":"e2e shard 1","conclusion":"failure"},{"name":"unit","conclusion":"success"},{"name":"e2e shard 3","conclusion":"timed_out"}]}
EOF
  out=$(run_check "$c" demo main); rc=$?
  [ "$rc" -eq 1 ] || fail "red: exit $rc, want 1 ($out)"
  [ "$out" = "red main https://github.com/o/r/actions/runs/8 (e2e shard 1, e2e shard 3)" ] || fail "red: got '$out'"
  grep -q -- '--branch main' "$c/gh.argv" || fail "red: an explicit branch argument was not used"
  pass "a failed latest run reads red with its run URL and failing job names; a skipped run is ignored"
}

test_no_workflow() {
  local c out rc
  c=$(make_case none)
  write_gh "$c"
  printf '[]\n' > "$c/runs.json"
  out=$(run_check "$c" demo); rc=$?
  [ "$rc" -eq 2 ] || fail "no workflow: exit $rc, want 2 ($out)"
  [ "$out" = "unknown dev no completed CI runs" ] || fail "no workflow: got '$out'"
  pass "a project with no completed CI runs reads unknown"
}

test_gh_unavailable() {
  local c out rc
  c=$(make_case nogh)
  # A PATH holding only the tools the script needs, and no gh.
  local tool
  for tool in bash git jq dirname cat sed basename; do
    ln -s "$(command -v "$tool")" "$c/fakebin/$tool"
  done
  out=$(FM_HOME="$c/home" PATH="$c/fakebin" bash "$BASE_GREEN" demo 2>"$c/stderr"); rc=$?
  [ "$rc" -eq 2 ] || fail "gh unavailable: exit $rc, want 2 ($out)"
  [ "$out" = "unknown dev gh unavailable" ] || fail "gh unavailable: got '$out'"
  pass "a missing gh reads unknown, never green"
}

test_gh_error() {
  local c out rc
  c=$(make_case gherr)
  printf '#!/usr/bin/env bash\necho "HTTP 401: Bad credentials" >&2\nexit 1\n' > "$c/fakebin/gh"
  chmod +x "$c/fakebin/gh"
  out=$(run_check "$c" demo); rc=$?
  [ "$rc" -eq 2 ] || fail "gh error: exit $rc, want 2 ($out)"
  [ "$out" = "unknown dev gh run list failed: HTTP 401: Bad credentials" ] || fail "gh error: got '$out'"
  pass "a failing gh call reads unknown with its reason"
}

test_missing_clone() {
  local c out rc
  c=$(make_case noclone)
  write_gh "$c"
  out=$(run_check "$c" absent); rc=$?
  [ "$rc" -eq 2 ] || fail "missing clone: exit $rc, want 2 ($out)"
  [ "$out" = "unknown - no clone at $c/home/projects/absent" ] || fail "missing clone: got '$out'"
  pass "an unknown project reads unknown and names the missing clone"
}

# The session-start digest's deferred network stage lists every registered
# project's base-branch verdict on one line. A red base makes the line
# actionable (BASE_BRANCHES:); an all-clear line is a BOOTSTRAP_INFO fact, so
# it never wakes firstmate on its own. local-only projects run no CI and are
# skipped, and a project with no clone is not listed.
test_session_start_lists_base_branches() {
  local c out p
  c=$(make_case digest)
  for p in alpha bravo solo; do
    fm_git_init_commit "$c/home/projects/$p" >/dev/null
    git -C "$c/home/projects/$p" update-ref refs/remotes/origin/main HEAD
    git -C "$c/home/projects/$p" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  done
  mkdir -p "$c/home/data"
  printf '%s\n' '# Projects' '' \
    '- alpha [direct-PR +yolo] - green project (added 2026-10-05)' \
    '- bravo [no-mistakes] - red project (added 2026-10-05)' \
    '- solo [local-only] - no CI (added 2026-10-05)' \
    '- ghost [direct-PR] - registered but not cloned (added 2026-10-05)' \
    > "$c/home/data/projects.md"
  cat > "$c/fakebin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  'auth status') exit 0 ;;
  'run list') cat "$c/runs-\$(basename "\$PWD").json" ;;
  'run view') printf '%s\n' '{"jobs":[{"name":"e2e","conclusion":"failure"}]}' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$c/fakebin/gh"
  printf '%s\n' '[{"databaseId":1,"conclusion":"success","url":"https://x/runs/1","workflowName":"CI","event":"push"}]' > "$c/runs-alpha.json"
  printf '%s\n' '[{"databaseId":2,"conclusion":"failure","url":"https://x/runs/2","workflowName":"CI","event":"push"}]' > "$c/runs-bravo.json"

  out=$(FM_HOME="$c/home" PATH="$c/fakebin:$PATH" FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    bash "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  [ "$out" = "BASE_BRANCHES: red base branch blocks CI-dependent ships until fixed: bravo red main https://x/runs/2 (e2e); alpha green main https://x/runs/1" ] \
    || fail "digest red: got '$out'"

  cp "$c/runs-alpha.json" "$c/runs-bravo.json"
  out=$(FM_HOME="$c/home" PATH="$c/fakebin:$PATH" FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
    bash "$ROOT/bin/fm-bootstrap.sh" 2>/dev/null)
  [ "$out" = "BOOTSTRAP_INFO: base branches: alpha green main https://x/runs/1; bravo green main https://x/runs/1" ] \
    || fail "digest green: got '$out'"
  pass "the session-start network stage lists each registered project's base-branch verdict, actionable only when red"
}

test_green
test_red
test_no_workflow
test_gh_unavailable
test_gh_error
test_missing_clone
test_session_start_lists_base_branches
