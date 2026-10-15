import AppKit

extension NSPasteboard.PasteboardType {
    static let boomeSession = NSPasteboard.PasteboardType("com.boom.boome.live-session")
}

final class SessionDropIndicator: NSView {
    var background = BoomeChrome.fallbackBackground
    var line = false
    var caption = ""
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let color = BoomeChrome.text(selected: true, on: background)
        color.withAlphaComponent(0.75).setStroke()
        if line {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 2, y: bounds.midY))
            path.line(to: NSPoint(x: bounds.maxX - 2, y: bounds.midY))
            path.lineWidth = 2
            path.stroke()
        } else {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
            color.withAlphaComponent(0.09).setFill()
            path.fill()
            path.lineWidth = 1.5
            path.stroke()
            if !caption.isEmpty {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: color,
                    .backgroundColor: background,
                ]
                (caption as NSString).draw(at: NSPoint(x: 12, y: 10), withAttributes: attributes)
            }
        }
    }
}

/// A collapsed sidebar still accepts sessions over the terminal or other panels.
final class SessionDropView: NSView {
    var onCanDrop: ((String) -> Bool)?
    var onDrop: ((String) -> Bool)?
    private let indicator = SessionDropIndicator()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.boomeSession])
        indicator.isHidden = true
        addSubview(indicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func use(background: NSColor) { indicator.background = background }

    override func layout() {
        super.layout()
        indicator.frame = bounds.insetBy(dx: 6, dy: 6)
        if !indicator.isHidden { addSubview(indicator, positioned: .above, relativeTo: nil) }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { indicator.isHidden = true }
    override func draggingEnded(_ sender: NSDraggingInfo) { indicator.isHidden = true }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let token = sender.draggingPasteboard.string(forType: .boomeSession) else { return false }
        return onCanDrop?(token) == true
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        guard let token = sender.draggingPasteboard.string(forType: .boomeSession) else { return false }
        return onDrop?(token) == true
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let token = sender.draggingPasteboard.string(forType: .boomeSession), onCanDrop?(token) == true else {
            indicator.isHidden = true
            return []
        }
        indicator.caption = "Move sessions into this window"
        indicator.frame = bounds.insetBy(dx: 6, dy: 6)
        addSubview(indicator, positioned: .above, relativeTo: nil)
        indicator.isHidden = false
        indicator.needsDisplay = true
        return .move
    }
}
