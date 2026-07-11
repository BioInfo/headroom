import Foundation
import HeadroomKit

// Minimal engine CLI. Grows into `usage` / `doctor` as collectors land.
// The z.ai collector needs a WKWebView (app context), so the CLI currently
// exercises the schema + JSON encoding; live web collectors run from the app.

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "usage"

func emit(_ usages: [ProviderUsage]) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    if let data = try? enc.encode(usages), let s = String(data: data, encoding: .utf8) {
        print(s)
    }
}

/// Collectors that need no WKWebView run here: Claude + Codex read local creds/logs,
/// MiniMax uses a local key, Kimi uses a pasted token (Bearer, no cookie). z.ai's key path
/// would work headless too, but it keeps a webview fallback so it runs in Headroom.app.
let headless: [any Collector] = [ClaudeCollector(), CodexCollector(), MiniMaxCollector(), KimiCollector(), GrokCollector()]

func runHeadlessCollectors() async -> [ProviderUsage] {
    var out: [ProviderUsage] = []
    for c in headless {
        do { out.append(try await c.collect()) }
        catch { out.append(ProviderUsage(provider: c.id, displayName: c.displayName, status: .error)) }
    }
    return out
}

switch command {
case "doctor":
    print("headroom doctor")
    print("  schema: ProviderUsage / Metric / Unit / Status — ok")
    print("  collectors: claude + codex + minimax + kimi (local/paste), zai (app-context)")
    for s in await runHeadlessCollectors() {
        print("  \(s.provider): status=\(s.status.rawValue) plan=\(s.plan ?? "-") meters=\(s.metrics.count)")
        for m in s.metrics {
            if m.unlimited {
                print("    \(m.label): unlimited (no cap)")
            } else {
                let pct = m.percentUsed.map { "\(Int($0.rounded()))%" } ?? "-"
                print("    \(m.label): \(pct) used" + (m.resetAt.map { ", resets \($0)" } ?? ""))
            }
        }
    }
case "usage", "--json":
    emit(await runHeadlessCollectors())
case "history":
    let days = Int(args.dropFirst().first ?? "14") ?? 14
    let series = await UsageHistory.claudeTokenSeries(days: days)
    let fmt = DateFormatter(); fmt.dateFormat = "EEE yyyy-MM-dd"
    print("Claude token throughput, last \(days) days (from ~/.claude logs):")
    var total = 0
    for d in series { total += d.tokens
        print("  \(fmt.string(from: d.day)): \(d.tokens.formatted()) tokens") }
    print("  total: \(total.formatted()) over \(series.count) active days")
default:
    print("usage: headroom [usage|doctor|history [days]]")
}
