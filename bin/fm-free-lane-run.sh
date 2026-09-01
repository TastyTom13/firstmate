#!/usr/bin/env bash
# Run one free-tier model lane through pi, from a single stable command shape.
# Usage: fm-free-lane-run.sh <lane> [pi-args...]
#        fm-free-lane-run.sh --list
#        fm-free-lane-run.sh --install-launcher [--av <path>]
# Lanes are groq, cerebras, cloudflare, and openrouter, in the survey
# preference order of docs/free-tier-providers.md. Each lane maps to the pi
# provider and model registered in the operator's own ~/.pi/agent/models.json;
# docs/free-tier-routing.md owns those provider entries.
# This script never reads, writes, or logs a secret value. It requires the
# lane's key to be present in its own environment and exits 3 naming the
# missing variable when it is not, so an unauthenticated lane refuses instead
# of dispatching. The blessed launcher installed by --install-launcher is what
# supplies those variables; see "Key delivery" below.
#
# Key delivery: routine invocations go through a home-local launcher whose
# shebang is an `av inject` line naming exactly the four lane keys, so one
# `av bless <launcher>` by the owner pre-authorises every later call.
# --install-launcher writes that launcher to
# ${FM_CONFIG_OVERRIDE:-${FM_HOME:-$FM_ROOT}/config}/free-lane-launcher,
# resolving the operator's own `av` path rather than hard-coding one, and
# prints the one-time `av bless` command to run against it. The launcher is
# home-local and gitignored because its shebang carries a machine-specific
# interpreter path; this tracked script stays portable and secret-free.
#
# One lane, one key: the launcher injects the whole set so a single blessing
# covers every lane, and this script then narrows the environment immediately
# before starting pi, removing every lane key except the one the invoked lane
# declares. If a key cannot be removed, the script exits 3 rather than starting
# pi with a wider environment than intended.
#
# Re-entry guard: the narrowed environment carries FM_FREE_LANE_ACTIVE=1, and a
# lane invocation that already sees that marker refuses with exit 4 instead of
# starting pi. It refuses for every lane, including the same lane again,
# because the concern is a second lane session existing at all.
#
# What these two actually buy, stated plainly: the pi process for a lane holds
# only that lane's own key, and the marker closes the incidental path where a
# lane session simply starts another lane. Neither is a boundary. The blessed
# launcher is by design a no-prompt path to any lane for anything that can
# execute it, and a cooperating agent could unset the marker before invoking
# it, just as the invoked lane's own key stays readable inside its own session.
# Both residuals are deliberate and accepted here; buying them out would need
# the keys to reach pi by a path the session cannot read at all.
#
# Cloudflare mispaste guard: the cloudflare lane is account-scoped and pi does
# not expand environment variables in `baseUrl`, only in `apiKey` and
# `headers`, so the account identifier must be typed into the operator's own
# models.json. Before dispatching that lane only, this script reads
# ${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json, which is the path pi
# itself resolves, and inspects the account segment of the baseUrl belonging to
# the provider the lane table names for that lane, so renaming the provider
# there cannot silently drop the guard. An unfilled segment - empty, an
# unexpanded `$NAME` or `${NAME}` reference, or an angle-bracket blank - exits 3
# naming the file and what to fill in, instead of dispatching to a URL
# Cloudflare will reject.
# A shape or parse problem is deliberately NOT fatal: an absent, unreadable, or
# malformed file, a missing cloudflare provider, a missing baseUrl, or an
# absent jq all print one warning line to stderr and dispatch anyway, so a pi
# change can cost this guard but can never brick the lane.
#
# Exit codes: 0 the lane ran, 2 usage error, 3 the lane's key is absent from
# the environment, its account segment is unfilled, or the environment could
# not be narrowed, 4 a free-tier lane tried to start another free-tier lane,
# otherwise pi's own exit code.
#
# Slim prompt: pi's own default is a coding-agent system prompt plus its
# built-in tool definitions (read, bash, edit, write, and friends). Worse,
# pi auto-discovers AGENTS.md/CLAUDE.md from the working directory and
# appends their full content to that same prompt regardless of
# --system-prompt, which dwarfs everything else when a lane runs from a
# firstmate home (its own AGENTS.md alone made a one-line "hi" prompt cost
# roughly 20k-31k tokens in local measurement and live evidence). A
# free-tier lane is one-shot text generation, never a tool-using or
# project-aware agent session, so every lane invocation here passes a
# minimal --system-prompt plus --no-builtin-tools and --no-context-files
# ahead of the caller's own arguments. Because pi takes the last occurrence
# of a repeated flag, a caller who genuinely needs a different system
# prompt or the built-in tools can still pass --system-prompt or
# --tools/-t after the lane name; nothing here refuses that override. pi
# has no flag to force context-file discovery back on, so a lane call that
# genuinely needs AGENTS.md/CLAUDE.md content should not go through this
# free-tier runner at all.
FREE_LANE_SYSTEM_PROMPT='You are a one-shot text generator running on a free-tier model. Respond with only the requested content, nothing else: no tool calls, no preamble, no explanation of your process, no follow-up questions.'
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
LAUNCHER="$CONFIG/free-lane-launcher"
MODELS_FILE="${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}/models.json"

# Single owner of the lane table: lane|env var|pi provider|pi model.
LANES='groq|GROQ_API_KEY|groq|openai/gpt-oss-120b
cerebras|CEREBRAS_API_KEY|cerebras|gpt-oss-120b
cloudflare|CLOUDFLARE_API_KEY|cloudflare|@cf/openai/gpt-oss-120b
openrouter|OPENROUTER_API_KEY|openrouter-free|minimax/minimax-m3:free'

