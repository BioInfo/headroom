# Provider Capture Sheet

One row per provider, filled by a DevTools spike before its collector is written. The collector replays exactly what is captured here. When a provider reships its frontend and a collector breaks, re-run the spike and update the row.

Columns: **login** (how the session is obtained) · **usage endpoint** (the internal XHR the page calls) · **auth** (cookie / bearer / how it rides) · **response** (the JSON fields we read) · **reset** (how the window/reset is expressed) · **status**.

---

## z.ai (GLM) — `zai`  ✅ CAPTURED 2026-06-13

- **Usage page:** `https://z.ai/manage-apikey/coding-plan/personal/usage`
- **Login:** in-app WKWebView; user logs into z.ai once (z.ai uses Google OAuth).
- **Usage endpoint:** `GET https://api.z.ai/api/monitor/usage/quota/limit`
  - (sibling endpoints on `api.z.ai`: `/api/monitor/usage/model-usage?startTime=&endTime=`, `/tool-usage`, `/api/biz/subscription/list`, `/api/biz/customer/getCustomerInfo` — for breakdown/plan detail if wanted later)
- **Auth: Bearer JWT, NOT a cookie.** The SPA stores creds in localStorage and attaches them itself. Cookies on the request are analytics only. Read these three localStorage keys and send as headers:
  - `Authorization: Bearer <localStorage["z-ai-open-platform-token-production"]>`
  - `bigmodel-organization: <localStorage["Bigmodel-Organization"]>`
  - `bigmodel-project: <localStorage["Bigmodel-Project"]>`
  - plus `accept: application/json`. Note API is on `api.z.ai` (different origin from the `z.ai` page; CORS allows it with `access-control-allow-credentials`).
- **Response shape:** `{ code, success, data: { level: "pro", limits: [ Limit ] } }` where each `Limit` is:
  - `TIME_LIMIT`: `{ usage, currentValue, remaining, percentage, nextResetTime(epoch ms), usageDetails:[{modelCode,usage}] }` — the prompt/request window (observed cap 1000).
  - `TOKENS_LIMIT`: `{ percentage, nextResetTime(epoch ms) }` — the token-budget window.
- **Reset semantics:** per-limit `nextResetTime` is epoch **milliseconds**. Two independent windows reset on different clocks. `data.level` = plan tier.
- **Collector recipe (proven live via in-page replay):** in the logged-in WKWebView, `evaluateJavaScript` a function that reads the three localStorage keys, fetches the endpoint with those headers, and returns the parsed `limits`. Token stays inside the webview. Map `TIME_LIMIT` and `TOKENS_LIMIT` → two `Metric`s (remaining/percentage authoritative=true, resetAt from nextResetTime).
- **🔑 BETTER PATH (found 2026-06-13): the WKWebView scrape is NOT required.** The quota endpoint also accepts the **local GLM Coding-Plan API key** as a plain Bearer — `GET api.z.ai/api/monitor/usage/quota/limit` with `Authorization: Bearer <coding-key>` returns 200 with the full `limits` payload (no web JWT, no localStorage, no browser). `…/api/biz/subscription/list` returns the plan name ("GLM Coding Pro"). So GLM can be a browser-free, local-key collector like Claude/Codex.
  - **"Works for everyone" caveat:** unlike Claude Code (`.credentials.json`/Keychain) and Codex (`~/.codex`), GLM has **no single canonical local key store** — the user wires it however (env var when used as a Claude Code backend: `ANTHROPIC_AUTH_TOKEN`; or `ZHIPUAI_API_KEY`/`Z_AI_API_KEY`/`GLM_API_KEY`; or a config file). So the GLM collector needs a key-resolution chain (env vars → known config paths → paste-once in-app), with the WKWebView login kept as the last-resort fallback. **OPEN DESIGN DECISION** before refactoring `ZaiCollector` key-first.
- **Status:** CAPTURED. Current collector uses WKWebView; refactor to local-key-first pending the key-source decision above.

## Kimi — `kimi`  ✅ CAPTURED + BUILT 2026-06-14 (token-paste, no webview — confirmed live)

