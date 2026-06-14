import Foundation

/// Serialize Headroom's local usage history to CSV or JSON — your data, exportable, no
/// cloud. Two layers come together: the self-recorded per-provider utilization and the
/// Claude token series. Pure + testable; the app writes the result to a file.
public enum HistoryExport {
    private static let dayKey: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current
        return f
    }()

    /// Long-form CSV — one row per (date, provider, metric, value). Utilization rows carry
    /// the day's peak fraction (0…1); token rows carry Claude's daily token total. One
    /// shape that opens cleanly in any spreadsheet.
    public static func csv(utilization: [DayUtilization], tokens: [TokenDay]) -> String {
        var rows = ["date,provider,metric,value"]
        for d in utilization.sorted(by: { $0.day < $1.day }) {
            let date = dayKey.string(from: d.day)
            for (provider, frac) in d.fractions.sorted(by: { $0.key < $1.key }) {
                rows.append("\(date),\(provider),utilization,\(String(format: "%.4f", frac))")
            }
        }
        for t in tokens.sorted(by: { $0.day < $1.day }) {
            rows.append("\(dayKey.string(from: t.day)),claude,tokens,\(t.tokens)")
        }
        return rows.joined(separator: "\n") + "\n"
    }

    private struct Payload: Codable {
        struct UtilDay: Codable { let date: String; let fractions: [String: Double] }
        struct TokDay: Codable { let date: String; let tokens: Int }
        let exported: String
        let utilization: [UtilDay]
        let tokens: [TokDay]
    }

    /// Pretty JSON: `{ exported, utilization: [{date, fractions}], tokens: [{date, tokens}] }`.
    public static func json(utilization: [DayUtilization], tokens: [TokenDay],
                            now: Date = Date()) -> String {
        let iso = ISO8601DateFormatter()
        let payload = Payload(
            exported: iso.string(from: now),
            utilization: utilization.sorted { $0.day < $1.day }
                .map { .init(date: dayKey.string(from: $0.day), fractions: $0.fractions) },
            tokens: tokens.sorted { $0.day < $1.day }
                .map { .init(date: dayKey.string(from: $0.day), tokens: $0.tokens) }
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(payload),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
