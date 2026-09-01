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
Live here means live through the launcher; a spawned crewmate does not yet reach these lanes, as the dispatch rule section below explains.
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
That launcher is the only path that delivers a lane key today, which is why a spawned crewmate cannot use a lane until `fm-free-lane-spawn-wiring` lands.

[`bin/fm-free-lane-run.sh`](../bin/fm-free-lane-run.sh) is the single command shape for every lane; its header owns the exact flags, lane table, and exit codes.
It is an ordinary portable script that reads each lane's key from its own environment and refuses with exit 3 when that variable is absent, so an unauthenticated lane never dispatches.
Before the cloudflare lane only, it also refuses when the account segment of that provider's `baseUrl` is still an unfilled blank in the operator's own `models.json`.
That check is deliberately non-fatal on any shape problem: an absent, unreadable, or malformed models file warns on stderr once and dispatches anyway, so a pi change can cost the guard but never the lane.

`bin/fm-free-lane-run.sh --install-launcher` writes a home-local launcher to `config/free-lane-launcher` whose shebang is an `av inject` line naming exactly the four lane keys, resolving this machine's own `av` path.
The owner then runs `av bless <that path>` once, and every later call runs without a further approval prompt.
The launcher is home-local and gitignored because its shebang carries a machine-specific interpreter path, which is also why the portable script cannot carry that shebang itself.
Re-run `--install-launcher` and `av bless` after moving or reinstalling the firstmate home, because the launcher records an absolute path to the tracked script.

## Dispatch rule

Read this before installing the rule: the free-tier lanes are launcher-only today.
They work when a lane is invoked by hand through [`bin/fm-free-lane-run.sh`](../bin/fm-free-lane-run.sh) or the blessed launcher, and only then.
A crewmate spawned on this rule does not inherit the lane keys, because the spawn path launches the `pi` binary directly and knows nothing about the launcher.
Selecting this rule today therefore produces a worker whose free-tier model is unavailable in its own pane, so the rule must not be relied on for real dispatch yet.
The follow-up task `fm-free-lane-spawn-wiring` is the work that closes that gap; install the rule now only to have it ready, not to route real work through it.

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
  "why": "Free-tier relief for the highest-volume, lowest-judgement task class. Candidates are in survey-preference order from docs/free-tier-providers.md: Groq first (Services Agreement forbids training on inputs account-wide, no free-tier carve-out), Cloudflare Workers AI second (published no-training term), OpenRouter last for breadth (non-logging upstreams only by default). Cerebras is deliberately absent: its account returned 402 payment_required on every chat completion on 2026-09-01 despite a live key, so it is held out until the account clears. Never select this profile without a passing bin/fm-free-tier-guard.sh check. Routine invocations go through the blessed launcher at config/free-lane-launcher, never ad-hoc av inject. LAUNCHER-ONLY UNTIL fm-free-lane-spawn-wiring LANDS: the spawn path launches pi directly and does not deliver the lane keys, so a crewmate spawned on this profile will not have a working free-tier model in its pane. See docs/free-tier-routing.md."
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
