import Foundation
import HeadroomKit

/// Mock data for the dev screenshot paths (`--snapshot` popover, `--open history --shoot`).
/// The actual rendering is done by `AppDelegate.renderPopover` / `renderAndShoot` through a
/// real NSHostingView + cacheDisplay — that path resolves SF Symbols, which ImageRenderer
/// cannot. This file is just the representative data those renders display.
enum Snapshot {
    /// Synthetic token history for the History screenshot (the live path reads ~/.claude logs).
    /// 120 days with a weekday-weighted, slightly random-looking ramp so the heatmap + trend
    /// show texture. Deterministic (no Date.now ban here — this is app code, not a workflow).
    static var mockTokens: [TokenDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<120).map { i in
            let day = cal.date(byAdding: .day, value: -i, to: today)!
            let wd = cal.component(.weekday, from: day)               // 1=Sun..7=Sat
            let weekdayWeight = (wd == 1 || wd == 7) ? 0.4 : 1.0      // quieter weekends
            let wobble = Double((i * 2654435761) % 1000) / 1000.0     // deterministic 0..1
            let base = 0.6 + 0.8 * wobble
            let tokens = Int(weekdayWeight * base * 3_000_000_000)
            return TokenDay(day: day, tokens: i % 9 == 0 ? 0 : tokens)  // some idle days
        }.reversed()
    }

    /// Mirrors the live captures in docs/PROVIDERS.md so the rendered look is realistic.
    /// Windows: 5h reset in 2h → 60% elapsed; weekly reset in 5d → ~29% elapsed, so the
    /// pace tick sits at 60% / 29%. Codex's 92% 5h fill lands ahead of it (the warning +
    /// burn-rate ETA), and with Codex hot the "use this next" banner points at MiniMax.
    /// MiniMax's weekly is the unlimited tier (status 3) so it renders "Unlimited".
    static var mock: [ProviderUsage] {
        let h5: TimeInterval = 5 * 3600, week: TimeInterval = 7 * 86400
        let in5h = Date().addingTimeInterval(2 * 3600)
        let inWeek = Date().addingTimeInterval(5 * 86400)
        return [
            ProviderUsage(
                provider: "claude", displayName: "Claude", plan: "Max",
                metrics: [
                    Metric(label: "5h window",  percentUsed: 33, unit: .percent, resetAt: in5h, windowDuration: h5),
                    Metric(label: "weekly",     percentUsed: 15, unit: .percent, resetAt: inWeek, windowDuration: week),
                    Metric(label: "Sonnet",     percentUsed: 3,  unit: .percent, resetAt: inWeek, windowDuration: week),
                ], status: .ok),
            ProviderUsage(
                provider: "codex", displayName: "Codex", plan: "Plus",
                metrics: [
                    Metric(label: "5h window", percentUsed: 92, unit: .percent, resetAt: in5h, windowDuration: h5),
                    Metric(label: "weekly",    percentUsed: 41, unit: .percent, resetAt: inWeek, windowDuration: week),
                ], status: .ok),
            ProviderUsage(
                provider: "minimax", displayName: "MiniMax", plan: "Coding",
                metrics: [
                    Metric(label: "5h window", percentUsed: 11, unit: .percent, resetAt: in5h, windowDuration: h5),
                    Metric(label: "weekly", unit: .percent, unlimited: true),
                ], status: .ok),
            ProviderUsage(
                provider: "zai", displayName: "GLM (z.ai)", plan: "Pro",
                metrics: [
                    Metric(label: "Prompt window", percentUsed: 0, unit: .percent, resetAt: inWeek, windowDuration: week),
                    Metric(label: "Token budget",  percentUsed: 68, unit: .percent, resetAt: in5h, windowDuration: h5),
                ], status: .ok),
            ProviderUsage(
                provider: "kimi", displayName: "Kimi", plan: "Allegretto",
                metrics: [
                    Metric(label: "5h window",   percentUsed: 58, unit: .percent, resetAt: in5h, windowDuration: h5),
                    Metric(label: "Plan window", percentUsed: 22, unit: .percent, resetAt: inWeek, windowDuration: week),
                ], status: .ok),
        ]
    }
}
