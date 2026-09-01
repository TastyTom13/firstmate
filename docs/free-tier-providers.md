# Free-tier provider survey

This page records what a single fresh account gets from each legitimate model provider, and what that vendor's own terms say about training on your input.
It exists so a routing decision can be made from evidence instead of a marketing page.
[`docs/free-tier-routing.md`](free-tier-routing.md) is the pilot that acts on it.

Survey date: 2026-08-31, with the Scaleway and Cerebras rows corrected against live accounts on 2026-09-01.
Rate limits and free allowances change without notice; re-read the vendor's own dashboard before relying on any number here.

## How to read this page

Every training or retention claim below is either a quote from the vendor's own terms with its source, or is marked **unverified**.
A vendor that says nothing about training is recorded as "assume trains", because silence is not a promise.

**Dispatchable** means a harness can send a task to it: an HTTP API with a key.
A browser-only or chat-only surface is not dispatchable no matter how good the models are.

**Rejected** means the vendor is out under a policy line, not that it is a bad product.

## Summary

| Vendor | Published terms | Trains on free-tier input | Free allowance | Dispatchable | Verdict |
|---|---|---|---|---|---|
| Groq | Yes | No, account-wide | 30 RPM / 1,000 req per day | Yes, OpenAI-compatible | **Recommended** |
| Cerebras | Yes | No, by limited-purpose clause | Published 1M tokens per day; this account gets none | Yes, OpenAI-compatible | **Recommended** on terms, blocked in practice |
| Scaleway Generative APIs | Yes | No, explicit | **None**, per-token paid pricing | Yes, OpenAI-compatible | Rejected, no free allowance |
| Cloudflare Workers AI | Yes | No, explicit | 10,000 neurons per day | Yes | **Recommended** |
| OpenRouter (free models) | Yes | No by OpenRouter; logging upstreams excluded by default | 50 req per day, 1,000 with $10 credit | Yes | Usable |
| OrcaRouter (free models) | Yes | No by OrcaRouter; upstreams on own terms | 10 RPM / 50 req per day | Yes | Usable, small |
| Fireworks AI | Yes | No, explicit opt-in only | $1 one-off credit, no recurring tier | Yes | Usable but not a free tier |
| SEA-LION (AI Singapore) | Partial | Unverified | 10 RPM, one key per user | Yes, OpenAI-compatible | Narrow, SE-Asian languages |
| Typhoon | Partial | Unverified | 200 RPM on the main models | Yes | Narrow, Thai |
| Hugging Face Inference Providers | Yes | Per upstream provider | $0.10 per month of credits | Yes | Too small to matter |
| Cohere | Yes | Yes, "improve and enhance" | 1,000 calls per month, 20 RPM | Yes | Rejected on terms |
| SambaNova | Yes, but silent on training | Assume yes | 20 RPM / 20 req per day | Yes | Rejected, silent + tiny |
| SiliconFlow | Partial, mostly Chinese | Unverified | Fixed limits on free models | Yes | Rejected, KYC + jurisdiction |
| Z.ai (Zhipu) | Yes | Yes, stated legitimate interest | Several GLM Flash models at $0 | Yes | Rejected on terms |
| NVIDIA NIM / build.nvidia.com | Yes | Yes, explicit | ~1,000 trial credits | Yes | Rejected on terms and trial-only licence |
| GitHub Copilot Free | Yes | Yes by default since 2026-04-24 | 2,000 completions per month | Only via Copilot clients | Rejected on terms |
| Google AI Studio / Gemini | Yes | Yes, plus human review | Small and volatile | Yes | Rejected on terms |
| Mistral (Experiment tier) | Yes | Yes by default, manual opt-out | 1 req/sec, ~1B tokens per month | Yes | Conditional at best |
| Agnes AI | Yes | Yes, explicit for the free API tier | RPM 20, no end date | Yes | Rejected on terms |
| Requesty | Partial | Unverified | Router with 5% markup; signup credits unstated | Yes | Router, not a free pool |
| Puter AI | Yes | Not applicable | Per end-user allocation | **No**, browser JS only | Rejected, not dispatchable |
| b.ai | Not read | Unknown | None found | Unclear | Rejected, unverifiable |
| Grok / xAI | Yes (consumer) | Yes for free chat | No free API tier at all | **No** | Rejected, nothing to dispatch |
| GitHub Models | N/A | N/A | Retired 2026-07-30 | **No** | Dead |
| freellmapi | Yes | Delegated to 34 upstreams | Sum of your own upstream keys | Yes | Amber, adds no protection |

## Recommended

### Groq

