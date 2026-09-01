# Free-tier routing pilot

This page is the operator procedure for routing one narrow class of crewmate work to a free-tier model provider instead of a paid Claude window.
[`docs/free-tier-providers.md`](free-tier-providers.md) is the evidence survey behind it; this page is the thing you install and run.

The pilot class is boilerplate test generation in non-core repositories: fixtures, mocks, and assertion scaffolding with no design judgement.
Nothing else is in scope, and widening the class is a new decision, not a configuration tweak.

## The data lines this pilot does not cross

These hold for every provider, on every tier, no matter how good that vendor's terms look.

1. No user or candidate data.
2. No environment values, API keys, tokens, or connection strings.
3. No candidate-database rows, populated schemas, or exports.
4. No GDPR Article 9 special-category personal data.
5. No proprietary reasoning or strategy logic, including the prompt wrappers that encode it.
6. No vendor whose terms cannot be read before signup.

Assume every free tier publishes your input to that vendor and may train on it, unless that vendor's own terms say otherwise for the exact tier in use.
Vendor silence is "assume yes, they train", not "probably fine".

One account per provider.
No multi-accounting, no promo-credit cycling, no proxied consumer chat products, and no shared or leaked keys.
Any page offering free frontier tokens without qualification is showing a revoked key, a terms violation, or both; those sources are recorded as rejected in the survey and never wired in.

## Provider entries

Four lanes are installed: Groq, Cloudflare Workers AI, and OpenRouter are live, and Cerebras is registered but currently refused by its own account.
Live here means live through the launcher, whether that is a hand-run one-shot call or a spawned worker (the "Spawning a worker on a lane" section below explains the latter).
All four run on `pi`, because OpenCode is not installed on this machine (`command -v opencode` finds nothing as of 2026-09-01) and an uninstalled harness cannot be verified.
The OpenCode block that earlier versions of this page carried has been removed rather than left unverified; add it back only after an installed OpenCode proves its own field names.

Pi reads custom providers from `~/.pi/agent/models.json`, not from `settings.json`, and the field is `apiKey` with `$ENV_VAR` interpolation, not `apiKeyEnv`.
Pi expands `$ENV_VAR` and `${ENV_VAR}` in `apiKey` and `headers` only, and never in `baseUrl`, which it passes to the vendor exactly as written.
The block below was verified against pi 0.84.3: every model in it appears in `pi --list-models` under its provider, and three of the four answered a real generation.
Those generations ran against an installed file whose Cloudflare `baseUrl` carried this home's own literal account identifier in place of the blank printed here, because a `baseUrl` still holding the blank cannot generate.
The file is home-local machine state, so this page ships the block rather than the file.

```json
{
  "providers": {
    "groq": {
      "baseUrl": "https://api.groq.com/openai/v1",
      "api": "openai-completions",
      "apiKey": "$GROQ_API_KEY",
      "models": [
        {
          "id": "openai/gpt-oss-120b",
          "name": "GPT-OSS 120B (Groq free tier)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 4000,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    },
    "cerebras": {
      "baseUrl": "https://api.cerebras.ai/v1",
      "api": "openai-completions",
      "apiKey": "$CEREBRAS_API_KEY",
      "models": [
        {
          "id": "gpt-oss-120b",
          "name": "GPT-OSS 120B (Cerebras free tier)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 8000,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    },
    "cloudflare": {
      "baseUrl": "https://api.cloudflare.com/client/v4/accounts/<your-cloudflare-account-id>/ai/v1",
      "api": "openai-completions",
      "apiKey": "$CLOUDFLARE_API_KEY",
      "models": [
        {
          "id": "@cf/openai/gpt-oss-120b",
          "name": "GPT-OSS 120B (Cloudflare Workers AI free tier)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 131072,
          "maxTokens": 8000,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    },
    "openrouter-free": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "api": "openai-completions",
      "apiKey": "$OPENROUTER_API_KEY",
      "models": [
        {
          "id": "minimax/minimax-m3:free",
          "name": "MiniMax M3 (OpenRouter free tier)",
          "reasoning": true,
          "input": ["text"],
          "contextWindow": 262144,
          "maxTokens": 8000,
          "cost": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 }
        }
      ]
    }
  }
}
```

