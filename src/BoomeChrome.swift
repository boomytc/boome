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

    /// Selected row. Same family as the terminal background, a step above hover.
    static func selectionFill(on background: NSColor) -> NSColor {
        isDark(background) ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.08)
    }

    /// One fill scale for every sidebar row. Rest is clear.
    static func rowFill(_ role: RowRole, on background: NSColor) -> NSColor {
        switch role {
        case .rest:
            return .clear
        case .hover:
            return quietFill(on: background)
        case .selected:
            return selectionFill(on: background)
        }
    }

    /// The New Tab control has no resting fill. Hover uses the row hover.
    static func newTabFill(hovered: Bool, on background: NSColor) -> NSColor {
        hovered ? quietFill(on: background) : .clear
    }

    enum RowRole {
        case rest
        case hover
        case selected
    }

    static func hairline(on background: NSColor) -> NSColor {
        isDark(background) ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.1)
    }

    static func text(selected: Bool, on background: NSColor) -> NSColor {
        if isDark(background) {
            return NSColor(srgbRed: 0.93, green: 0.91, blue: 0.88, alpha: selected ? 1 : 0.78)
        }
        return ink
    }

    static func secondaryText(selected: Bool, on background: NSColor) -> NSColor {
        if isDark(background) {
            return NSColor(srgbRed: 0.72, green: 0.70, blue: 0.66, alpha: selected ? 1 : 0.85)
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

/// Presentation only: dragging the session name should move the window,
/// not open a second tab picker or start text selection.
final class SessionTitleLabel: NSTextField {
    override var mouseDownCanMoveWindow: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBezeled = false
        isBordered = false
        drawsBackground = false
        alignment = .left
        lineBreakMode = .byTruncatingTail
        maximumNumberOfLines = 1
        font = .systemFont(ofSize: 13, weight: .medium)
        setAccessibilityRole(.staticText)
        setAccessibilityIdentifier("CurrentSessionTitle")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func show(_ title: String) {
        stringValue = title
        toolTip = title
        setAccessibilityLabel(title)
    }
}