Groq Services Agreement §4.2: *"Groq is not permitted to use Inputs or Outputs for training or fine-tuning any AI Model Services or other models, unless explicitly granted permission or instructed by Customer."*
The companion retention page states *"By default, Groq does not retain customer data for inference requests,"* with a 30-day abuse-log exception.
Neither clause is split by tier, which is what separates Groq from every other free tier surveyed: Google and Mistral both give the free lane a weaker promise than the paid one, and Groq does not.
Free limits are 30 requests per minute and 1,000 per day on flagship open-weight models, measured at organisation level.
Source: `console.groq.com/docs/legal/services-agreement`.

### Cerebras

The report this pilot came from left Cerebras marked unverified because the Inference Terms PDF would not extract.
That gap is now closed by reading the PDF pages directly.
§3(c) "Prompts and User Content" states: *"You agree that we may access and use the User Content to provide the Services and comply with applicable law (the 'Purpose'). We retain the User Content only to the extent necessary in connection with the Purpose, and we have the right to remove any User Content in our sole discretion."*
Training is not in that stated Purpose, and §3(d) "Usage Data" is drafted as *"diagnostic and usage related information, excluding User Content"* before granting the broad improve-and-develop rights.
So the improvement right that other vendors apply to your prompts is applied at Cerebras only to data that explicitly excludes them.
This is a no-training posture reached by a limited purpose rather than by an explicit no-training sentence, which is a shade weaker in form than Groq's clause but equivalent in effect.
Free limits are published as 5 requests per minute and 1M tokens per day on `gpt-oss-120b`, plus $5 of credits that expire after 30 days.
**Those limits were not reachable on 2026-09-01.**
A live key on this account lists models over `GET /v1/models` and then returns `402 payment_required` with `"param":"quota"` on every `POST /v1/chat/completions`, on both `gpt-oss-120b` and `gemma-4-31b`.
An authenticated model listing is therefore not evidence that a lane can generate; only a completion is.
Sources: the Inference Terms and Conditions PDF linked from `cerebras.ai`, and `inference-docs.cerebras.ai/support/rate-limits`.

### Cloudflare Workers AI

Cloudflare's developer-platform service-specific terms state: *"Unless otherwise agreed, Cloudflare does not use any Customer Content to train generative AI tools."*
Inputs and Outputs are both Customer Content under those terms.
The free allowance is *"10,000 Neurons per day at no charge"*, resetting at 00:00 UTC, on both Free and Paid Workers plans; a neuron is Cloudflare's own compute unit, so the token equivalent depends entirely on the model.
Sources: `cloudflare.com/service-specific-terms-developer-platform/` and `developers.cloudflare.com/workers-ai/platform/pricing/`.

## Usable with caveats

### OpenRouter

OpenRouter's own posture is *"OpenRouter does not use your Inputs or Outputs for model training"*, while *"Some Model Providers may use your Inputs and Outputs for model training or improvement."*
The operational detail that makes this enforceable is that providers which log, or whose policy OpenRouter could not confirm, are excluded from routing unless you switch on a training-permission toggle.
Default behaviour is exclusion, which is the opposite default from Google and Mistral.
Free-model limits are 50 requests per day without purchased credits, 1,000 per day with $10 or more of credit, and 20 requests per minute.

### OrcaRouter

A zero-markup router whose permanently free Hacker plan includes three API keys and 0% token markup, plus a rotating pool of genuinely $0-per-token models at 10 requests per minute and 50 per day, rising to 20 per minute and 800 per day once a workspace has ever paid $20.
Its Trust Center states plainly: *"We do not use your prompts or completions to train models. Upstream providers are bound by their own terms."*
Zero data retention is offered on supported routes.
Two things follow.
The free routing is worth having only once paid keys exist, because a router with no keys routes nothing.
The free model pool is small but real, and is a legitimate second free lane rather than a repackaged one.
The same vendor's blog is also the clearest published statement of this survey's rejection rule: any page promising free frontier tokens without qualification is showing a revoked key, a terms violation, or both.

### Fireworks AI

Its privacy policy commits: *"We do not use your prompts, training data, or API inputs to train or improve our AI models without your explicit opt-in"* and *"We do not log or store prompt or generation data for any open models without explicit user opt-in."*
That is a strong posture, but the free offering is $1 of one-off credits for new accounts, not a recurring free tier.
Treat it as a trial, not a lane.

### SEA-LION

Operated by AI Singapore, a national programme under the National Research Foundation and hosted by the National University of Singapore, so the operator is unusually accountable for a free service.
The API is OpenAI-compatible at `https://api.sea-lion.ai/v1`, with one trial key per user and a 10 requests-per-minute limit, and the documentation states the free API is for proof-of-concept work rather than production.
Its data-usage position is deferred to a separate Terms of Use and Privacy Policy that this survey did not read: **training stance unverified**.
The models are tuned for Southeast Asian languages, so the fit for English test scaffolding is poor even where the terms turn out to be fine.

