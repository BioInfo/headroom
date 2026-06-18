# Changelog

All notable changes to Headroom are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/BioInfo/headroom/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/BioInfo/headroom/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/BioInfo/headroom/releases/tag/v1.0.0