DevTools spike on the logged-in `kimi.com/code/console` session captured the on-target coding-plan quota. Kimi signs in with Google, and Google blocks OAuth in embedded webviews (the UA trick is dead, verified 2026-06-14), so there is NO in-app webview. Instead the session JWT rides as a plain Bearer with **no cookie** (verified `credentials:"omit"` → 200), so this is the MiniMax/GLM stateless-key pattern: the user pastes `localStorage.access_token` once. **Confirmed live 2026-06-14:** token pulled from the logged-in browser, stored in keychain `Headroom-kimi-token`, `headroom doctor` → plan=Allegretto, 5h 58% / plan window 22%. ~30-day JWT (expiry 2026-07-14).

- **Usage endpoint:** `POST https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages` (Connect-RPC), request body `{"scope":["FEATURE_CODING"]}`, header `connect-protocol-version: 1`.
- **Auth:** `Authorization: Bearer <JWT>`. The JWT lives in **`localStorage.access_token`** (the `kimi-auth` cookie is httpOnly; cookie-only fetch → 401 `REASON_INVALID_AUTH_TOKEN`). The webview probe reads `localStorage.access_token` in-page and builds the header — the token never leaves the webview.
- **Response shape:** `{ usages:[ { scope:"FEATURE_CODING", detail:{ limit, used, remaining, resetTime }, limits:[ { window:{ duration, timeUnit }, detail:{ limit, used, remaining, resetTime } } ] } ], totalQuota:{ limit, used, remaining } }`.
  - Values are **out of `limit:"100"`, i.e. already percentages** (`used:"39"` = 39%).
  - `limits[0].window` = `{ duration:300, timeUnit:"TIME_UNIT_MINUTE" }` → the **5-hour window** (300 min = 18000s), drives the pace tick.
  - `usages[0].detail` = the **plan-period cap** (`resetTime` ~2 days out, no fixed window length → no even-burn line).
  - `resetTime` is ISO-8601 with microseconds + `Z`; the probe converts to epoch ms in-page (`new Date(...).getTime()`) so Swift reuses `dateFromEpochMillis`.
- **Plan name:** `POST .../kimi.gateway.membership.v2.MembershipService/GetSubscription` (body `{}`) → `subscription.goods.title` (e.g. "Allegretto").
- **Reset semantics:** rolling 5-hour sub-window + a longer plan-period cap, each its own `resetTime`. Matches Claude/Codex/MiniMax.
- **Auth model = needsLogin:** missing token or a 401 → `.needsLogin` ("paste a fresh token"). Keychain service `Headroom-kimi-token`, resolved via `LocalKey` (keychain → `KIMI_TOKEN`/`KIMI_ACCESS_TOKEN` env). Parse locked by `KimiCollectorTests`.
- **License note:** endpoint + Bearer + field names found by a DevTools spike on a logged-in session; no code copied. Token never printed to logs/chat or committed (pulled via the clipboard straight into the keychain).
- **Status:** BUILT + wired into `AppModel` + the headless CLI (stateless `URLSession` struct, like MiniMax). Default-enabled (paste-once, like MiniMax/GLM).

## MiniMax — `minimax`  ✅ BUILT 2026-06-13 (browser-free, local coding-plan key)

The GLM hypothesis held: MiniMax's usage endpoint accepts the coding-plan subscription key as a plain Bearer, so this is the Claude/Codex local-key pattern — no webview.

- **Credential:** the coding-plan key (`sk-cp-…`). Resolved via `LocalKey`: Headroom keychain `Headroom-minimax-key` (paste-once) → env `MINIMAX_API_KEY` → `~/.minimax-api-key`. (The app reads the key from an env var or its own keychain entry, never a password manager.)
- **Usage endpoint:** `GET https://api.minimax.io/v1/token_plan/remains` (also `www.minimax.io`; **not** `api.minimaxi.com` — `2049 invalid api key` for this key, region split). `Authorization: Bearer <key>`.
- **Response shape:** `{ model_remains: [ { model_name, start_time, end_time, current_interval_remaining_percent, weekly_start_time, weekly_end_time, current_weekly_remaining_percent, …counts } ], base_resp: { status_code, status_msg } }`.
  - One entry per model class: `general` (= text/coding plan, what we surface) and `video`. v1 shows only `general`.
  - `*_remaining_percent` is REMAINING → `percentUsed = 100 - it`. Times are **epoch milliseconds**; `end_time`/`weekly_end_time` are resets; window length = `(end - start)/1000` (5h interval = 18000s).
  - Errors come back HTTP 200 with `base_resp.status_code != 0`: `2049` = invalid key → `.needsLogin`; other non-zero → `.error`.
  - **Unlimited windows (`current_*_status: 3`):** a window with `status == 3` is uncapped, returning `remaining_percent: 100` forever. On the coding plan the **weekly is unlimited** (status 3), as is any unused model class (`video`). Headroom renders these as a real **`Metric.unlimited`** ("Unlimited", no bar) instead of a misleading 0%, and excludes them from gauges/tightest/notify/history. (Status 1 = the active limited 5h window. Other status values unobserved → treated as limited.) Confirmed against the live response + Justin 2026-06-14.
