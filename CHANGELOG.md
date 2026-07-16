# Changelog

All notable changes to Headroom are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.5.0] - 2026-07-15

### Fixed
- **Codex weekly window.** OpenAI moved the weekly cap into the primary rate-limit window (and stopped sending a secondary one), so Headroom was labeling the weekly as "5h window" and never showing the weekly. Windows are now labeled by their actual length (5h vs weekly), so the correct one shows.
- **Grok meter no longer goes stale between sessions.** The Grok token in `~/.grok/auth.json` lasts about six hours and only refreshes when you run the `grok` CLI, so the meter broke whenever you hadn't used Grok in a while. Headroom now refreshes the token itself via x.ai's OIDC endpoint and writes it back, so the weekly meter stays live.
- **GLM (z.ai) meter labels.** The 5-hour coding quota was mislabeled "Token budget" and the monthly web-search/reader quota "Prompt window." They now read "5h window" and "Web search," with the correct reset windows, decoded from z.ai's own window fields.
- **Claude card no longer blanks on a transient error.** A brief 401 during token rotation could clear the Claude card to "No meters reported"; it now keeps the last good reading (dimmed), the same way every other transient failure is handled, and persists it across relaunches.

## [1.4.0] - 2026-07-11

### Added
- Light / Dark appearance override (Settings → Appearance). Pin the popover and windows to Light or Dark, or follow the system as before. The menu-bar glyph looks the same either way.
- Snooze notifications for 1 or 4 hours (Settings → General). Mutes alert delivery without losing track: state keeps advancing underneath, so when the snooze ends you only hear about new changes, not a backlog of everything that happened while you were quiet. Survives a relaunch; resume any time.
- Adaptive refresh cadence (opt-in, Settings → General). Instead of a fixed interval, Headroom polls every 2–30 minutes based on how recently you opened it — fast while you're watching, coasting when you've stepped away — and backs off to 30 minutes on Low Power Mode or high heat. Opening the menu also freshens the readings on the spot. The fixed slider stays the default; nothing changes unless you turn adaptive on.
- Window-exhausted and window-back alerts (Settings → General → notifications, on by default). When a window hits its cap you get one "exhausted" alert — the one that means you're actually locked out — independent of the percentage thresholds, and a "back" alert when it resets. Distinct from the threshold and refill pings, and never double-fires on the same reset.

## [1.3.0] - 2026-07-11

### Added
- Grok provider. Tracks the SuperGrok / Grok Build weekly credit allowance, browser-free, by reading the Grok CLI's own local OIDC token (`~/.grok/auth.json`) and calling the billing endpoint the CLI itself polls. Shows weekly usage percent and reset countdown, like the other providers. Default on.

### Changed
- Claude usage now reads Anthropic's new `limits` response shape. The API moved the per-model weekly cap into a `limits` array (and stopped populating the old `seven_day_opus` / `seven_day_sonnet` fields), so Headroom now surfaces the per-model weekly meter (e.g. the Opus-tier weekly cap most likely to bind on Max) and stays correct through the migration. Falls back to the legacy flat fields when the array is absent.

## [1.2.1] - 2026-06-29

### Fixed
- Claude usage no longer breaks after a logout/login on macOS. The collector read `~/.claude/.credentials.json` first and would keep using an expired token from that file even when the login Keychain held a freshly refreshed one, leaving Claude stuck on a stale reading. Credential selection is now expiry-aware: the file token is used only while valid, otherwise the collector falls back to the Keychain and the later-expiring token wins.

## [1.2.0] - 2026-06-18

### Added
- Automatic updates via Sparkle. Signed, notarized builds check a GitHub-hosted appcast and install EdDSA-verified updates in the background; toggle in Settings → Updates.
- Developer ID signing + Apple notarization in `build-app.sh` (`NOTARIZE=1`), so downloaded builds open with no Gatekeeper warning. Builds without a Developer ID identity fall back to ad-hoc signing as before.

## [1.1.0] - 2026-06-18

### Added
- Menu-bar glyph styles: hat, bar, and battery (battery drains to show remaining headroom, colored by usage tier).
- Live provider status dots for providers with a public status page (Claude, Codex), default on, read-only.
- First-run onboarding: pick subscriptions and menu-bar style.
- Meter pinning, peak-hours tracking, and a finer gauge in the popover.
- Support and in-app updates UI.
- Per-provider refresh cadence (local collectors standard, remote relaxed).
- Codex token-history backfill with a per-provider warm cache.
- Blended cross-provider capacity, reset timeline, and history export (JSON/CSV).
- Internationalization scaffold.

### Fixed
- Menu-bar label now composites into a single `NSImage` so the glyph renders reliably.
- Menu-bar glyph is seeded at launch so the icon shows before the popover is first opened.
- Popover snapshots render through a real `NSView` instead of `ImageRenderer` (SF Symbols now resolve).

## [1.0.0] - 2026-06-14

### Added
- Initial release. Menu-bar app showing remaining subscription quota across Claude, Codex, Gemini, GLM (z.ai), Kimi, and MiniMax.
- Per-provider collectors conforming to a shared `Collector` protocol, normalized into the `ProviderUsage` schema.
- Local-creds collectors (Claude, Codex) and web-dashboard collectors (z.ai, Kimi, MiniMax) via a hidden per-provider `WKWebView` session.
- `headroom` CLI (`usage --json`, `doctor`) and the `Headroom.app` SwiftUI `MenuBarExtra`.

[Unreleased]: https://github.com/BioInfo/headroom/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/BioInfo/headroom/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/BioInfo/headroom/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BioInfo/headroom/releases/tag/v1.0.0
