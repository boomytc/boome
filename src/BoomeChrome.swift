import AppKit

/// Colors and the app icon. The orange is sampled from the ghost in
/// `resources/AppIcon.png` so the sidebar and the icon stay one palette.
enum BoomeChrome {
    /// Ghost body, sRGB (241, 150, 67).
    static let accent = NSColor(srgbRed: 241.0 / 255.0, green: 150.0 / 255.0, blue: 67.0 / 255.0, alpha: 1)
    /// Dark brown that stays readable on the accent. White on this orange is too faint.
    static let ink = NSColor(srgbRed: 62.0 / 255.0, green: 42.0 / 255.0, blue: 28.0 / 255.0, alpha: 1)

    static func sidebarFill(for appearance: NSAppearance) -> NSColor {
        if dark(appearance) {
            return NSColor(srgbRed: 44.0 / 255.0, green: 40.0 / 255.0, blue: 38.0 / 255.0, alpha: 1)
        }
        return NSColor(srgbRed: 243.0 / 255.0, green: 230.0 / 255.0, blue: 204.0 / 255.0, alpha: 1)
    }

    static func quietFill(for appearance: NSAppearance) -> NSColor {
        if dark(appearance) {
            return NSColor(white: 1, alpha: 0.08)
        }
        return NSColor(white: 1, alpha: 0.72)
    }

    static func text(selected: Bool, appearance: NSAppearance) -> NSColor {
        if selected || !dark(appearance) {
            return ink
        }
        return NSColor(srgbRed: 0.96, green: 0.94, blue: 0.91, alpha: 1)
    }

    static func icon(pointSize: CGFloat) -> NSImage {
        let image = (baseIcon.copy() as? NSImage) ?? baseIcon
        image.size = NSSize(width: pointSize, height: pointSize)
        image.isTemplate = false
        return image
    }

    static func installApplicationIcon() {
        NSApp.applicationIconImage = baseIcon
    }

    private static let baseIcon: NSImage = {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(size: NSSize(width: 32, height: 32))
    }()

    private static func dark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}
