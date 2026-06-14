import SwiftUI
import HeadroomKit

// MARK: - Hex → Color

extension Color {
    /// `RRGGBB` or `RRGGBBAA` hex (with or without leading `#`).
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r, g, b, a: Double
        if s.count == 8 {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8)  & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        } else {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8)  & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

// MARK: - Skin (SwiftUI bridge over HeadroomKit.Theme)

/// Resolves the right `Theme` for the current color scheme and exposes it as `Color`s.
/// Views build one per render: `let skin = Skin(scheme)`.
struct Skin {
    let theme: Theme
    init(_ scheme: ColorScheme) { theme = scheme == .dark ? .dark : .light }

    var bg: Color    { Color(hex: theme.bg) }
    var card: Color  { Color(hex: theme.card) }
    var bg2: Color   { Color(hex: theme.bg2) }
    var edge: Color  { Color(hex: theme.edge) }
    var clay: Color  { Color(hex: theme.clay) }
    var ink: Color   { Color(hex: theme.ink) }
    var ink2: Color  { Color(hex: theme.ink2) }
    var faint: Color { Color(hex: theme.faint) }

    func ramp(_ fraction: Double) -> Color { Color(hex: theme.ramp(fraction: fraction)) }
    func ramp(_ tier: UsageTier) -> Color  { Color(hex: theme.ramp(tier)) }
}

// MARK: - The shared Claudelicious chef-hat (vector, our own code)

/// A filled chef's-toque silhouette. The family mark — Headroom's app icon and
/// menu-bar glyph wear the same hat. Drawn in a unit box so it scales to any size and
/// tints to the current gauge tier. Overlapping subpaths union under nonzero fill.
struct ChefHat: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width, h = rect.height
        let x = rect.minX, y = rect.minY
        func puff(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> CGRect {
            let rx = r * w, ry = r * h
            return CGRect(x: x + cx*w - rx, y: y + cy*h - ry, width: rx*2, height: ry*2)
        }
        var p = Path()
        // Three crown puffs.
        p.addEllipse(in: puff(0.31, 0.40, 0.205))
        p.addEllipse(in: puff(0.69, 0.40, 0.205))
        p.addEllipse(in: puff(0.50, 0.30, 0.235))
        // Bridge the crown down into the band so the silhouette is solid.
        var bridge = Path()
        bridge.move(to:    CGPoint(x: x + 0.16*w, y: y + 0.50*h))
        bridge.addLine(to: CGPoint(x: x + 0.84*w, y: y + 0.50*h))
        bridge.addLine(to: CGPoint(x: x + 0.80*w, y: y + 0.66*h))
        bridge.addLine(to: CGPoint(x: x + 0.20*w, y: y + 0.66*h))
        bridge.closeSubpath()
        p.addPath(bridge)
        // The band.
        let band = CGRect(x: x + 0.21*w, y: y + 0.62*h, width: 0.58*w, height: 0.24*h)
        p.addRoundedRect(in: band, cornerSize: CGSize(width: 0.055*w, height: 0.06*h))
        return p
    }
}

/// The menu-bar mark: the chef-hat *is* the gauge. It fills bottom-up with the tier
/// color as quota is spent (brim first, then crown), so a glance reads both "Headroom"
/// and "how full / how hot." Outlined so the empty hat still reads at a healthy 10%.
struct ChefHatGauge: View {
    let fraction: Double   // 0...1 fill height
    let tint: Color        // tier color
    var body: some View {
        let f = min(max(fraction, 0), 1)
        ChefHat()
            .fill(tint.opacity(0.22))                 // faded hat = the track
            .overlay {
                GeometryReader { geo in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        tint.frame(height: geo.size.height * f)
                    }
                }
                .mask(ChefHat())                      // rising fill, clipped to the hat
            }
            .overlay(ChefHat().stroke(tint, lineWidth: 0.8))
    }
}

/// A slim horizontal bar that fills left→right with usage, tinted by tier. The flat,
/// minimal alternative to the hat. Fixed-size, no GeometryReader (so it never collapses
/// when measured in an ImageRenderer/VStack).
struct BarGauge: View {
    let fraction: Double
    let tint: Color
    private let w: CGFloat = 16, h: CGFloat = 9
    var body: some View {
        let f = min(max(fraction, 0), 1)
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint.opacity(0.22))
            RoundedRectangle(cornerRadius: 2, style: .continuous).fill(tint)
                .frame(width: max(1.5, w * f))
        }
        .frame(width: w, height: h)
    }
}

/// A battery that DRAINS as you spend: the fill shows charge LEFT (1 − usage), colored by
/// usage tier so a nearly-empty battery reads rust = "almost out." The most literal
/// "headroom" mark. A nub on the right sells the battery read at menu-bar size. Fixed-size.
struct BatteryGauge: View {
    let fraction: Double   // usage 0…1
    let tint: Color
    private let bodyW: CGFloat = 14, h: CGFloat = 9, inset: CGFloat = 1.5
    var body: some View {
        let remaining = 1 - min(max(fraction, 0), 1)
        let innerW = bodyW - inset * 2
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(tint.opacity(0.85), lineWidth: 1)
                RoundedRectangle(cornerRadius: 1.2, style: .continuous).fill(tint)
                    .frame(width: max(0, innerW * remaining), height: h - inset * 2)
                    .padding(.leading, inset)
            }
            .frame(width: bodyW, height: h)
            RoundedRectangle(cornerRadius: 0.5).fill(tint.opacity(0.85)).frame(width: 1.5, height: 4)
        }
        .frame(height: h)
    }
}