- **Reset semantics:** rolling 5-hour interval + weekly window, each its own start/end. Matches Claude/Codex. The weekly carries a reset boundary but, being uncapped, Headroom drops it (no depletion to reset).
- **Verified live:** `headroom doctor` → plan=Coding, 5h ~11% used, weekly "unlimited (no cap)". Parse locked by `MiniMaxCollectorTests`.
- **License note:** endpoint + Bearer + field names found by probing a real key against the documented endpoint; no code copied.
- **Status:** BUILT + wired into the CLI headless list and `AppModel`. Browser-free.

## Claude — `claude`  ✅ BUILT 2026-06-13 (browser-free, local OAuth token)

**Final approach: browser-free, no login.** An earlier spike found the claude.ai web endpoint is Cloudflare-gated (bare curl → 403), which pointed at a WKWebView path. But the real answer is cleaner: the Claude Code CLI's own local OAuth token reaches an official endpoint on `api.anthropic.com` (which does NOT Cloudflare-gate API clients). No web login, no cookie handling. (The JSONL plan was rejected — it only estimates against unpublished caps.)

- **Credential (read locally, file-first so it works for every user):**
  1. `~/.claude/.credentials.json` → `claudeAiOauth.accessToken` (`sk-ant-oat01…`). Cross-platform (Linux + many macOS setups), no Keychain prompt.
  2. macOS login Keychain, service `Claude Code-credentials`, same `claudeAiOauth` blob (the macOS default store; read via `/usr/bin/security -w`, prompts once for access).
  - The blob also carries `subscriptionType` (e.g. `max`) → used as the plan label. Token is read fresh each poll so the CLI owns refresh.
- **Usage endpoint:** `GET https://api.anthropic.com/api/oauth/usage`
  - **Auth: `Authorization: Bearer <oat token>`** only. No `anthropic-beta`, no `anthropic-version` needed (tested: Bearer-only returns 200).
- **Response shape:** `{ five_hour, seven_day, seven_day_opus, seven_day_sonnet, extra_usage, …many null siblings }`
  - Each window: `{ utilization (Double percent 0–100), resets_at }`. `resets_at` is ISO-8601 **with microseconds + offset** (`2026-06-14T02:59:59.160907+00:00`) → needs `.withFractionalSeconds` (plain ISO8601 returns nil).
  - `extra_usage`: `{ is_enabled, monthly_limit, used_credits, utilization, currency }` — the monthly extra-usage credit pool. Mapped only when `is_enabled`, as a `.usd` metric (used/limit credits + percent).
  - Sibling profile endpoint (not needed, but available): `GET /api/oauth/profile` → account + org + `rate_limit_tier` + `has_claude_max`.
- **Reset semantics:** rolling 5-hour (`five_hour`) + weekly (`seven_day`, plus per-model `seven_day_opus`/`seven_day_sonnet`), each its own `resets_at`. No reset on extra_usage.
- **Verified live:** `headroom usage` → plan=max, 5h 30% / weekly 15% / Sonnet 3% / Extra usage 69%, with reset dates. Parse locked by `ClaudeCollectorTests`.
- **License note:** endpoint + Bearer + field names discovered by probing a real local token; no code copied. Token never stored, logged, or committed.
- **Status:** BUILT + wired into the CLI host and app. Browser-free.

## Codex — `codex`  ✅ BUILT 2026-06-13 (browser-free, LIVE server endpoint)

**Final approach: live, like Claude.** An earlier build read the rate-limit snapshot from the CLI session rollout logs (`~/.codex/sessions/**/rollout-*.jsonl`). That was authoritative but **went stale** — the logs only update when the *CLI* runs, so working in the Codex **desktop app** left them days old (reset times in the past, numbers not matching the app). The fix: hit the same server endpoint the Codex app itself calls, using the local OAuth token.

