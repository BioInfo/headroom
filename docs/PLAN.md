# Headroom — Build Plan

## The product

A native macOS menu bar app that unifies the usage/limit meters of every AI coding subscription you pay for. One gauge cluster, remaining headroom per provider, reset countdowns. Claude, Codex, GLM (z.ai), Kimi, MiniMax.

## The gap it fills

Each provider has its own usage dashboard with its own limit model (Claude rolling windows, Kimi weekly quota, GLM/MiniMax windows, Codex 5h windows). Nothing unifies them. The existing trackers (Claude Usage Tracker, SessionWatcher, Tally, caut) each cover a subset, and none read the coding-plan dashboards for GLM/Kimi/MiniMax. Gateway spend (e.g. a LiteLLM proxy) is the wrong number: it is dollars-proxied, not "how much of my plan quota is left this window." Headroom reads the authoritative dashboards directly.

## Architecture

One SwiftPM package, three targets:

- **`HeadroomKit`** (library): schema, `Collector` protocol, all provider collectors. Headless and unit-testable. The 80% of the work lives here.
- **`headroom`** (CLI executable): `headroom usage --json`, `headroom doctor`. Runs and tests every collector without the UI. This is the engine.
- **`Headroom.app`** (SwiftUI `MenuBarExtra`): polls HeadroomKit on a timer, renders gauges and a dropdown. Pretty is nearly free with MenuBarExtra.

### The spine: one normalized schema

Everything collapses into this:

```
ProviderUsage {
  provider: String          // "claude", "zai", "kimi", ...
  account: String?          // email / org label
  plan: String?             // "Max", "Coding Plan", ...
  metrics: [Metric]
  status: Status            // ok | needsLogin | stale | error
  lastUpdated: Date
}

Metric {
  label: String             // "5h window", "weekly", "opus tier"
  used: Double
  limit: Double?            // nil when the provider does not expose a cap
  unit: Unit                // tokens | requests | usd | percent
  resetAt: Date?
  authoritative: Bool       // true = real meter, false = estimated from spend vs known cap
}
```

The `authoritative` flag is honesty in the UI: some gauges are real meters, some are best-effort estimates. Never present an estimate as a live meter.

### Collector protocol

```
protocol Collector {
  var id: String { get }
  func collect() async throws -> ProviderUsage
}
```

One implementation per provider. Add a provider = add one file. That is the "extend it for whatever we need" property.

## How collectors get the data

Two mechanisms.

**Web-dashboard providers (z.ai, Kimi, MiniMax).** These pages are SPAs. The number you see is rendered from an internal JSON API call the page makes to itself, authed by your logged-in session. The collector:
1. Holds a hidden `WKWebView` with a persistent data store, logged into the provider (in-app login, once).
2. Loads the usage origin and runs the page's own internal usage `fetch` via `evaluateJavaScript`.
3. The webview sends the session cookie automatically on the same-origin fetch (httpOnly cookies are sent even though JS cannot read them), so no token is extracted or stored.
4. Parses the returned JSON into `ProviderUsage`.

This is self-contained (no external Chrome), clean for open-source, and native (WKWebView is AppKit, so the whole app stays one Swift package).

**Claude / Codex (revised after spikes — see `docs/PROVIDERS.md`).** The original "no browser, read local JSONL" plan was half right:
- **Claude:** NOT browser-free. The local JSONL gives only a token *estimate* against unpublished plan caps. The authoritative 5h/weekly subscription % lives behind `claude.ai/api/organizations/{orgId}/usage`, which is **Cloudflare-gated** — only readable from inside a logged-in browser session. So Claude uses the same WKWebView session-replay pattern as z.ai (one-time in-app login).
- **Codex:** browser-free after all, but there is **no usage endpoint** (caut's own notes confirm the CLI exposes none). Codex writes the server-returned `rate_limits` snapshot into `~/.codex/sessions/**/rollout-*.jsonl`; the collector reads the newest one. Authoritative but only as fresh as the last Codex session.

## Providers and honest difficulty

| Provider | CLI name | Mechanism | Difficulty | Status |
|----------|----------|-----------|------------|--------|
| z.ai (GLM) | `zai` | WKWebView session replay of coding-plan usage API | Medium | spike first |
| Kimi | `kimi` | WKWebView session replay of code console API | Medium | after z.ai |
| MiniMax | `minimax` | WKWebView session replay | Medium | after Kimi |
| Claude | `claude` | WKWebView replay of `claude.ai/.../usage` (Cloudflare-gated; not browser-free) | Medium | ✅ built |
| Codex | `codex` | local OAuth token (`~/.codex/auth.json`) → live `chatgpt.com/backend-api/wham/usage` | Low | ✅ built (live) |
| ~~Gemini~~ | `gemini` | removed — AI Studio exposes no usage meter (see PROVIDERS.md) | — | removed |
| Grok | `grok` | deferred | — | not a priority |

### The honest cost

The web-dashboard endpoints are **unofficial**. There is no official coding-plan quota API, so these collectors carry a **maintenance tax**: when a provider reships its frontend, that collector breaks and needs a re-capture. This is inherent to any tool reading these pages (caut included). The build itself is hours per provider, not days. The discovery (find the one XHR per dashboard) is the real per-provider work, and it is concrete: open DevTools, watch the network panel, capture the endpoint and response shape.

## The spike process (per provider)

1. Open the provider's usage page in a logged-in browser via the chrome-devtools MCP.
2. Watch the network panel, find the XHR that returns the quota number.
3. Capture: endpoint URL, method, the auth mechanism (cookie / bearer), the response JSON shape, and how the reset window is expressed.
4. Record it in `docs/PROVIDERS.md`.
5. Write the Swift collector that replays it via WKWebView.

z.ai is the first spike. It proves the whole pattern (WKWebView in-page fetch → JSON → ProviderUsage) and de-risks the rest.

## License and open-source plan

- **Our own code, clean MIT.** Do not copy or derive from `caut` (rider infects derivatives). caut is a reference checker only.
- Dev canonical repo lives at `~/apps/headroom` with full history and a detached/absent public remote.
- Public release is a **clean orphan export** (scrub working-memory + any personal endpoints), re-scanned before and after push, then updated by fast-forward, per `~/.claude/rules/security.md`.

## Phasing

1. **Vertical slice:** z.ai collector (after spike) + a minimal `MenuBarExtra` that shows one real gauge end to end. Proves the whole stack.
2. **Core providers:** Claude (WKWebView, Cloudflare-gated) and Codex (local rollout logs). ✅ both built; Claude needs a one-time in-app login, Codex is browser-free.
3. **Web trio:** Kimi and MiniMax, repeating the z.ai capture pattern.
4. **Gemini:** evaluated and removed — AI Studio has no comparable usage meter (see `docs/PROVIDERS.md`).
5. **Polish + open-source:** gauges, reset countdowns, settings, login flows, signing/notarization, clean export.

Useful after slice 1. No point where it is broken-until-done.
