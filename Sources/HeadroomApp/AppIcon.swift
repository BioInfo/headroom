import SwiftUI
import AppKit
import HeadroomKit

/// The app icon: the shared Claudelicious chef-hat on a warm cream squircle — the family
/// mark, same hat as the menu-bar glyph. Rendered to PNG via `--render-icon <path> <px>`,
/// which the build script turns into AppIcon.icns. Our own vector → MIT stays clean.
struct AppIconView: View {
    var body: some View {
        let t = Theme.light
        ZStack {
            RoundedRectangle(cornerRadius: 224, style: .continuous)   // ~macOS squircle at 1024
                .fill(LinearGradient(colors: [Color(hex: t.card), Color(hex: t.bg2)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 224, style: .continuous)
                .strokeBorder(Color(hex: t.edge), lineWidth: 10)
            ChefHat()
                .fill(LinearGradient(colors: [Color(hex: t.clay), Color(hex: t.pressing)],
                                     startPoint: .top, endPoint: .bottom))
                .padding(220)
        }
        .frame(width: 1024, height: 1024)
    }
}

enum AppIcon {
    @MainActor
    static func render(to path: String, px: Int) {
        let renderer = ImageRenderer(content: AppIconView())
        renderer.scale = CGFloat(px) / 1024.0
        guard let cg = renderer.cgImage else {
            FileHandle.standardError.write(Data("render-icon: failed\n".utf8)); exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: px, height: px)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("render-icon: PNG encode failed\n".utf8)); exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("icon written: \(path) (\(px)px)")
        exit(0)
    }
}
