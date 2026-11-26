/// User-chosen provider display order.
///
/// The saved order is a preference, not a whitelist: ids it doesn't know (a provider added
/// in a later build, a newly captured Claude account) keep their default position relative
/// to their default-order predecessor, and saved ids that no longer exist are dropped.
public enum ProviderOrder {
    public static func apply(saved: [String], to ids: [String]) -> [String] {
        let present = Set(ids)
        var out = saved.filter { present.contains($0) }
        var seen = Set(out)
        for (i, id) in ids.enumerated() where !seen.contains(id) {
            // Slot a newcomer right after the nearest default-order predecessor already placed.
            let pred = ids[..<i].last { seen.contains($0) }
            let at = pred.flatMap { out.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            out.insert(id, at: at)
            seen.insert(id)
        }
        return out
    }

    /// Move `id` one slot up (`by: -1`) or down (`by: 1`) within `ids`. No-op at the ends.
    public static func move(_ id: String, by delta: Int, in ids: [String]) -> [String] {
        guard let i = ids.firstIndex(of: id) else { return ids }
        let j = i + delta
        guard ids.indices.contains(j) else { return ids }
        var out = ids
        out.swapAt(i, j)
        return out
    }
}
