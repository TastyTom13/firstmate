#!/usr/bin/env bash
# tests/fm-free-lane-slim-prompt-live-e2e.test.sh - the live pi-flag guard for
# the free-tier lane runner (live-harness-optin family).
#
# bin/fm-free-lane-run.sh's whole token saving rests on four flags the vendor
# owns: --system-prompt, --no-builtin-tools, --no-context-files, and
# --no-extensions. pi routes a flag it does not recognise to its extensions
# before deciding it is unknown, so a pi release that renames one of these, or
# an extension that claims the old name, can leave the lane exiting 0 while
# silently regaining the default coding-agent prompt, the built-in tool
# definitions, and this repo's whole AGENTS.md - the ~31k-token request that
# drew Groq's 413 in the first place. The portable fake-pi test in
# tests/fm-free-lane-run.test.sh pins the dispatched argv and cannot see that,
# because a fake pi accepts whatever it is handed. This guard checks the
# effect, not the argv, so it catches both a loud unknown-option exit and a
# silent change of meaning.
#
# This guard therefore runs the REAL installed pi against a local mock
# OpenAI-compatible endpoint and asserts on the request pi actually assembled:
# no tools, no context-file content, and the runner's own system prompt rather
# than pi's default. No provider key and no model tokens are spent - the mock
# answers every request with a canned stream. What keeps the run off the
# network is the loopback baseUrl in the models.json this guard generates under
# its own PI_CODING_AGENT_DIR: that file is the only provider pi can resolve
# here, and the lane key it carries is a placeholder value.
#
# It proves the flags by contrast against a baseline run of the same pi in the
# same directory with none of them: that run must show the built-in tools, the
# extension-registered tool, and the AGENTS.md sentinel, or the guard fails
# rather than passing vacuously on a setup that no longer reproduces discovery.
#
# Run explicitly with FM_FREE_LANE_SLIM_LIVE_E2E=1. An absent pi or node is
# reported and skipped. Every failure names pi and its version, because the
# expected cause is a vendor flag change rather than a bug in this repo.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_FREE_LANE_SLIM_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_FREE_LANE_SLIM_LIVE_E2E=1 to run the live free-lane pi-flag guard"
  exit 0
fi

command -v pi >/dev/null 2>&1 || { echo "skip: pi is not installed; nothing to verify the free-lane flags against"; exit 0; }
command -v node >/dev/null 2>&1 || { echo "skip: node is not installed; the mock provider endpoint needs it"; exit 0; }

PI_VERSION=$(pi --version 2>/dev/null | head -1)
[ -n "$PI_VERSION" ] || PI_VERSION=version-unknown

# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-free-lane-live.XXXXXX")
LAB=$(cd "$LAB" && pwd -P)
AGENT_DIR="$LAB/agent"
WORK="$LAB/work"
BODY="$LAB/body.json"
MOCK_PID=''
FAILED=0
SENTINEL='FM-FREE-LANE-LIVE-CONTEXT-SENTINEL'
LANE_PHRASE='one-shot text generator'
PROBE_TOOL='fm_free_lane_live_probe'
RUN_TIMEOUT=${FM_FREE_LANE_SLIM_LIVE_TIMEOUT:-120}

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'not ok - %s (pi %s)\n' "$1" "$PI_VERSION" >&2; FAILED=1; }