Four details in that block are load-bearing and were each learned by a failed call, not by reading a vendor page.

`maxTokens` is charged against a per-minute budget before a single token is generated.
Groq's free tier allows 8,000 tokens per minute, so pi's default 65,536-token output reservation makes every request fail with `rate_limit_exceeded ... Requested 66013`.
Keep the free lanes' `maxTokens` small; 4,000 on Groq and 8,000 elsewhere is what the smoke ran on.

The Cloudflare entry is account-scoped: its `baseUrl` embeds the account identifier, and the OpenAI-compatible path is `/ai/v1` under that account.
This page prints `<your-cloudflare-account-id>` as an operator blank so no account identifier is published, and never as a variable reference, because pi does not expand variables in `baseUrl`.
Type your own account identifier over that blank in your own home-local `models.json`; the installed file holds the literal value, which is correct and required.
[`bin/fm-free-lane-run.sh`](../bin/fm-free-lane-run.sh) guards against pasting the blank unchanged, and its header owns exactly what that guard reads and when it refuses.

Pi ships its own built-in `groq` and `cerebras` catalogues, and `models.json` composes above them rather than replacing them, so both providers list more models than this block defines.
The name `openrouter-free` is deliberate: pi already has a built-in `openrouter` provider, and a separate identifier keeps the free-model lane from being confused with the paid one.

`pi --list-models` is the check that a lane is registered, and it is not the check that a lane works.
Cerebras passes it and still returns `402 payment_required` on every chat completion, which is why the dispatch rule below does not list Cerebras as a candidate.

## Key delivery

No key value is ever written to a file, including this one.
Routine lane invocations go through one stable launcher so the owner reviews it once instead of approving every call.
That launcher is the only path that delivers a lane key: never through an env file, never through a plaintext copy.
A spawned worker reaches it the same way a hand-run call does - see "Spawning a worker on a lane" below.