### Typhoon

A Thai-language model family with a free API at 5 requests per second and 200 per minute on its main instruct models, and 20 per minute on OCR.
No data or training statement was found on the documentation pages read: **training stance unverified**, therefore assume it trains.
Like SEA-LION, its value is language coverage, not general code work.

### Hugging Face Inference Providers

Free accounts receive *"$0.10, subject to change"* of monthly inference credits, against $2.00 for PRO.
Ten cents a month is not a routing lane; it is a demo budget.
Training stance is per upstream provider, because Hugging Face routes rather than serves.

## Rejected, with the reason

### Scaleway Generative APIs

**Rejected on 2026-09-01: no free allowance.**
The owner's own console shows per-token paid pricing for the Generative APIs with no free tier attached to the account.
The "1,000,000 free tokens" figure this page previously carried came from a marketing and FAQ page rather than from the console, and it is stale: it was recorded as a free allowance without an account to check it against.
Everything below about its data posture still holds and is why it stays worth re-checking if Scaleway ever reintroduces a free tier.

It has the strongest written promise in the survey, and it is the only EU-jurisdiction one.
Its Generative APIs privacy policy states: *"Your data is not accessible to the creators of the underlying large language models (LLMs). Your data is not used for training, retraining, or improving the base models."*
It also states *"By default we apply a Zero Data Retention Policy"* and *"We do not collect, read, reuse, or analyze the content of your inputs, prompts, or outputs generated by the API"*, with a narrow exception for temporarily storing request content when a request triggers a server error or looks malicious, held up to two weeks.
The processor is Scaleway, registered in Paris, with models hosted in European data centres and GDPR compliance claimed directly.
The *"up to 1,000,000 tokens for models billed by tokens"* line still appears in the vendor's own documentation, and the console contradicts it for this account, which is why the verdict above is drawn from the console.
Serverless requests are rate limited without a published number, and the Batches API has no rate limit for non-real-time work.
Sources: `scaleway.com/en/docs/generative-apis/reference-content/data-privacy/` and `.../faq/`.

### Cohere

The Terms of Use grant Cohere the right to process customer data to *"IMPROVE AND ENHANCE THE COHERE SOLUTION"*, which is a training-permissive clause with no free-tier carve-out in the opposite direction.
Free trial keys are capped at *"1,000 API calls a month"* with 20 requests per minute on chat models.
Multiple secondary sources report that trial keys are additionally not permitted for production or commercial use; that exact sentence was not found in the primary documentation pages read here, so the restriction is **unverified** while the training clause is not.
Rejected on the training clause alone.

### SambaNova

Free limits are 20 requests per minute, 20 requests per day, and 200,000 tokens per day, identical across every free model.
20 requests per day is not a working lane for any real task.
The Terms and Conditions contain no clause on using inputs or outputs for model training, so under this survey's rule the answer is assume yes.
Rejected for both reasons.

### SiliconFlow

Keeps a small set of open-source models permanently free, but its own documentation requires real-name authentication before free models can be used: *"实名认证后使用全部的免费模型"* — after real-name verification, use all the free models.
Handing government identity to a Chinese platform to obtain free inference is a jurisdiction and identity cost this pilot has no reason to pay.
No English training clause was found: **unverified**, therefore assume it trains.

### Z.ai (Zhipu)

Several GLM Flash text and vision models are priced at $0.
The privacy policy names model training as a purpose it processes Communication Information for, on a legitimate-interest basis: *"including in developing, improving, or promoting our Services, such as when we train and improve our models."*
That is a plain statement that prompts feed training.
Rejected on terms.

### NVIDIA NIM / build.nvidia.com

The strongest evidence of the survey, and it goes the wrong way.
NVIDIA's API Trial Terms of Service §3.3 lists the data NVIDIA collects to operate and improve its products, ending with *"(iv) User Content and Generated Content to improve NVIDIA products and services, including AI models."*
§1.4 adds a licence limit: *"Unless you purchase a Subscription from NVIDIA or a Service Provider (as applicable), you may only use the API Service for internal testing and evaluation purposes, not in production."*
§2.6(a) separately forbids submitting confidential information, sensitive data, or personal data at all.
Free credits are widely reported as 1,000 on signup rising to 5,000 with a business email, at 40 requests per minute; those figures come from secondary sources and are **unverified**.
Rejected twice over: it trains on input, and shipping work through it is outside the trial licence.

### GitHub Copilot Free

