import SwiftUI
import Charts
import AppKit
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
    /// Which provider's token series is shown (Claude / Codex — the ones with local logs).
    @State private var tokenProvider = "claude"

    var body: some View {
        let skin = Skin(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(skin)
                resetSection(skin)
                if loading {
                    ProgressView("Reading local logs…").tint(skin.clay)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if days.isEmpty {
                    Text("No \(Prefs.displayName(tokenProvider)) token history in its local logs yet.")
                        .foregroundStyle(skin.faint).frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    summaryRow(skin)
                    trend(skin)
                    heatmap(skin)
                }
                utilizationPanel(skin)
            }
            .padding(18)
        }
        .background(skin.bg)
        .task {
            if let preloaded { days = preloaded; loading = false; return }
            // Default to a provider that actually has data (Claude usually; Codex if not).
            let avail = availableProviders
            if !avail.contains(tokenProvider) { tokenProvider = avail.first ?? "claude" }
            await load(tokenProvider)
        }
        .onChange(of: tokenProvider) { _, p in
            // Switch instantly from the warm cache (no spinner), then refresh in place.
            days = model.historyTokensByProvider[p] ?? []
            Task { await load(p) }
        }
    }

    /// Token providers with data in the warm cache (so the picker only offers real tabs).
    /// Falls back to Claude before the first warm completes.
    private var availableProviders: [String] {
        let withData = UsageHistory.tokenProviders.filter { !(model.historyTokensByProvider[$0]?.isEmpty ?? true) }
        return withData.isEmpty ? ["claude"] : withData
    }

    /// Render `provider`'s series: warm cache first (instant), then a fresh parse in place.
    private func load(_ provider: String) async {
        if let warm = model.historyTokensByProvider[provider] { days = warm; loading = false }
        let fresh = await UsageHistory.tokenSeries(for: provider, days: 182)
        guard tokenProvider == provider else { return }   // user switched mid-parse
        days = fresh
        loading = false
        model.historyTokensByProvider[provider] = fresh
    }

    private func header(_ skin: Skin) -> some View {
        let avail = availableProviders
        return HStack(spacing: 8) {
            ChefHat().fill(skin.clay).frame(width: 20, height: 20)
            Text("Usage History").font(.title3.weight(.semibold)).foregroundStyle(skin.ink)
            Spacer()
            if avail.count > 1 {
                Picker("", selection: $tokenProvider) {
                    ForEach(avail, id: \.self) { Text(Prefs.displayName($0)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            Text("\(Prefs.displayName(tokenProvider)) tokens · from local logs")
                .font(.caption).foregroundStyle(skin.faint)
            Menu {
                Button("Export CSV…") { export(.csv) }
                Button("Export JSON…") { export(.json) }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton).fixedSize().tint(skin.clay)
            .help("Export your local usage history")
        }
    }

    private enum ExportFormat { case csv, json }

    /// Write the local history (self-recorded utilization + Claude token series) to a file
    /// the user picks. No cloud, no upload — your data, exportable.
    private func export(_ format: ExportFormat) {
        let util = UsageHistory.shared.utilizationSeries(days: 365)
        let (content, ext) = switch format {
        case .csv:  (HistoryExport.csv(utilization: util, tokens: days), "csv")
        case .json: (HistoryExport.json(utilization: util, tokens: days), "json")
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "headroom-usage.\(ext)"
        panel.canCreateDirectories = true
        panel.title = "Export Usage History"
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: reset timeline ("what resets when", soonest first)

    /// Plan the day around the next refill: every capped window across providers, soonest
    /// first. Hidden when nothing is live (e.g. the snapshot harness has no usages).
    @ViewBuilder private func resetSection(_ skin: Skin) -> some View {
        let entries = model.resetTimeline
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(skin.clay)
                    Text("Resets").font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink2)
                    Spacer()
                    Text("soonest first").font(.caption2).foregroundStyle(skin.faint)
                }
                ForEach(entries) { e in
                    HStack(spacing: 9) {
                        Circle()
                            .fill(e.fractionUsed.map { skin.ramp($0) } ?? skin.edge)
                            .frame(width: 7, height: 7)
                        Text(e.displayName).font(.caption.weight(.medium)).foregroundStyle(skin.ink)
                        Text(e.label).font(.caption2).foregroundStyle(skin.faint)
                        if let f = e.fractionUsed {
                            Text("\(Int((f*100).rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(skin.ink2)
                        }
                        Spacer()
                        Text(e.resetAt.formatted(.relative(presentation: .named)))
                            .font(.caption.weight(.medium)).foregroundStyle(skin.ink2)
                        Text(e.resetAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption2.monospacedDigit()).foregroundStyle(skin.faint)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(e.displayName) \(e.label) resets \(e.resetAt.formatted(.relative(presentation: .named)))")
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(skin.card))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(skin.edge, lineWidth: 1))
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

    // MARK: cross-provider utilization (self-recorded peak % used per day)

    /// One point: a provider's recorded peak utilization on a given day, as a percent.
    private struct UtilPoint: Identifiable {
        let day: Date; let provider: String; let pct: Double
        var id: String { "\(provider)-\(day.timeIntervalSince1970)" }
    }

    /// All providers' utilization overlaid on one chart, with a real % axis, dated X axis,
    /// per-provider color, and a legend that names each provider's latest recorded value.
    /// This is the cross-provider read only a multi-provider tool gives — "who's been hot
    /// lately" — readable instead of five flat, axis-less sparklines.
    private func utilizationPanel(_ skin: Skin) -> some View {
        let series = UsageHistory.shared.utilizationSeries(days: 30)
        let providers = Array(Set(series.flatMap { $0.fractions.keys })).sorted()
        let points: [UtilPoint] = series.flatMap { d in
            d.fractions.map { UtilPoint(day: d.day, provider: $0.key, pct: $0.value * 100) }
        }
        let names = providers.map { Prefs.displayName($0) }
        let colors = providers.map { ProviderInfo.tierColor($0, skin) }
        func latest(_ id: String) -> Double? {
            series.last(where: { $0.fractions[id] != nil })?.fractions[id]
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Utilization — % used per day").font(.subheadline.weight(.semibold)).foregroundStyle(skin.ink2)
            if points.isEmpty {
                Text("Headroom records each provider's peak utilization per day as it runs. Check back tomorrow.")
                    .font(.caption).foregroundStyle(skin.faint)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Day", p.day), y: .value("Used", p.pct))
                        .foregroundStyle(by: .value("Provider", Prefs.displayName(p.provider)))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
                .chartForegroundStyleScale(domain: names, range: colors)
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0.0, 25, 50, 75, 100]) { v in
                        AxisGridLine().foregroundStyle(skin.edge.opacity(0.5))
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text("\(Int(d))%").font(.caption2).foregroundStyle(skin.faint)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisGridLine().foregroundStyle(skin.edge.opacity(0.4))
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .chartLegend(.hidden)   // custom legend below carries the latest value
                .frame(height: 180)
                HStack(spacing: 16) {
                    ForEach(providers, id: \.self) { id in
                        HStack(spacing: 5) {
                            Circle().fill(ProviderInfo.tierColor(id, skin)).frame(width: 8, height: 8)
                            Text(Prefs.displayName(id)).font(.caption).foregroundStyle(skin.ink2)
                            if let l = latest(id) {
                                Text("\(Int((l*100).rounded()))%")
                                    .font(.caption.monospacedDigit().weight(.semibold)).foregroundStyle(skin.ink)
                            }
                        }
                    }
                    Spacer(minLength: 0)
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
