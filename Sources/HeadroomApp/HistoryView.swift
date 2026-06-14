import SwiftUI
import Charts
import HeadroomKit

/// Usage history: Claude token throughput (from local logs) as headline totals, a trend
/// line, and a GitHub-style heatmap — plus per-provider utilization sparklines from
/// Headroom's own recorded readings. Token series is Claude-only for now (the one
/// provider with clean local token logs; others keep counts in sqlite — see ROADMAP).
struct HistoryView: View {
    let model: AppModel
    /// Snapshot/preview hook: when set, skip the async log read and render these.
    var preloaded: [TokenDay]? = nil
    @Environment(\.colorScheme) private var scheme
    @State private var days: [TokenDay] = []
    @State private var loading = true

    var body: some View {
        let skin = Skin(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(skin)
                if loading {
                    ProgressView("Reading local logs…").tint(skin.clay)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if days.isEmpty {
                    Text("No Claude token history found in ~/.claude logs yet.")
                        .foregroundStyle(skin.faint).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    summaryRow(skin)
                    trend(skin)
                    heatmap(skin)
                }
                sparklines(skin)
            }
            .padding(18)
        }
        .background(skin.bg)
        .task {
            if let preloaded { days = preloaded; loading = false; return }
            days = await UsageHistory.claudeTokenSeries(days: 182)
            loading = false
        }
    }

    private func header(_ skin: Skin) -> some View {
        HStack(spacing: 8) {
            ChefHat().fill(skin.clay).frame(width: 20, height: 20)
            Text("Usage History").font(.title3.weight(.semibold)).foregroundStyle(skin.ink)
            Spacer()
            Text("Claude tokens · from local logs").font(.caption).foregroundStyle(skin.faint)
        }
    }

    // MARK: headline totals