2,000 inline completions per month plus an allowance of GitHub AI credits.
GitHub's own policy page states: *"Starting on April 24, 2026, if you have a Copilot Free, Copilot Pro, Copilot Pro+, or Copilot Max plan, GitHub may use your interactions with GitHub features and services... to train and improve AI models."*
The setting "Allow GitHub to use my data for AI model training" is on by default for those plans and must be disabled by hand; Business and Enterprise plans do not have it because their data is covered by the Data Protection Agreement.
It is also only reachable through Copilot-authenticated clients rather than as a general API.
Rejected: a manual, per-account, silently-reversible opt-out is exactly the fragility a routing lane must not depend on.

### Google AI Studio / Gemini free tier

Unpaid: *"Google uses the content you submit to the Services and any generated responses to provide, improve, and develop Google products and services and machine learning technologies"* and *"human reviewers may read, annotate, and process your API input and output."*
Paid has the opposite clause.
This is the clearest confirmation in the survey that unpaid means published and read by a person.
Free request limits are genuinely volatile and only reliable from the live dashboard: **exact current figures unverified**.

### Agnes AI

A first-party lab (SapiensAI) with real published terms, a free multimodal API with no fixed end date, and roughly 20 requests per minute.
Its privacy policy is explicit about the price: *"For users of the Free API tier and other Free Services, interactions with the Service may be used to train and improve our AI models unless you opt out where applicable"*, while *"Enterprise customers and Paid Token Plan users are excluded from model training by default."*
Rejected on terms, but recorded as a legitimate vendor with honest documentation rather than as a scam.

### Puter AI

Rejected on plumbing, not on ethics.
Puter's model is that each signed-in end user spends their own allocation, and the platform advertises *"No API keys in your frontend or backend: nothing to leak, steal, or rotate"* and *"There are no API keys to obtain, no servers to provision, and no SDK setup."*
That is browser JavaScript scoped to a logged-in human.
There is no server-side key for a headless worker to hold, so there is nothing for a harness to dispatch against.

### b.ai

Presented as Web3 infrastructure giving agents "permissionless access to leading AI models" with on-chain payment and identity rails, on contact-for-pricing terms.
No free tier was found, no published training clause was read, and unqualified access to frontier models through a third party is the exact pattern the hard lines reject.
Rejected as unverifiable.

### Grok / xAI

There is no free API tier.
Free Grok access is the consumer chat product on grok.com, X, and X Premium, which has no programmatic surface a harness can dispatch to.
Rejected on plumbing.

## Not rejected on terms, but not a free pool either

These vendors are not out under a policy line.
They are here because the Summary table's verdict for each is something other than a usable free pool: conditional, a paid router, dead, or a pass-through that adds no protection of its own.

### Mistral Experiment tier

Pay-as-you-go customers are opted out of training by default; the free Experiment plan is the named exception and may be used to train Mistral's models unless "Anonymous improvement data" is manually disabled in the Admin Console.
Volume is generous at roughly 1 billion tokens a month, and Codestral suits boilerplate code well.
Conditional at best: the protection depends on a manual toggle staying off, which nothing in this fleet would notice being flipped back.

### Requesty

A unified gateway over 600+ models at a stated 5% markup, with "free credits" on new accounts whose amount is not published: **unverified**.
It is a router, not a free token pool, and it costs more per token than going direct.
No training clause was found in the pages read.

### GitHub Models

Fully retired on 2026-07-30, redirecting to Azure AI Foundry or Copilot.
Several current-dated third-party comparison pages still list it as live with generous free limits, which is a standing reminder to check the vendor rather than the summary.

### freellmapi

An aggregator, entity Neu Software LLC, whose privacy policy states *"Your prompts, completions, and provider API keys are stored and processed locally on your device and are sent only to the AI providers you configure. They are never transmitted to, stored by, or visible to Neu Software LLC."*
Its own posture is therefore fine, and its posture overall is exactly as good as the worst upstream provider enabled behind it.
Its Anthropic-wire-format endpoint is protocol compatibility only, not Claude access; there is no Anthropic entry among its providers.
Amber: a convenience layer over already-vetted providers, adding neither independent risk nor independent protection.

## What a stacked pool actually buys

On paper, adding every recommended vendor gives roughly 1,000 Groq requests a day, 1M Cerebras tokens a day, 10,000 Cloudflare neurons a day, and 50 to 1,000 OpenRouter requests a day.
What 2026-09-01 actually bought was three of those four lanes: the Cerebras account refuses every completion.
Scaleway, which an earlier version of this line counted, has no free tier to add at all.
That is a real pool for mechanical work and nowhere near a replacement for a judgement lane.
The binding constraint is not the token count.
It is that a written promise not to train on your input stays rare, and the Summary table above is the current list of who makes one.
A first-party serving vendor's own promise is also not the same thing as a router passing the question upstream to whichever provider actually serves the request, nor the same thing as a one-off trial credit that expires.
The pilot's allow class exists precisely because it is the only work that survives being published.