[`bin/fm-free-lane-run.sh`](../bin/fm-free-lane-run.sh) is the single command shape for every lane; its header owns the exact flags, lane table, and exit codes.
A lane invocation is text-only: it runs with no built-in tools, no extension-registered tools, and no `AGENTS.md`/`CLAUDE.md` project context, so a lane cannot read the repository it is pointed at.
That restriction is what keeps a lane under the per-minute budget above: pi otherwise attaches its own coding-agent prompt, its tool definitions, and the full auto-discovered `AGENTS.md`/`CLAUDE.md` of the working directory, which made a one-line prompt cost 31,264 tokens and drew a Groq `413` refusal before this runner sent a slim prompt instead.
Two of those defaults are overridable per call, and they are not the same thing: `--system-prompt` after the lane name replaces the slim prompt text, and `--tools`/`-t` after the lane name re-enables named built-in tools that `--no-builtin-tools` switched off.
`--tools` cannot bring back an extension's tool, because `--no-extensions` stops that extension loading at all, so there is no registered name for the allowlist to match.
The extension restriction blocks automatic discovery only, so the one way back for an extension's tool is naming that extension file explicitly with `-e <path>` after the lane name.
There is no per-call override for the context-file restriction; a call that genuinely needs `AGENTS.md`/`CLAUDE.md` content should not use this runner.
Those four pi flags are the whole saving, so [`docs/verification/runtime-backends.md`](verification/runtime-backends.md#free-tier-lane-pi-flags) owns the opt-in live guard that reproves them against the installed pi after an upgrade.
It is an ordinary portable script that reads each lane's key from its own environment and refuses with exit 3 when that variable is absent, so an unauthenticated lane never dispatches.
Before the cloudflare lane only, it also refuses when the account segment of that provider's `baseUrl` is still an unfilled blank in the operator's own `models.json`.
That check is deliberately non-fatal on any shape problem: an absent, unreadable, or malformed models file warns on stderr once and dispatches anyway, so a pi change can cost the guard but never the lane.

`bin/fm-free-lane-run.sh --install-launcher` writes a home-local launcher to `config/free-lane-launcher` whose shebang is an `av inject` line naming exactly the four lane keys, resolving this machine's own `av` path.
The launcher names all four keys so that one blessing covers every lane, but the lane process itself is given only the invoked lane's own key: the script removes the other three before it starts pi.
The narrowed environment also carries `FM_FREE_LANE_ACTIVE=1`, and a lane invocation that already sees that marker refuses with exit 4 rather than starting a second lane session.
Together these mean the pi process for a lane holds only that lane's own key, and the incidental path where a lane session simply starts another lane is closed.
Neither is a boundary, and this page does not claim one: the blessed launcher is by design a no-prompt path to any lane for anything that can execute it, a cooperating agent could unset the marker before invoking it, and the invoked lane's own key stays readable inside its own session.
Both residuals are accepted deliberately, because buying them out would need the keys to reach pi by a path the session cannot read at all, which is a larger design not bought here.
The owner then runs `av bless <that path>` once, and every later call runs without a further approval prompt.
The launcher is home-local and gitignored because its shebang carries a machine-specific interpreter path, which is also why the portable script cannot carry that shebang itself.
Re-run `--install-launcher` and `av bless` after moving or reinstalling the firstmate home, because the launcher records an absolute path to the tracked script.

## Spawning a worker on a lane

`bin/fm-spawn.sh` wires a whole pi crewmate through a free-tier lane instead of only a hand-run one-shot call, closing the gap the dispatch rule below used to warn about.
No new profile field: `--harness pi` (or `pi-signed`) with a `--model` whose provider segment (the text before the first `/`) matches a lane in `bin/fm-free-lane-run.sh`'s own table - `groq`, `cerebras`, `cloudflare`, `openrouter-free` - is enough, and that is exactly the `model` string the dispatch rule's `use` array already carries.
A paid pi model is completely unaffected: the provider segment simply does not match any lane, and the spawn proceeds exactly as it did before this wiring existed.
A raw launch command passed in place of a harness name (the unverified-adapter escape hatch) is exempt too: that form supplies its own command line, which has no place for the lane wrap, so it never reaches a lane and is never preflighted.

Key delivery for a spawned worker rides the same blessed launcher as a hand-run call, never an env file and never a plaintext copy: `fm-spawn` runs the worker's real pi process through `<launcher> --exec <lane> -- <pi ...>`, a launcher mode that narrows the environment to that one lane's key and carries the same re-entry guard as every other lane invocation (`bin/fm-free-lane-run.sh`'s header owns the exact mechanics).
Unlike a hand-run one-shot call, this worker keeps pi's normal tools, brief, and turn-end wiring - it is a full agentic worker on the free-tier key, not the slim text-only shape `--no-builtin-tools`/`--no-context-files`/`--no-extensions` produce.
That is exactly why the scope in the dispatch rule's `when` clause is load-bearing here, not optional flavor text.

Every failure mode refuses the spawn outright rather than falling back to a paid pool: a launcher that is not installed, executable, or shaped like a generated `av inject` launcher; a vault key absent for the selected lane; a launcher that is not yet blessed; or a lane table that cannot be read at all, since a model that cannot be classified might still be a lane model.
That last case is a genuine constraint worth understanding: `av`'s own blessing prompt is interactive, and an unblessed launcher's shebang blocks on a "human approval required" prompt instead of exiting - there is no query to ask `av` "is this blessed" without risking that same block.
`fm-spawn` handles it with a bounded background probe (a few seconds) through the exact same launcher path a real launch would use; a probe still running past that bound is treated as unblessed and killed rather than ever treated as success.
The practical requirement this leaves standing: an operator bless the launcher (`av bless <path>`, printed by `--install-launcher`) before this dispatch rule is used for real, exactly as for a hand-run call.

## Dispatch rule

Since `fm-free-lane-spawn-wiring` landed, this rule routes a whole spawned pi worker through a lane, not only a hand-run one-shot call: `bin/fm-spawn.sh` detects a free-lane model by its provider segment (the text before the first `/` in `--model`, matched against `bin/fm-free-lane-run.sh`'s own lane table) and wires the worker's pi process through the blessed launcher for key delivery, exactly as "Spawning a worker on a lane" below describes.
No new profile field is needed: the `model` string in the `use` array below is already the exact `--model` syntax `fm-spawn` reads, unchanged from before this wiring landed.

Scope the brief accordingly, and it matters MORE now than when this rule was one-shot-only: a spawned worker on this rule gets pi's normal tools, brief, and turn-end wiring - it is a full agentic worker, not a text-only call - so the boilerplate-only, no-design-judgement scope in the `when` clause below is the thing keeping it safe, not any lack of tool access.
The `bin/fm-free-tier-guard.sh` check below is a mechanical backstop for that scope, never a replacement for reading the brief.
The captain's standing rule holds regardless of which form dispatches the lane: free lanes carry only low-judgement bulk work in a registered non-core repo, never work that is important, complex, security-sensitive, or judgement-heavy.
A hand-run one-shot call through [`bin/fm-free-lane-run.sh`](../bin/fm-free-lane-run.sh)'s default form (not the `--exec` worker path) is still text-only regardless: no built-in tools, no extension tools, no `AGENTS.md`/`CLAUDE.md` context, so any fixture shape, module signature, or existing test style the generated boilerplate must match has to be quoted into the brief itself; that call form returns text for the dispatching agent to place, it is not a worker that opens files in the repo.

`config/crew-dispatch.json` is home-local and gitignored, so this repository ships the rule text rather than the file.
Add this object to the `rules` array of the home's own `config/crew-dispatch.json`, keeping it ahead of the general cheap-model rule so the narrower condition is matched first.
[`docs/configuration.md`](configuration.md) owns the file's schema.

```json
{
  "when": "Boilerplate test generation in a registered non-core repo: fixtures, mocks, or assertion scaffolding with no design judgement, in a project where free-tier routing has been enabled and bin/fm-free-tier-guard.sh returns eligible for this repo and brief.",
  "use": [
    {
      "harness": "pi",
      "model": "groq/openai/gpt-oss-120b",
      "effort": "low"
    },
    {
      "harness": "pi",
      "model": "cloudflare/@cf/openai/gpt-oss-120b",
      "effort": "low"
    },
    {
      "harness": "pi",
      "model": "openrouter-free/minimax/minimax-m3:free",
      "effort": "low"
    }
  ],
  "why": "Free-tier relief for the highest-volume, lowest-judgement task class. Candidates are in survey-preference order from docs/free-tier-providers.md: Groq first (Services Agreement forbids training on inputs account-wide, no free-tier carve-out), Cloudflare Workers AI second (published no-training term), OpenRouter last for breadth (non-logging upstreams only by default). Cerebras is deliberately absent: its account returned 402 payment_required on every chat completion on 2026-09-01 despite a live key, so it is held out until the account clears. Never select this profile without a passing bin/fm-free-tier-guard.sh check. A worker spawned on this profile is a full agentic pi worker, not a text-only call: bin/fm-spawn.sh routes it through the blessed launcher at config/free-lane-launcher for key delivery (never an env file, never ad-hoc av inject), refusing the spawn outright rather than falling back to a paid pool if the launcher is missing, unblessed, or the vault key is absent. That means the boilerplate-only, no-design-judgement scope in this rule's own when clause is the actual safety boundary, not any lack of tool access. See docs/free-tier-routing.md."
}
```

The `use` array is a quota-aware candidate list resolved by [`quota-array-dispatch`](../.agents/skills/quota-array-dispatch/SKILL.md), in the survey preference order of [`docs/free-tier-providers.md`](free-tier-providers.md).
Cerebras is absent from it on purpose: the lane is registered in pi and its account still refuses every completion, so listing it would spend a dispatch on a certain failure.
Add it back as the second candidate once the account clears.

The rule is advisory data.
The guard below is a mechanical backstop that catches obvious mis-scoping only; firstmate's own judgement when writing the brief remains the actual gate.

## The guard

[`bin/fm-free-tier-guard.sh`](../bin/fm-free-tier-guard.sh) is run at brief-writing time, before the dispatch rule above may be selected.
Its header owns the exact flags, exit codes, and matching rules.

The repository allowlist is `config/free-tier-repos`, one repository name per line, blank lines and `#` comments ignored.
It is home-local and gitignored like every other `config/` file.
An absent, empty, or unreadable allowlist refuses every repository, so free-tier routing stays off until a home opts a repository in by name.

```bash
bin/fm-free-tier-guard.sh --repo <name> --brief-file <path>
```

Exit 0 prints `eligible: <repo>` and is the only state in which the free-tier profile may be selected.
Exit 1 prints the refusal reason; fall through to the existing paid cheap-model rule and dispatch there instead.
Exit 2 means the check did not run at all, which covers a usage error and `--help`, and is never permission to dispatch.

Run `bin/fm-free-tier-guard.sh --help` for the current deny set and matching rules, which it prints from the values the check itself uses; the guard is the single source of truth and this page deliberately does not restate it.
It over-refuses on purpose: a false refusal costs one fallback to the paid tier, while a miss publishes content to a vendor.
A keyword list is not a classifier, so a brief that crosses a data line without using a deny term still passes; do not lean on the guard in place of reading the brief.

## Comparison procedure

This is a procedure to run by hand over a small fixed sample, not a service to build.
Run the same brief twice, once under the free-tier profile and once under the existing paid cheap-model profile, over 5 to 10 tasks per side before drawing any conclusion.

For each task, record from the pipeline's own output, with no new instrumentation:

- Whether validation passed on the first attempt, and how many fix-review cycles it took if not.
- Whether the worker ever reported tests passing while the pipeline's own run disagreed, which is the false-completion case that matters most.
- The wall-clock and turn count each side spent.

Alongside the comparison, measure the share of the window this class actually represents: over the same period, count the boilerplate-test tasks dispatched and what fraction of all dispatched tasks they were.
The relief this pilot can deliver is bounded above by that fraction, and no useful estimate of it exists before the pilot measures it.

Conclude the pilot only when both halves are answered: whether free-tier output survives the same gates, and whether the class is a big enough slice to be worth the routing.

## Lane status

Account creation is the owner's step, and all four accounts exist as of 2026-09-01.
The environment variable column is the name the lane's `apiKey` interpolation and the blessed launcher both use.

| Lane | Sign-up | Env var | Status on 2026-09-01 |
|---|---|---|---|
| Groq | `console.groq.com` | `GROQ_API_KEY` | Live. Pilot vendor: no training account-wide, 1,000 requests/day, 8,000 tokens/minute |
| Cloudflare Workers AI | `dash.cloudflare.com` | `CLOUDFLARE_API_KEY` | Live. Published no-training term, 10,000 neurons/day, account-scoped endpoint |
| OpenRouter | `openrouter.ai` | `OPENROUTER_API_KEY` | Live on free models. Breadth lane, 50 requests/day until the account holds credit |
| Cerebras | `cloud.cerebras.ai` | `CEREBRAS_API_KEY` | Registered, refused. Key authenticates and every completion returns `402 payment_required` |

Scaleway is deliberately absent: the survey now records it as rejected, because its console shows per-token paid pricing with no free allowance.

Providers not in that table are surveyed in [`docs/free-tier-providers.md`](free-tier-providers.md) and are not recommended for a key today.
