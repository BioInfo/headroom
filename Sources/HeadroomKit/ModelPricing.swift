import Foundation

/// USD per **1M tokens** for one model, from models.dev. Missing components price as 0
/// (e.g. models with no cache tiers).
public struct ModelPrice: Equatable, Sendable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double
    public init(input: Double = 0, output: Double = 0, cacheRead: Double = 0, cacheWrite: Double = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }
}

/// Model pricing metadata from https://models.dev/api.json — a keyless public catalog of
/// provider/model pricing (the same source CodexBar routes cost lookups through; we
/// reimplement the pipeline). Scoped provider → model so two providers sharing a model id
/// can't cross-price. Cached on disk for 24h; a failed refresh keeps serving the last
/// valid table, so spend readouts degrade to stale rather than empty.
public enum ModelPricing {
    public typealias Table = [String: [String: ModelPrice]]   // provider id → model id → price

    /// Parse the models.dev payload: `{ "<provider>": { "models": { "<id>": { "cost": {…} } } } }`.
    /// Entries without a `cost` object are skipped (free/local models price as absent).
    public static func parse(_ data: Data) -> Table {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var table: Table = [:]
        for (provider, v) in root {
            guard let p = v as? [String: Any], let models = p["models"] as? [String: Any] else { continue }
            var out: [String: ModelPrice] = [:]
            for (id, mv) in models {
                guard let m = mv as? [String: Any], let cost = m["cost"] as? [String: Any] else { continue }
                func f(_ key: String) -> Double {
                    (cost[key] as? Double) ?? (cost[key] as? Int).map(Double.init) ?? 0
                }
                out[id] = ModelPrice(input: f("input"), output: f("output"),
                                     cacheRead: f("cache_read"), cacheWrite: f("cache_write"))
            }
            if !out.isEmpty { table[provider] = out }
        }
        return table
    }

    /// Price for a model under a provider. Exact id first, then a dated-id fallback: local
    /// logs carry ids like `claude-haiku-4-5-20251001` while the catalog may list the
    /// undated `claude-haiku-4-5` (and vice versa).
    public static func price(provider: String, model: String, in table: Table) -> ModelPrice? {
        guard let models = table[provider] else { return nil }
        if let hit = models[model] { return hit }
        // strip a trailing -YYYYMMDD date stamp
        if let r = model.range(of: #"-\d{8}$"#, options: .regularExpression) {
            let undated = String(model[..<r.lowerBound])
            if let hit = models[undated] { return hit }
        }
        // or the catalog may carry only the dated form
        if let dated = models.keys.first(where: { $0.hasPrefix(model + "-") &&
            $0.dropFirst(model.count + 1).allSatisfy(\.isNumber) }) {
            return models[dated]
        }
        return nil
    }

    // MARK: - cached fetch

    static let sourceURL = URL(string: "https://models.dev/api.json")!
    static let cacheTTL: TimeInterval = 24 * 3600

    nonisolated static var cacheURL: URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Headroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model-pricing.json")
    }

    /// The pricing table: fresh cache if young enough, else refetch (keeping the old cache
    /// when the network fails). Never throws — an empty table just means "unpriced".
    public static func load(session: URLSession = .shared, now: Date = Date()) async -> Table {
        let fm = FileManager.default
        let cache = cacheURL
        let age = (try? fm.attributesOfItem(atPath: cache.path)[.modificationDate] as? Date)
            .map { now.timeIntervalSince($0) }
        if let age, age < cacheTTL, let data = try? Data(contentsOf: cache) {
            let t = parse(data)
            if !t.isEmpty { return t }
        }
        var req = URLRequest(url: sourceURL)
        req.timeoutInterval = 15
        if let (data, resp) = try? await session.data(for: req),
           (resp as? HTTPURLResponse)?.statusCode == 200 {
            let t = parse(data)
            if !t.isEmpty {
                try? data.write(to: cache, options: .atomic)
                return t
            }
        }
        // network failed → last valid cache, however old
        if let data = try? Data(contentsOf: cache) { return parse(data) }
        return [:]
    }
}
