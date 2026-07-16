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
case "spend":
    // Estimated local spend from provider session logs, priced at models.dev list rates.
    // An estimate of consumption value on a subscription, not a bill.
    let pricing = await ModelPricing.load()
    if pricing.isEmpty { print("note: pricing catalog unavailable (models.dev unreachable, no cache) — token counts only") }
    print("Estimated spend from local logs, last 30 days (list rates; subscriptions don't bill per token):")
    for (id, pricingProvider) in SpendUsage.providers {
        // Same per-file cache the app maintains — a warm run only parses changed files.
        let cache = SpendScanCache.load(provider: id)
        let (daily, updated) = id == "claude" ? await SpendUsage.claudeDaily(days: 30, cache: cache)
                                              : await SpendUsage.codexDaily(days: 30, cache: cache)
        updated.save(provider: id)
        let s = SpendUsage.summarize(daily, provider: pricingProvider, pricing: pricing)
        func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
        print("  \(id): today \(usd(s.today)) · 7d \(usd(s.last7)) · 30d \(usd(s.last30))")
        for m in s.byModel30.prefix(6) {
            let cost = m.usd.map { String(format: "$%.2f", $0) } ?? "unpriced"
            print("    \(m.model): \(cost)  (\(m.tokens.formatted()) tokens)")
        }
        if s.unpricedTokens30 > 0 {
            print("    (\(s.unpricedTokens30.formatted()) tokens not in the pricing catalog)")
        }
    }
case "claude-accounts", "accounts":
    // Headless multi-account management (same Keychain stashes the app uses).
    let sub = args.dropFirst().first ?? "status"
    func fail(_ m: String) { FileHandle.standardError.write(Data((m + "\n").utf8)); exit(1) }
    func report(_ r: Result<String, ClaudeAccounts.OpError>) {
        switch r { case .success(let m): print(m); case .failure(let e): fail(e.message) }
    }
    switch sub {
    case "list":    ClaudeAccounts.listLabels().forEach { print($0) }
    case "status":  print(ClaudeAccounts.statusReport())
    case "switch":
        guard let l = args.dropFirst(2).first else { fail("usage: headroom claude-accounts switch <label>"); break }
        report(ClaudeAccounts.switchTo(l))
    case "capture":
        guard let l = args.dropFirst(2).first else { fail("usage: headroom claude-accounts capture <label>"); break }
        report(ClaudeAccounts.capture(label: l))
    case "remove":
        guard let l = args.dropFirst(2).first else { fail("usage: headroom claude-accounts remove <label>"); break }
        report(ClaudeAccounts.remove(l))
    default:
        print("usage: headroom claude-accounts [list|status|switch <label>|capture <label>|remove <label>]")
    }
default:
    print("usage: headroom [usage|doctor|history [days]|spend|claude-accounts …]")
}
