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

Groq is the pilot vendor because its Services Agreement forbids training on inputs account-wide, with no free-tier carve-out.
Both entries are home-local configuration on the machine that runs the worker, not tracked repository state.

`GROQ_API_KEY` must be exported in the environment the worker harness inherits.

Neither block below has been dispatched against a real harness, because no Groq key exists yet; treat both as unverified until the first key proves them.

OpenCode, in `~/.config/opencode/opencode.json`.
This block's field names were not verified against an installed OpenCode, so check the installed version's own configuration reference before pasting it:

```json
{
  "provider": {
    "groq": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Groq",
      "options": {
        "baseURL": "https://api.groq.com/openai/v1",
        "apiKey": "{env:GROQ_API_KEY}"
      },
      "models": { "openai/gpt-oss-120b": { "name": "GPT-OSS 120B (Groq)" } }
    }
  }
}
```

Dispatch it as `--model groq/openai/gpt-oss-120b`; confirm the exact identifier with `opencode models groq` before first use.

Without the `apiKey` binding the provider dispatches unauthenticated and fails on the first call, so confirm how the installed OpenCode spells that environment reference before pasting.

Pi, as a custom provider in Pi's own settings file.
The field names below were not verified against an installed Pi, so read Pi's installed `docs/models.md` and `docs/settings.md` for the current key names before pasting this block:

```json
{
  "providers": {
    "groq": {
      "baseUrl": "https://api.groq.com/openai/v1",
      "apiKeyEnv": "GROQ_API_KEY",
      "models": ["openai/gpt-oss-120b"]
    }
  }
}
```

Pi's installed `docs/models.md` owns how custom provider entries reach `--list-models`; confirm the entry appears there before dispatching against it.

## Dispatch rule

`config/crew-dispatch.json` is home-local and gitignored, so this repository ships the rule text rather than the file.
Add this object to the `rules` array of the home's own `config/crew-dispatch.json`, keeping it ahead of the general cheap-model rule so the narrower condition is matched first.
[`docs/configuration.md`](configuration.md) owns the file's schema.

```json
{
  "when": "Boilerplate test generation in a registered non-core repo: fixtures, mocks, or assertion scaffolding with no design judgement, in a project where free-tier routing has been enabled and bin/fm-free-tier-guard.sh returns eligible for this repo and brief.",
  "use": { "harness": "opencode", "model": "groq/openai/gpt-oss-120b", "effort": "low" },
  "why": "Free-tier relief for the highest-volume, lowest-judgement task class, on the vendor whose terms forbid training on inputs regardless of tier. Never select this profile without a passing bin/fm-free-tier-guard.sh check; see docs/free-tier-routing.md."
}
```

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

## Keys the owner must create

Account creation is the owner's step.
Ranked by value for this pilot, with the environment variable each key is read from:

| Rank | Provider | Sign-up | Env var | Why |
|---|---|---|---|---|
| 1 | Groq | `console.groq.com` | `GROQ_API_KEY` | Pilot vendor: no training account-wide, 1,000 requests/day |
| 2 | Cerebras | `cloud.cerebras.ai` | `CEREBRAS_API_KEY` | Verified equivalent data posture, 1M tokens/day |
| 3 | Scaleway | `console.scaleway.com` | `SCW_SECRET_KEY` | EU/GDPR, zero data retention, no training, 1M free tokens |
| 4 | Cloudflare Workers AI | `dash.cloudflare.com` | `CLOUDFLARE_API_TOKEN` | Published no-training term, 10,000 neurons/day |
| 5 | OpenRouter | `openrouter.ai` | `OPENROUTER_API_KEY` | Breadth of open-weight models, logging providers excluded by default |

Providers below this line are surveyed in [`docs/free-tier-providers.md`](free-tier-providers.md) and are not recommended for a key today.
