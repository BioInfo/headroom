import SwiftUI
import AppKit
import HeadroomKit

/// Renders the popover to a PNG with representative mock data, light and dark side by
/// side. Triggered by `--snapshot <path>`; never runs in the shipping menu-bar flow.
enum Snapshot {
    @MainActor
    static func run(to path: String) {
        let model = AppModel()
        model.usages = mock
        model.lastRefresh = Date()

        let view = VStack(spacing: 16) {
            iconStrip
            HStack(alignment: .top, spacing: 16) {
                MenuContent(model: model).environment(\.colorScheme, .light)
                MenuContent(model: model).environment(\.colorScheme, .dark)
            }
        }
        .padding(16)
        .background(Color(white: 0.5))

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("snapshot: render failed\n".utf8))
            exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot: PNG encode failed\n".utf8))
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot written: \(path)")
        exit(0)
    }

    /// The menu-bar mark at a range of fills, on a light and a dark menu-bar pill, so a
    /// snapshot shows how the chef-hat gauge fills and warms across the ramp.
    @ViewBuilder
    static var iconStrip: some View {
        let fills: [Double] = [0.08, 0.45, 0.78, 0.92, 1.15]
        HStack(spacing: 18) {
            ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
                HStack(spacing: 10) {
                    ForEach(fills, id: \.self) { f in
                        HStack(spacing: 3) {
                            ChefHatGauge(fraction: f,
                                         tint: Color(hex: Theme.light.ramp(fraction: f)))
                                .frame(width: 17, height: 17)
                            Text("\(Int((min(f,1) * 100).rounded()))%")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(Color(hex: Theme.light.ramp(fraction: f)))
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.93),
                            in: Capsule())
            }
        }
    }

    /// Synthetic token history for the snapshot (the live path reads ~/.claude logs).
    /// 120 days with a weekday-weighted, slightly random-looking ramp so the heatmap +
    /// trend show texture. No Date.now ban here — this is app code, not a workflow script.
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
