import AppKit

/// Colors and the app icon. The orange is sampled from the ghost in
/// `resources/AppIcon.png` so the sidebar and the icon stay one palette.
enum BoomeChrome {
    /// Ghost body, sRGB (241, 150, 67).
    static let accent = NSColor(srgbRed: 241.0 / 255.0, green: 150.0 / 255.0, blue: 67.0 / 255.0, alpha: 1)
    /// Dark brown that stays readable on the accent. White on this orange is too faint.
    static let ink = NSColor(srgbRed: 62.0 / 255.0, green: 42.0 / 255.0, blue: 28.0 / 255.0, alpha: 1)

    /// Ghostty's default background, used until the loaded config answers.
    static let fallbackBackground = NSColor(srgbRed: 40.0 / 255.0, green: 44.0 / 255.0, blue: 52.0 / 255.0, alpha: 1)

    static func isDark(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return true }
        func lin(_ channel: CGFloat) -> CGFloat {
            channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let luminance = 0.2126 * lin(rgb.redComponent) + 0.7152 * lin(rgb.greenComponent) + 0.0722 * lin(rgb.blueComponent)
        return luminance < 0.45
    }

    static func quietFill(on background: NSColor) -> NSColor {
        isDark(background) ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.06)
    }

    static func hairline(on background: NSColor) -> NSColor {
        isDark(background) ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)
    }

    static func text(selected: Bool, on background: NSColor) -> NSColor {
        if selected || !isDark(background) {
            return ink
        }
        return NSColor(srgbRed: 0.93, green: 0.91, blue: 0.88, alpha: 1)
    }

    /// Second line under a tab name. On the accent, full ink stays readable;
    /// a faded ink blends into the orange and drops below the primary.
    static func secondaryText(selected: Bool, on background: NSColor) -> NSColor {
        if selected { return ink }
        if isDark(background) {
            return NSColor(srgbRed: 0.72, green: 0.70, blue: 0.66, alpha: 1)
        }
        return NSColor(srgbRed: 0.38, green: 0.32, blue: 0.27, alpha: 1)
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

}