- **Credential (universal store):** `~/.codex/auth.json` → `tokens.access_token` (a ChatGPT OAuth JWT) + `tokens.account_id`. Both the CLI and desktop app use this file, so it works for every user. Read fresh each poll (app/CLI owns refresh).
- **Usage endpoint:** `GET https://chatgpt.com/backend-api/wham/usage` ("wham" = Codex's backend codename).
  - **Auth: `Authorization: Bearer <jwt>`** only (tested: Bearer-only → 200). `chatgpt-account-id: <account_id>` is accepted and sent for robustness but not required. (Sibling `…/backend-api/codex/usage` returns 403 — use `wham`.)
- **Response shape:** `{ plan_type, rate_limit: { primary_window, secondary_window }, rate_limit_reset_credits: { available_count }, credits: {…} }`
  - `primary_window` ≈ 5-hour (`limit_window_seconds` 18000) → "5h window"; `secondary_window` ≈ weekly (604800) → "Weekly".
  - Each window: `{ used_percent (0–100), reset_at (epoch SECONDS), reset_after_seconds (relative fallback), limit_window_seconds }`.
  - `rate_limit_reset_credits.available_count` is the "N resets available" the app shows (not yet surfaced as a meter — candidate for the UI pass).
- **Reset semantics:** `reset_at` epoch **seconds**. `used_percent` already a percent. Two rolling windows, independent resets.
- **Verified live:** matches the Codex app exactly — `plan=plus`, 5h 2% (resets ~2:16 AM ET tonight), Weekly 0% (resets Jun 20 ET). Decode locked by `CodexCollectorTests` (real response + auth.json parse).
- **Status mapping:** 200 → `.ok`. 401/403 (token expired) → `.stale` (app/CLI will refresh). No `auth.json` → `.needsLogin`.
- **Status:** BUILT + wired into the CLI host and app. Browser-free + live.
- **Token history backfill (2026-06-14):** the *current usage* comes from the live endpoint above, but the rollout logs we abandoned for usage are perfect for **token history**. `~/.codex/sessions/**/rollout-*.jsonl` (+ `archived_sessions`) carry `event_msg` lines with `payload.type == "token_count"` and `payload.info.last_token_usage.total_tokens` — the **per-turn delta** (verified: summing it equals the session's final `total_token_usage.total_tokens`, so no double-count). `UsageHistory.codexTokenSeries` sums these per local day (same pattern as `claudeTokenSeries`); parse locked by `CodexTokenParse` tests. History window shows a Claude/Codex token picker, both warm-cached.

## Gemini — `gemini`  ❌ REMOVED 2026-06-14 (no comparable headroom meter)

DevTools spike on a logged-in AI Studio session (2026-06-14) confirmed there is **no subscription-headroom meter to show**, unlike every other provider:
- AI Studio's RPC (`alkalimakersuite-pa…/MakerSuiteService/*`) exposes `GetAiStudioBenefitTier` → just the tier integer (`[1]`), and `GetUserRestrictions` → caps, **not live consumption**. No "used X of Y" endpoint exists.
- Auth is Google `SAPISIDHASH` (signed from the SAPISID cookie + origin + timestamp), not a clean Bearer — heavier than every other provider.
- The real Gemini API quota (RPM/RPD/TPM) lives in **Google Cloud Console → Quotas**, project-scoped behind full OAuth, and only means anything for paid-API-with-billing-project users. Free-tier AI Studio just rate-limits with 429s.
- Decision (2026-06-14): **removed** — it's the "Google-painful" setup we don't want, and there's no gauge to render anyway. Collector + scaffold deleted.

## Grok — `grok`

- Deferred. Not a priority.

## Service status pages (live health, not usage)  ✅ CAPTURED 2026-06-14

Separate from usage: the public Atlassian Statuspage feeds power the Down/Degraded card pill
(`ProviderStatus` in HeadroomKit), so a flat meter during an outage reads as their problem.
- **Claude** → `https://status.claude.com/api/v2/status.json`. Note: `status.anthropic.com` **302-redirects** here (verified live 2026-06-14); we point at the canonical host to skip the hop.
- **Codex (OpenAI)** → `https://status.openai.com/api/v2/status.json` (verified live: `indicator: none | All Systems Operational`).
- Shape: `{ "status": { "indicator": "none|minor|major|critical", "description": … } }` → operational/degraded/down. Any failure (offline, non-200, bad shape) → `.unknown` (no dot).
- MiniMax / GLM / Kimi publish no public status page → always `.unknown`. Fetch throttled to 5 min, off the usage-refresh path; toggle in Settings → General (default on, read-only).
