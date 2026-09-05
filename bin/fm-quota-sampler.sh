#!/bin/sh
# fm-quota-sampler.sh - append one Claude and ChatGPT quota sample.
#
# Usage:
#   fm-quota-sampler.sh
#
# This script is safe to invoke from a macOS LaunchAgent with launchd's sparse
# environment. It restores the account home when HOME is absent, discovers a
# quota-axi installed in common user-level locations, and puts that executable's
# directory on PATH so its `#!/usr/bin/env node` interpreter can resolve.
#
# Claude is read for exactly one provider without credential refresh or a
# keychain prompt. A provider read that is unavailable is recorded as null so
# the independent ChatGPT reading and sample timestamp are not lost.
#
# FM_HOME                       operational home (default: repository root)
# FM_QUOTA_SAMPLE_HISTORY       output file (default: $FM_HOME/data/quota-history.jsonl)
# FM_QUOTA_SAMPLE_QUOTA_AXI     quota-axi executable override
# FM_QUOTA_SAMPLE_GPT_READER    ChatGPT reader override
# FM_QUOTA_SAMPLE_PYTHON        Python 3 executable override
set -eu

PATH=${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}
export PATH
ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
FM_HOME=${FM_HOME:-$ROOT}
OUT=${FM_QUOTA_SAMPLE_HISTORY:-$FM_HOME/data/quota-history.jsonl}
GPT_READER=${FM_QUOTA_SAMPLE_GPT_READER:-$ROOT/bin/fm-gpt-quota.sh}

resolve_python() {
  if [ -n "${FM_QUOTA_SAMPLE_PYTHON:-}" ]; then
    printf '%s\n' "$FM_QUOTA_SAMPLE_PYTHON"
  elif [ -x /usr/bin/python3 ]; then
    printf '%s\n' /usr/bin/python3
  elif command -v python3 >/dev/null 2>&1; then
    command -v python3
  else
    return 1
  fi
}

PYTHON=$(resolve_python) || {
  printf 'fm-quota-sampler: python3 is required\n' >&2
  exit 1
}

if [ -z "${HOME:-}" ]; then
  HOME=$("$PYTHON" -c 'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)')
  export HOME
fi

BASE_PATH=${PATH:-/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}
resolve_quota_axi() {
  if [ -n "${FM_QUOTA_SAMPLE_QUOTA_AXI:-}" ]; then
    [ -x "$FM_QUOTA_SAMPLE_QUOTA_AXI" ] || return 1
    printf '%s\n' "$FM_QUOTA_SAMPLE_QUOTA_AXI"
    return
  fi
  if command -v quota-axi >/dev/null 2>&1; then
    command -v quota-axi
    return
  fi
  found=
  for candidate in \
    "$HOME/.local/bin/quota-axi" \
    "$HOME/.npm-global/bin/quota-axi" \
    "$HOME"/.nvm/versions/node/*/bin/quota-axi
  do
    [ -x "$candidate" ] && found=$candidate
  done
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

QUOTA_AXI=$(resolve_quota_axi) || {
  printf 'fm-quota-sampler: quota-axi was not found for HOME=%s\n' "$HOME" >&2
  exit 1
}
PATH=$(dirname -- "$QUOTA_AXI"):$BASE_PATH
export PATH

mkdir -p "$(dirname -- "$OUT")"
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CLAUDE=$("$QUOTA_AXI" --provider claude --no-credential-refresh --json 2>/dev/null || :)
GPT=$("$GPT_READER" --json 2>/dev/null || :)
export TS CLAUDE GPT

"$PYTHON" - >> "$OUT" <<'PY'
import json
import os


def parse(value):
    try:
        return json.loads(value) if value else None
    except (TypeError, ValueError):
        return None


print(json.dumps({
    "ts": os.environ["TS"],
    "claude": parse(os.environ.get("CLAUDE")),
    "gpt": parse(os.environ.get("GPT")),
}, separators=(",", ":")))
PY
