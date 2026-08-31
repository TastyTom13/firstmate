# ChatGPT (Codex) quota reading verification

Audience: maintainer verification.

This record supports `bin/fm-gpt-quota.sh` and, through it, the ChatGPT pool of the bearings usage gauge (`bin/fm-quota-pools.sh`).
It records the vendor behaviour the reader depends on, so a change on OpenAI's side is re-established here rather than guessed at.
Task chronology and incident evidence stay in private reports or PR evidence.

## Why a firstmate-owned reader exists at all

`quota-axi` reads each provider's local usage records.
A home that talks to OpenAI through an OAuth ChatGPT account with no `codex` CLI installed has no such record, so `quota-axi` reports `codex,all,error,Codex quota unavailable,none` and can report nothing better.
Verified 2026-08-31 against quota-axi 0.1.34 on a home whose only OpenAI credential is the `openai-codex` OAuth entry in `~/.pi/agent/auth.json`.

## The account's quota is on the response, not behind an endpoint

Verified 2026-08-31 against `https://chatgpt.com/backend-api`.

Three candidate sources were probed with the stored OAuth access token and `chatgpt-account-id` header:

- `GET /backend-api/codex/usage`, `GET /backend-api/me`, `GET /backend-api/accounts/check/v4-2023-04-27`, and `GET /backend-api/codex/rate_limits` each returned HTTP 403 with an HTML body.
  The same credential returned HTTP 200 and `{"items": [], "cursor": null}` from `GET /backend-api/wham/tasks` in the same run, so the 403s are those routes refusing this client, not a bad credential.
  There is no usage endpoint this credential can call.
- `POST /backend-api/codex/responses` attaches the account's current rate-limit state to the response as `x-codex-*` headers.
  This is the readable source, and it is the provider's own enforced figure rather than a local estimate.
- A local tally of this home's own Pi requests was therefore not implemented.
  It would measure this home's spend rather than the account's remaining allowance, which is a different question; `bin/fm-gpt-quota.sh` reserves `estimate: true` for a source of that kind.

## The reading costs nothing

The reader sends a request that names a supported model and carries no `input`.
The backend validates the model, attaches the rate-limit headers, and rejects the request with HTTP 400 `missing_required_parameter` before invoking any model.

Verified 2026-08-31, request body `{"model":"gpt-5.5","stream":true,"store":false}`:

```
status=400 codexHeaders=14
{"x-codex-active-limit":"premium","x-codex-credits-balance":"","x-codex-credits-has-credits":"False",
 "x-codex-credits-unlimited":"False","x-codex-plan-type":"free",
 "x-codex-primary-over-secondary-limit-percent":"0","x-codex-primary-reset-after-seconds":"2591264",
 "x-codex-primary-reset-at":"1790804272","x-codex-primary-used-percent":"6",
 "x-codex-primary-window-minutes":"43200","x-codex-secondary-reset-after-seconds":"0",
 "x-codex-secondary-reset-at":"","x-codex-secondary-used-percent":"0",
 "x-codex-secondary-window-minutes":"0"}
```

Two 400 probes in succession both reported `x-codex-primary-used-percent: 6`, so the probe does not move the counter it reads.

Two earlier failure modes bound the technique and are why the reader names the model it probes with:

- A request whose model is unknown (`{"model":"no-such-model-xyz"}`) or absent returns HTTP 400 with **zero** `x-codex-*` headers and the body `The '<name>' model is not supported when using Codex with a ChatGPT account.`
  Model validation happens before the headers are attached, so a retired probe model silently costs the reading.
  `bin/fm-gpt-quota.sh` reports that case as `no_headers` naming the model, and `FM_GPT_QUOTA_MODEL` changes it without a code edit.
- `GET /backend-api/codex/responses` returns HTTP 405 with zero `x-codex-*` headers, so there is no header-only read that avoids a POST.

## Header meanings the reader relies on

- `x-codex-primary-window-minutes` / `x-codex-secondary-window-minutes` - the window length. `43200` is 30 days, `10080` is 7 days.
  A window the account does not have is reported as `0` minutes with an empty `reset-at`; the reader drops it rather than rendering a fully free window that does not exist.
- `x-codex-primary-used-percent` - percent of that window consumed, an integer. Remaining is `100 - used`.
- `x-codex-primary-reset-at` - reset instant as epoch seconds.
- `x-codex-plan-type` and `x-codex-active-limit` - recorded as evidence, never used to compute the figure.

The account observed on 2026-08-31 reported `x-codex-plan-type: free` with `x-codex-active-limit: premium` and a single 30-day window, while the JWT's `chatgpt_plan_type` claim also read `free`.
Plan naming is therefore not a reliable signal of which windows exist; the window headers are.

## How to re-establish this record

```
bin/fm-gpt-quota.sh --json
```

A `status: "known"` reading with a non-empty `windows` array confirms every fact above that the reader depends on.
A `status: "unavailable"` reading names which one broke: `no_headers` means the probe model or the header contract changed, `auth_required` or `auth_expired` means the credential did, and `unreachable` means the network did.

`tests/fm-gpt-quota.test.sh` pins the reader's own logic against recorded headers with no network, so it cannot detect a vendor change; only the command above can.