# shellcheck disable=SC2329 # Invoked by the EXIT trap registered below.
cleanup() {
  [ -z "$MOCK_PID" ] || kill "$MOCK_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$AGENT_DIR" "$WORK/.pi/extensions"

# The stand-in provider: records the request body pi assembled, then answers
# with the smallest well-formed streaming completion pi accepts.
cat > "$LAB/mock-provider.mjs" <<'MOCK'
import http from "node:http";
import fs from "node:fs";

const bodyFile = process.argv[2];
const server = http.createServer((req, res) => {
  let body = "";
  req.on("data", (chunk) => { body += chunk; });
  req.on("end", () => {
    fs.writeFileSync(bodyFile, body);
    res.writeHead(200, { "content-type": "text/event-stream" });
    const send = (payload) => res.write(`data: ${JSON.stringify(payload)}\n\n`);
    send({
      id: "mock", object: "chat.completion.chunk", created: 1, model: "mock",
      choices: [{ index: 0, delta: { role: "assistant", content: "ok" } }],
    });
    send({
      id: "mock", object: "chat.completion.chunk", created: 1, model: "mock",
      choices: [{ index: 0, delta: {}, finish_reason: "stop" }],
      usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
    });
    res.write("data: [DONE]\n\n");
    res.end();
  });
});
server.listen(0, "127.0.0.1", () => { console.log(server.address().port); });
MOCK

# Reads the recorded request and prints the facts the assertions need: the tool
# names pi offered, how many times the context-file sentinel reached the
# request, how many times the lane's own prompt phrase did, and a digest of the
# whole system prompt pi sent.
cat > "$LAB/read-request.mjs" <<'READ'
import fs from "node:fs";
import { createHash } from "node:crypto";

const body = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const sentinel = process.argv[3];
const lanePhrase = process.argv[4];
const tools = (body.tools ?? []).map((t) => t.function?.name ?? t.name ?? "?");
const system = (body.messages ?? [])
  .filter((m) => m.role === "system")
  .map((m) => (typeof m.content === "string" ? m.content : JSON.stringify(m.content)))
  .join("\n");
const whole = JSON.stringify(body);
console.log(`tools=${tools.join(",")}`);
console.log(`sentinel=${whole.split(sentinel).length - 1}`);
console.log(`lane_phrase=${system.split(lanePhrase).length - 1}`);
console.log(`system_digest=${createHash("sha256").update(system).digest("hex")}`);
READ

node "$LAB/mock-provider.mjs" "$BODY" > "$LAB/port" 2>"$LAB/mock.err" &
MOCK_PID=$!

PORT=''
for _ in $(seq 1 100); do
  PORT=$(head -1 "$LAB/port" 2>/dev/null || true)
  [ -z "$PORT" ] || break
  sleep 0.1
done
if [ -z "$PORT" ]; then
  echo "not ok - the mock provider endpoint did not start: $(cat "$LAB/mock.err" 2>/dev/null)" >&2
  exit 1
fi

# The lane table's own groq provider and model, pointed at the mock. pi reads
# this file from PI_CODING_AGENT_DIR, so the operator's real models.json and
# real keys are untouched.
cat > "$AGENT_DIR/models.json" <<EOF
{
  "providers": {
    "groq": {
      "baseUrl": "http://127.0.0.1:$PORT/v1",
      "api": "openai-completions",
      "apiKey": "\$GROQ_API_KEY",
      "models": [
        {
          "id": "openai/gpt-oss-120b",
          "name": "Mock free-lane model",
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 256,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
EOF

# Extension discovery only reaches a trusted directory, so the baseline needs
# this working directory trusted for the extension half of the contrast.
printf '{"%s": true}\n' "$WORK" > "$AGENT_DIR/trust.json"

printf '# Project context\n\n%s\n' "$SENTINEL" > "$WORK/AGENTS.md"
cat > "$WORK/.pi/extensions/fm-free-lane-live-probe.ts" <<EOF
export default function (pi: any) {
  pi.registerTool({
    name: "$PROBE_TOOL",
    description: "Live-guard probe tool; never executed.",
    parameters: { type: "object", properties: {} },
    execute: async () => ({ output: "probe" }),
  });
}
EOF

# Runs one pi invocation in the lab working directory and prints the recorded
# request's facts. Returns non-zero when the invocation or the capture failed.
capture() {  # <label> <command...>
  local label=$1 status=0
  shift
  rm -f "$BODY"
  (
    cd "$WORK" || exit 1
    GROQ_API_KEY=not-a-real-value \
    PI_CODING_AGENT_DIR="$AGENT_DIR" \
    FM_FREE_LANE_ACTIVE='' \
      fm_run_timed "$RUN_TIMEOUT" "$@" </dev/null >"$LAB/$label.out" 2>"$LAB/$label.err"
  ) || status=$?
  if [ "$status" != 0 ]; then
    fail "$label: pi exited $status: $(tail -3 "$LAB/$label.err" 2>/dev/null)"
    return 1
  fi
  if [ ! -s "$BODY" ]; then
    fail "$label: pi sent no request to the mock provider"
    return 1
  fi
  node "$LAB/read-request.mjs" "$BODY" "$SENTINEL" "$LANE_PHRASE"
}

fact() {  # <captured-facts> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p"
}

# Baseline: the same pi, same directory, none of the runner's flags. This is
# what the runner is protecting against, and it also proves the lab still
# reproduces tool and context-file discovery at all.
BASELINE=$(capture baseline pi --provider groq --model openai/gpt-oss-120b --no-session -p "hi") || BASELINE=''
if [ -z "$BASELINE" ]; then
  echo "not ok - could not record a baseline pi request; nothing was verified (pi $PI_VERSION)" >&2
  exit 1
fi

BASE_TOOLS=$(fact "$BASELINE" tools)
BASE_SENTINEL=$(fact "$BASELINE" sentinel)
case ",$BASE_TOOLS," in
  *",$PROBE_TOOL,"*) ;;
  *) fail "baseline pi offered no extension-registered tool ($BASE_TOOLS); the guard cannot prove --no-extensions" ;;
esac
case "$BASE_TOOLS" in
  *read*) ;;
  *) fail "baseline pi offered no built-in tools ($BASE_TOOLS); the guard cannot prove --no-builtin-tools" ;;
esac
[ "${BASE_SENTINEL:-0}" -ge 1 ] \
  || fail "baseline pi did not load AGENTS.md into the request; the guard cannot prove --no-context-files"

# pi's own default system prompt under the same restrictions, with no
# --system-prompt of its own. The lane's prompt must not be this one.
DEFAULT_PROMPT=$(capture default-prompt pi --provider groq --model openai/gpt-oss-120b --no-session \
  --no-builtin-tools --no-context-files --no-extensions -p "hi") || DEFAULT_PROMPT=''
if [ -z "$DEFAULT_PROMPT" ]; then
  echo "not ok - could not record pi's default system prompt under the runner's restrictions (pi $PI_VERSION)" >&2
  exit 1
fi
DEFAULT_DIGEST=$(fact "$DEFAULT_PROMPT" system_digest)

# The real runner, dispatching the real pi.
LANE=$(capture lane "$ROOT/bin/fm-free-lane-run.sh" groq --no-session -p "hi") || LANE=''
if [ -z "$LANE" ]; then
  echo "not ok - the groq lane did not reach the mock provider through the real pi (pi $PI_VERSION)" >&2
  exit 1
fi

LANE_TOOLS=$(fact "$LANE" tools)
LANE_SENTINEL=$(fact "$LANE" sentinel)
LANE_DIGEST=$(fact "$LANE" system_digest)

if [ -n "$LANE_TOOLS" ]; then
  fail "the lane request still offers tools ($LANE_TOOLS); --no-builtin-tools/--no-extensions no longer take effect"
else
  pass "the lane request offers no tools, while the same pi offers $BASE_TOOLS without the flags"
fi

if [ "${LANE_SENTINEL:-0}" != 0 ]; then
  fail "the lane request still carries AGENTS.md content; --no-context-files no longer takes effect"
else
  pass "the lane request carries no AGENTS.md content, while the same pi loads it without the flag"
fi

LANE_PHRASE_HITS=$(fact "$LANE" lane_phrase)
if [ "$LANE_DIGEST" = "$DEFAULT_DIGEST" ]; then
  fail "the lane request carries pi's own default system prompt; --system-prompt no longer takes effect"
elif [ "${LANE_PHRASE_HITS:-0}" -lt 1 ]; then
  fail "the lane request's system prompt does not carry the runner's own prompt text; --system-prompt no longer reaches the request intact"
else
  pass "the lane request carries the runner's own system prompt, not pi's default"
fi

if [ "$FAILED" != 0 ]; then
  echo "# pi $PI_VERSION: a flag bin/fm-free-lane-run.sh depends on changed meaning, or its own prompt text moved away from '$LANE_PHRASE'; check pi --help and the runner's FREE_LANE_SYSTEM_PROMPT before editing either" >&2
  exit 1
fi

echo "# verified against pi $PI_VERSION"
exit 0
