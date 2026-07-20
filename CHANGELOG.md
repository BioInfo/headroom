# Changelog

All notable changes to Headroom are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.4] - 2026-07-20

### Fixed
- **The login-keychain password prompt kept coming back.** The Claude meter reads Claude Code's own credential from the macOS Keychain. Two apps sharing one Keychain item is fragile: macOS rewrites that item's access permission (its *partition list*) to whichever program last touched it, so Headroom's silent access would get revoked. When that happened, Headroom fell back to a command that pops the "enter your login keychain password" dialog — and approving it ("Always Allow") flipped the permission the other way and locked **Claude Code** out of its own token, so then Claude Code prompted. That back-and-forth is why the prompt returned no matter how many times you fixed it.

  Headroom now **never shows that dialog for Claude Code's credential.** If it cannot read the token silently, the Claude card simply keeps showing its last reading until access comes back on its own — no prompt, so nothing gets locked out and the loop ends. Saved-account cards are unaffected (Headroom owns those items). Reading a saved account can still ask once, as before.

  If you are already stuck in the loop, run the partition-list command from the 1.6.2 notes one last time; after upgrading to 1.6.4 it will hold.

## [1.6.3] - 2026-07-17

### Fixed
- **A saved account's card said "couldn't read usage" after a few hours.** A saved account is a frozen copy of a credential, and its access token expires within hours — so every card except the live one decayed into an error and stayed there. Headroom now renews a saved account's token in the background before reading it, so those cards keep working.

  This is deliberately *not* the operation removed in 1.6.2. Renewing a saved account writes only Headroom's own Keychain item, never Claude Code's, so it cannot evict Claude Code from that item's partition list and it never races Claude Code for a credential Claude Code is rotating — a saved account is one the CLI is not signed into, so nothing else is touching it.

  If a saved account has genuinely been signed out, Headroom records that once and stops trying. A refresh token is single-use, so re-presenting a dead one on every refresh would look exactly like an attack; the card tells you to sign in again and re-save instead.

## [1.6.2] - 2026-07-17

### Removed
- **Switching Claude accounts.** It cannot be done safely and is gone. Switching had to write Claude Code's own Keychain item, and on macOS *any* write to another app's Keychain item silently rewrites that item's **partition list** to the writing program's identity, evicting the owner. After a switch, Claude Code had to ask for your login keychain password every time it read its own token — roughly every 20 minutes, indefinitely. Nothing in 1.6.0/1.6.1 hinted at this, because the trusted-application list (the gate everyone looks at) really is preserved by a write; the partition list is a second, independent gate, and that is the one a write destroys. It is also not repairable from inside the app: restoring a partition list is itself a privileged operation that demands your keychain password. So the honest fix is to stop writing, not to patch the write. **Change accounts with Claude Code's own `claude /login`.** Saved accounts, their cards, and the ACTIVE marker all still work — Headroom reads Claude Code's credentials and never writes them.

  If 1.6.0 or 1.6.1 already left you with repeating password prompts, this fixes it permanently (one password, once). It pins Claude Code's signing **team** (`Q6L2SF6YDW`) rather than a specific build, so Claude Code's auto-updates will not break it again. `83XUJJQQL9` is Headroom's own team, which is what lets the Claude meter keep reading without asking you:

  ```
  security set-generic-password-partition-list \
    -S "apple-tool:,teamid:Q6L2SF6YDW,teamid:83XUJJQQL9" \
    -s "Claude Code-credentials" -a "$USER"
  ```

  Note that `-S` **replaces** the partition list rather than adding to it. If another tool also reads your Claude credentials, it will have to ask for permission once more afterwards (it re-adds itself; nothing is lost). To see what is there first, run `security dump-keychain | grep -A2 "Claude Code-credentials"`, or just run the command above and re-approve anything that asks.

### Fixed
- **Headroom could pin a CPU core indefinitely.** The token-history scan had no cache and re-read every Claude and Codex session log inside a 182-day window on launch *and* on every refresh tick. On a heavy tree that is 12,508 files and 8.56 GB per pass — a single pass measured 4.5 minutes of CPU, far longer than the refresh interval itself, so it never caught up. History now uses the same per-file cache the Spend panel already had: the first pass parses everything, and later passes only re-read files that actually changed. Measured on the same logs: **271s cold, 0.85s warm.** The numbers it reports are unchanged.

## [1.6.1] - 2026-07-16