usage() {
  awk 'NR > 1 { if ($0 !~ /^#/) { exit } sub(/^# ?/, ""); print }' "$0"
}

lane_row() {
  printf '%s\n' "$LANES" | awk -F'|' -v lane="$1" '$1 == lane { print; exit }'
}

lane_keys() {
  printf '%s\n' "$LANES" | awk -F'|' '{ printf "+%s ", $2 }'
}

install_launcher() {
  local av_path=${1:-}
  if [ -z "$av_path" ]; then
    av_path=$(command -v av || true)
  fi
  [ -n "$av_path" ] || { echo "error: av not found on PATH; pass --av <path>" >&2; exit 2; }
  av_path=$(cd "$(dirname "$av_path")" && printf '%s/%s' "$(pwd -P)" "$(basename "$av_path")")
  case $av_path in
    *[[:space:]]*)
      echo "error: av path '$av_path' contains whitespace, which a shebang cannot express" >&2
      echo "hint: symlink av to a whitespace-free path and pass it with --av" >&2
      exit 2
      ;;
  esac
  mkdir -p "$CONFIG"
  {
    printf '#!%s inject %s-- /bin/bash\n' "$av_path" "$(lane_keys)"
    printf '# Generated by bin/fm-free-lane-run.sh --install-launcher. Home-local, gitignored.\n'
    printf '# Its shebang carries this machine'"'"'s av path and the four free-tier lane keys.\n'
    printf '# One-time owner step: av bless '"'"'%s'"'"'\n' "$LAUNCHER"
    printf 'exec '"'"'%s'"'"'/bin/fm-free-lane-run.sh "$@"\n' "${FM_ROOT//\'/\'\\\'\'}"
  } > "$LAUNCHER"
  chmod 0755 "$LAUNCHER"
  echo "installed: $LAUNCHER"
  echo "next (owner, once): av bless '$LAUNCHER'"
}

# Refuses only an account segment that is plainly still a blank; every other
# problem warns and lets the dispatch through.
check_cloudflare_account() {
  local provider=$1 base_url account rest
  if [ ! -r "$MODELS_FILE" ] || ! command -v jq >/dev/null 2>&1; then
    echo "warning: cannot check the '$provider' account id in $MODELS_FILE; dispatching anyway" >&2
    return 0
  fi
  base_url=$(jq -r --arg p "$provider" '.providers[$p].baseUrl // empty' "$MODELS_FILE" 2>/dev/null) || base_url=''
  case $base_url in
    */accounts/*) ;;
    *)
      echo "warning: no '$provider' baseUrl with an account segment in $MODELS_FILE; dispatching anyway" >&2
      return 0
      ;;
  esac
  rest=${base_url#*/accounts/}
  account=${rest%%/*}
  case $account in
    ''|'$'*|'<'*)
      echo "error: the '$provider' provider in $MODELS_FILE still has an unfilled account segment" >&2
      echo "hint: pi does not expand variables in baseUrl; type your own Cloudflare account id into that file" >&2
      exit 3
      ;;
  esac
}

# The launcher injects every lane key; only the invoked lane's own key may
# reach pi.
narrow_to_lane_key() {
  local keep=$1 var
  while read -r var; do
    if [ "$var" != "$keep" ]; then
      unset "$var" || true
      if [ -n "${!var:-}" ]; then
        echo "error: cannot remove $var from the lane environment; refusing to start pi" >&2
        exit 3
      fi
    fi
  done < <(printf '%s\n' "$LANES" | cut -d'|' -f2)
  export FM_FREE_LANE_ACTIVE=1
}

[ "$#" -gt 0 ] || { usage; exit 2; }

case $1 in
  -h|--help)
    usage
    exit 2
    ;;
  --list)
    printf '%s\n' "$LANES" | awk -F'|' '{ printf "%-11s %-16s %s/%s\n", $1, $2, $3, $4 }'
    exit 0
    ;;
  --install-launcher)
    shift
    AV_PATH=''
    if [ "$#" -gt 0 ]; then
      [ "$1" = "--av" ] || { echo "error: unexpected argument '$1'; --install-launcher takes only --av <path>" >&2; exit 2; }
      [ "$#" -gt 1 ] || { echo "error: --av requires a path" >&2; exit 2; }
      [ "$#" -eq 2 ] || { echo "error: unexpected argument '$3' after --av <path>" >&2; exit 2; }
      AV_PATH=$2
    fi
    install_launcher "$AV_PATH"
    exit 0
    ;;
esac

LANE=$1
shift

if [ -n "${FM_FREE_LANE_ACTIVE:-}" ]; then
  echo "error: a free-tier lane may not start another free-tier lane" >&2
  echo "hint: FM_FREE_LANE_ACTIVE marks this process tree as already inside a lane" >&2
  exit 4
fi

ROW=$(lane_row "$LANE")
[ -n "$ROW" ] || { echo "error: unknown lane '$LANE'; run --list" >&2; exit 2; }

ENV_VAR=$(printf '%s' "$ROW" | cut -d'|' -f2)
PROVIDER=$(printf '%s' "$ROW" | cut -d'|' -f3)
MODEL=$(printf '%s' "$ROW" | cut -d'|' -f4)

if [ -z "${!ENV_VAR:-}" ]; then
  echo "error: lane '$LANE' needs $ENV_VAR in the environment" >&2
  echo "hint: run through the blessed launcher ($LAUNCHER); see --install-launcher" >&2
  exit 3
fi

[ "$LANE" != cloudflare ] || check_cloudflare_account "$PROVIDER"

narrow_to_lane_key "$ENV_VAR"

exec pi --provider "$PROVIDER" --model "$MODEL" \
  --system-prompt "$FREE_LANE_SYSTEM_PROMPT" --no-builtin-tools --no-context-files "$@"
