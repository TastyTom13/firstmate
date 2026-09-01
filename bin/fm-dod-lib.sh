#!/usr/bin/env bash
# Single owner of a ship task's mode-specific "Definition of done" block.
# Sourced by bin/fm-brief.sh, which renders it into a generated ship brief, and by
# bin/fm-promote.sh, which renders it into the ship instructions a promoted scout
# receives. Both paths must hand the worker the same contract: a promoted
# no-mistakes worker that never received the ask-user escalation rule or the
# `--yes` ban is the exact delivery hole this single owner exists to close.
# fm_dod_block <no-mistakes|direct-PR|local-only> <task-id> <meta-path> prints
# the block on stdout with no trailing blank line. The caller validates the
# mode; an unknown mode is refused rather than silently rendered as the
# pipeline contract. <meta-path> is the shell-quoted absolute path to this
# task's own state/<id>.meta, the durable record bin/fm-spawn.sh already
# writes harness=/model=/effort= into at spawn (and refreshes on relaunch),
# so the attribution line below survives a worker restart without depending
# on any runtime environment variable that would not.
# The block opens with the fixed machine-readable "Delivery contract: mode=<mode>"
# line that bin/fm-spawn.sh checks a ship brief against.
# The two PR-raising modes also tell the worker to follow its done line with
# "paused: awaiting merge of PR {url}", so the wait for a merge is a declared
# external wait rather than an idle pane the watcher escalates as stale.
# local-only raises no PR and therefore carries no such line, and no
# "Built by" instruction either, since it never opens one.
# The no-mistakes "Built by" recipe is the fleet's ONE sanctioned use of raw
# `gh` instead of `gh-axi`: gh-axi has no way to read a PR body back verbatim
# (`pr view --full` renders a record, and `--body-file` has no stdin form), so
# the read half of that one read-modify-write uses `gh pr view --json body`.
# Every heredoc here stays outside a command substitution: `VAR=$(cat <<EOF ...)`
# breaks parsing of the whole file on Bash 3.2 (tests/fm-brief.test.sh).

_FM_DOD_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _FM_DOD_LIB_DIR="."
# The declared-external-wait verb this block instructs has ONE owner
# (FM_CLASSIFY_PAUSED_VERB_DEFAULT in bin/fm-classify-lib.sh), so source it here
# rather than repeating the literal: a caller that renders the block without
# having sourced the classify lib itself (bin/fm-promote.sh) must still say the
# same verb the rest of the fleet reads.
# shellcheck source=bin/fm-classify-lib.sh
. "$_FM_DOD_LIB_DIR/fm-classify-lib.sh"

# Both callers must hand <meta-path> in as a single shell-quoted literal, so
# the quoting rule for this lib's own argument lives with the lib.
fm_shell_quote() {  # <value>
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_dod_block() {  # <mode> <task-id> <meta-path>
  local mode=$1 id=$2 meta=$3
  local paused=${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}
  case "$mode" in
    direct-PR)
      cat <<EOF
# Definition of done
Delivery contract: mode=direct-PR
This task ships **direct-PR**: you raise the PR yourself, without the no-mistakes pipeline.
The task is complete only when committed on your branch.
Before opening the PR, read $meta and turn its \`harness=\`, \`model=\`, and \`effort=\` fields into a trailing PR-body line \`Built by: <harness>/<model> at <effort>\` (an unset model or effort reads back as the literal \`default\`, matching how it was recorded); for example: \`awk -F= '\$1=="harness"{h=\$2} \$1=="model"{m=\$2} \$1=="effort"{e=\$2} END{printf "Built by: %s/%s at %s", h, m, e}' $meta\`. Include that exact line, on its own line, in the PR body you pass to \`gh-axi\`.
When it is implemented and committed, push your branch and open a PR with \`gh-axi\`, then append \`done: PR {url}\` to the status file, follow it with \`$paused: awaiting merge of PR {url}\`, and stop.
That second line declares a known external wait, so your idle pane is rechecked on a long cadence instead of being treated as a possible wedge.
Do NOT run /no-mistakes. The configured merge authority decides whether to merge the PR; firstmate relays the outcome.
EOF
      ;;
    local-only)
      cat <<EOF
# Definition of done
Delivery contract: mode=local-only
This task ships **local-only**: no remote, no PR, no pipeline.
The task is complete only when committed on your branch \`fm/$id\`. Do NOT push, do NOT open a PR, do NOT merge.
Keep your branch a clean fast-forward onto the current default branch - if \`main\` has advanced, rebase onto it so the eventual merge stays a fast-forward.
When it is implemented and committed, append \`done: ready in branch fm/$id\` to the status file and stop.
The configured merge authority approves the ready branch, then firstmate merges it into local \`main\` through the guarded fast-forward path.
EOF
      ;;
    no-mistakes)
      cat <<EOF
# Definition of done
Delivery contract: mode=no-mistakes
The task is complete only when committed on your branch.
When you believe it is complete, append \`done: {summary}\` to the status file and stop.
Firstmate will then instruct you to run /no-mistakes to validate and ship a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: it loads when you invoke /no-mistakes, and \`no-mistakes axi run --help\` plus the \`help\` lines in each \`axi\` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make \`--intent\` preserve all relevant content from this brief's \`# Task\` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies \`ask-user-authority\` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with \`no-mistakes axi respond\` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass \`--yes\` (or \`-y\`) to \`no-mistakes axi run\` or \`no-mistakes axi respond\`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

Once no-mistakes reports the PR, read $meta and turn its \`harness=\`, \`model=\`, and \`effort=\` fields into a trailing PR-body line \`Built by: <harness>/<model> at <effort>\` (an unset model or effort reads back as the literal \`default\`, matching how it was recorded); for example: \`awk -F= '\$1=="harness"{h=\$2} \$1=="model"{m=\$2} \$1=="effort"{e=\$2} END{printf "Built by: %s/%s at %s", h, m, e}' $meta\`. Append that exact line, on its own line, to the PR body before you report done, where \`<number>\` is the trailing path segment of the PR url: \`body=\$(mktemp) && gh pr view <number> --json body -q .body > "\$body"\`, append the \`Built by:\` line to that file, then \`gh-axi pr edit <number> --body-file "\$body"\`. Use a fresh \`mktemp\` path, never a fixed name like /tmp/pr-body.md: crewmates ship concurrently on one host, and a shared scratch file lets another task's body overwrite yours.
After /no-mistakes reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append \`done: PR {url} checks green\`, follow it with \`$paused: awaiting merge of PR {url}\`, and stop. You are finished.
That second line declares a known external wait, so your idle pane is rechecked on a long cadence instead of being treated as a possible wedge.
EOF
      ;;
    *)
      echo "error: fm_dod_block: unknown delivery mode '$mode'" >&2
      return 1 ;;
  esac
}
