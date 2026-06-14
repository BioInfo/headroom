import Foundation

/// Usage severity tier driving the warm gauge ramp. Pure domain logic so the
/// thresholds are one place and unit-testable. The app layer maps a tier to a color.
public enum UsageTier: String, Sendable, CaseIterable {
    case healthy   // <70% used
    case warming   // 70–85%
    case pressing  // 85–95%
    case critical  // 95–100%
    case runaway   // >100% (over-cap / extra usage)

    /// Map a fraction-used to a tier. Values above 1.0 (over-cap) land in `runaway`.
    public init(fraction: Double) {
        switch fraction {
        case ..<0.70: self = .healthy
        case ..<0.85: self = .warming
        case ..<0.95: self = .pressing
        case ...1.00: self = .critical
        default:      self = .runaway
        }
    }
}

/// The Claudelicious cookbook palette + the warm gauge ramp Headroom adds. One source
/// of truth. Colors are hex strings (`RRGGBB`); the app bridges them to SwiftUI `Color`.
/// Keeping it as plain data is what lets HeadroomKit stay headless and testable.
public struct Theme: Sendable {
    // Chrome — from Claudelicious's cream→clay→charcoal ladder.
    public let bg: String      // cream ground (popover)
    public let card: String    // raised provider cards
    public let bg2: String     // warmer cream / section fills
    public let edge: String    // tan card edges, hairlines
    public let clay: String    // structural fills, dividers, plan chips
    public let ink: String     // primary text
    public let ink2: String    // secondary text (linework ink)
    public let faint: String   // tertiary / captions

    // Gauge ramp — the warm traffic-light Claudelicious lacks, still at home on cream.
    public let healthy: String   // olive green
    public let warming: String   // clay-amber
    public let pressing: String  // terracotta
    public let critical: String  // rust
    public let runaway: String   // aubergine

    public func ramp(_ tier: UsageTier) -> String {
        switch tier {
        case .healthy:  healthy
        case .warming:  warming
        case .pressing: pressing
        case .critical: critical
        case .runaway:  runaway
        }
    }

    public func ramp(fraction: Double) -> String { ramp(UsageTier(fraction: fraction)) }

    public static let light = Theme(
        bg: "F3EAD5", card: "FFFDF8", bg2: "F5E7C9", edge: "E2CDB1",
        clay: "B79476", ink: "4A463E", ink2: "6B6B64", faint: "968A73",
        healthy: "6E8B3D", warming: "CC8A3C", pressing: "C2622D",
        critical: "9E3B2E", runaway: "6D3B5E"
    )

    /// Warm espresso ground + cream text, ramp lifted ~8% lightness — keeps the
    /// cookbook warmth at night instead of cold black.
    public static let dark = Theme(
        bg: "2A2520", card: "352F2A", bg2: "31291F", edge: "4A4036",
        clay: "8C7257", ink: "F0E7D3", ink2: "C9BCA4", faint: "9A8E78",
        healthy: "8AA64F", warming: "E0A24F", pressing: "D5743A",
        critical: "BC5040", runaway: "8C5476"
    )
}