### Fixed
- **Switching Claude accounts could sign the account out.** Claude Code rotates its OAuth refresh token, so a saved account's stored credential goes stale on its own. Headroom wrote that stale credential straight into the live slot, and replaying a rotated refresh token gets the whole token family revoked — which signed you out of Claude Code rather than simply failing. Headroom now refreshes a saved account **before** it goes live, saves the rotated token first, and writes nothing at all unless a valid credential is in hand. If an account really has been signed out, you get a clear message instead of a broken session.
- **Switching could file an account under the wrong name.** The credential itself carries no identity, so Headroom trusted a pointer file to know which account was live — and `/login` rewrites the live slot without touching that pointer. Once it drifted, saving the outgoing account could overwrite a *different* account's saved credential. Headroom now confirms identity against the account's own profile (`account.uuid`, which survives token rotation) and refuses to switch rather than guess. Saved accounts now show the real account email, so you can see which is which.
- **Three Keychain password prompts per switch, every time.** macOS scopes Keychain trust to the requesting program, and Headroom was shelling out to `/usr/bin/security` for each write — a new program each time, so it asked again and "Always Allow" never stuck. Writes now happen inside Headroom itself: approve once, and it stays approved. Your token also no longer passes through a command line.
- **The same account could appear as two cards** — one marked ACTIVE, one offering to switch to itself, both showing identical numbers — if the display refreshed mid-switch.

### Added
- `headroom claude-accounts reconcile` — re-links saved accounts to their verified identity, and repairs a drifted pointer. Read-only.

## [1.6.0] - 2026-07-16

### Added
- **Spend panel in Usage History.** What your local session logs are worth at list rates: per-provider Today / 7d / 30d totals plus a per-model breakdown, labeled "local logs at list rates · not a bill." A per-file scan cache means the first pass parses everything and every later refresh takes under a second, even on months of heavy logs.
- **Burn-down chart in Usage History.** How the current session and weekly windows actually burned, drawn against the straight even-burn line from window start to reset. Below the line is banked reserve; above it is deficit. Samples accrue automatically while Headroom runs (14-day retention, on your Mac).
- **Pace, in plain language.** Meter rows now say where you stand against even burn: "27% in reserve," "on pace," or "12% in deficit · runs out ~9:27 PM" (with a projected landing % when the run-out is more than a day away). Replaces the old "ahead of pace / lands ~%" phrasing.
- **Predictive pace alert (opt-in).** One notification when a meter crosses into deficit, meaning it will run out before the reset at the current rate, while there is still time to slow down. One per risk episode; re-arms only after you return to reserve or the window resets. Settings → General → notifications.
- **Popover Overview mode.** One dense line per provider (badge · tightest % · reset) instead of full cards, so the whole lineup fits at a glance when you track many providers or accounts. Toggle from the popover footer; click a row to open that provider's dashboard.
- **Menu-bar options:** a Monogram glyph style (the provider's letter badge, so the % is named), a "show remaining instead of used" flip (the % counts down and the hat/bar drain), and a "most-used provider" mode that auto-tracks whichever provider is hottest right now. Settings → Appearance.
- **Reset countdown when a meter runs out.** At 100% the menu bar shows the time until the window resets ("45m", "3h") in place of the percent, then reverts once it refills. The percent tells you nothing once you're capped; when it comes back is the number you act on. On by default; toggle in Settings → Appearance.
- **`headroom spend`.** Estimated consumption value from the provider's own local session logs (Claude and Codex), priced per model at models.dev list rates: today / 7-day / 30-day totals plus a per-model breakdown. It reads what your machine actually pushed and prices it at list, so you can see what your subscription delivered. An estimate, not a bill; unknown models are reported as unpriced rather than guessed. Uses the same scan cache as the app, so repeat runs are fast.
- **Multiple Claude accounts.** Track more than one Claude subscription at once, a gauge card per account, and switch which one the Claude Code CLI uses from inside Headroom. Add an account under a name (Settings → Providers → Claude accounts → "Add current Claude account"), switch from any account card or the accounts list, and remove ones you no longer need. To add a second account, log into it with `claude` in a terminal first (Claude has no in-app browser login), then capture it. Switching takes effect for new `claude` sessions. The same actions run headless: `headroom claude-accounts [list|status|switch <label>|capture <label>|remove <label>]`.

### Changed
- Card headers no longer cram when a Degraded/Down badge appears: chips never truncate mid-word, and the health badge collapses to a colored triangle (word in the tooltip) when space is tight.
- Keychain reads never prompt. Usage polling and account listing use in-process, non-interactive reads (with a timeout-guarded fallback to the classic path), so a background refresh can never pop the macOS authorization dialog or stall behind one. Only a user-initiated account switch can prompt, once.
- Each account's credentials live in Headroom's own Keychain items, verified by read-back on every write. The token itself is never read into the app or logged. The first switch may ask macOS to authorize Keychain access; choose "Always Allow" and it won't ask again.

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