    private func summaryRow(_ skin: Skin) -> some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let yTokens = days.first { cal.isDate($0.day, inSameDayAs: yesterday) }?.tokens ?? 0
        let last7 = sumSince(cal.date(byAdding: .day, value: -7, to: today)!)
        let last30 = sumSince(cal.date(byAdding: .day, value: -30, to: today)!)
        return HStack(spacing: 12) {
            stat("Yesterday", yTokens, skin)
            stat("Last 7 days", last7, skin)
            stat("Last 30 days", last30, skin)
        }
    }

    private func stat(_ label: String, _ tokens: Int, _ skin: Skin) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(fmtTokens(tokens)).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(skin.ink)
            Text(label).font(.caption).foregroundStyle(skin.faint)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))
    }

    // MARK: trend line (last 30 days, gaps filled)

    private func trend(_ skin: Skin) -> some View {
        let series = contiguous(days: 30)
        return VStack(alignment: .leading, spacing: 6) {
            Text("Usage Trend").font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink2)
            Chart(series, id: \.day) { d in
                AreaMark(x: .value("Day", d.day), y: .value("Tokens", d.tokens))
                    .foregroundStyle(.linearGradient(colors: [skin.ramp(.pressing).opacity(0.35), skin.ramp(.pressing).opacity(0.02)],
                                                     startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Day", d.day), y: .value("Tokens", d.tokens))
                    .foregroundStyle(skin.ramp(.pressing)).interpolationMethod(.monotone)
            }
            .chartYAxis { AxisMarks(format: TokenAxisFormat()) }
            .frame(height: 150)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))
    }

    // MARK: heatmap (weeks × weekday, in-brand warm intensity)

    private func heatmap(_ skin: Skin) -> some View {
        let cal = Calendar.current
        let byDay = Dictionary(uniqueKeysWithValues: days.map { (cal.startOfDay(for: $0.day), $0.tokens) })
        let peak = max(days.map(\.tokens).max() ?? 1, 1)
        // 26 weeks back, aligned to weeks (column = week, row = weekday 0=Sun..6=Sat).
        let weeks = 26
        let today = cal.startOfDay(for: Date())
        let todayWeekday = cal.component(.weekday, from: today) - 1   // 0...6
        let firstColStart = cal.date(byAdding: .day, value: -(weeks - 1) * 7 - todayWeekday, to: today)!
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Usage Heatmap").font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink2)
                Spacer()
                HStack(spacing: 3) {
                    Text("Less").font(.caption2).foregroundStyle(skin.faint)
                    ForEach(0..<5) { i in cell(intensity: Double(i)/4, skin: skin) }
                    Text("More").font(.caption2).foregroundStyle(skin.faint)
                }
            }
            HStack(alignment: .top, spacing: 3) {
                ForEach(0..<weeks, id: \.self) { w in
                    VStack(spacing: 3) {
                        ForEach(0..<7, id: \.self) { wd in
                            let date = cal.date(byAdding: .day, value: w*7 + wd, to: firstColStart)!
                            if date > today {
                                Color.clear.frame(width: 12, height: 12)
                            } else {
                                let t = byDay[cal.startOfDay(for: date)] ?? 0
                                cell(intensity: t == 0 ? 0 : Double(t) / Double(peak), skin: skin)
                                    .help("\(date.formatted(date: .abbreviated, time: .omitted)): \(fmtTokens(t))")
                            }
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))
    }

    private func cell(intensity f: Double, skin: Skin) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(heatColor(f, skin))
            .frame(width: 12, height: 12)
    }

    /// Empty → faint track; then cream→amber→terracotta→rust as it heats. In-brand, not GitHub green/red.
    private func heatColor(_ f: Double, _ skin: Skin) -> Color {
        switch f {
        case ..<0.001: skin.edge.opacity(0.5)
        case ..<0.25:  skin.ramp(.healthy).opacity(0.55)
        case ..<0.5:   skin.ramp(.warming)
        case ..<0.8:   skin.ramp(.pressing)
        default:       skin.ramp(.critical)
        }
    }

    // MARK: per-provider utilization sparklines (self-recorded)

    private func sparklines(_ skin: Skin) -> some View {
        let series = UsageHistory.shared.utilizationSeries(days: 30)
        let providers = Array(Set(series.flatMap { $0.fractions.keys })).sorted()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Recorded utilization (last 30 days)").font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink2)
            if providers.isEmpty {
                Text("Headroom records peak utilization per day as it runs — check back tomorrow.")
                    .font(.caption).foregroundStyle(skin.faint)
            } else {
                ForEach(providers, id: \.self) { id in
                    HStack(spacing: 10) {
                        Text(Prefs.displayName(id)).font(.caption).foregroundStyle(skin.ink2)
                            .frame(width: 90, alignment: .leading)
                        Chart(series, id: \.day) { d in
                            if let f = d.fractions[id] {
                                LineMark(x: .value("Day", d.day), y: .value("Used", f * 100))
                                    .foregroundStyle(skin.ramp(.warming)).interpolationMethod(.monotone)
                            }
                        }
                        .chartYScale(domain: 0...100).chartXAxis(.hidden).chartYAxis(.hidden)
                        .frame(height: 28)
                    }
                }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))
    }

    // MARK: helpers

    private func sumSince(_ start: Date) -> Int {
        days.filter { $0.day >= start }.reduce(0) { $0 + $1.tokens }
    }
    private func contiguous(days n: Int) -> [TokenDay] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let byDay = Dictionary(uniqueKeysWithValues: days.map { (cal.startOfDay(for: $0.day), $0.tokens) })
        return (0..<n).reversed().map { i -> TokenDay in
            let d = cal.date(byAdding: .day, value: -i, to: today)!
            return TokenDay(day: d, tokens: byDay[d] ?? 0)
        }
    }
}

/// 43_910_000 → "43.9M", 1_067_000_000 → "1.07B".
func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    switch d {
    case 1e12...:  return String(format: "%.2fT", d/1e12)
    case 1e9...:   return String(format: "%.2fB", d/1e9)
    case 1e6...:   return String(format: "%.1fM", d/1e6)
    case 1e3...:   return String(format: "%.0fK", d/1e3)
    default:       return "\(n)"
    }
}

/// Compact token labels on the chart Y axis.
struct TokenAxisFormat: FormatStyle {
    func format(_ value: Double) -> String { fmtTokens(Int(value)) }
}
