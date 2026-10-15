import AppKit
import GhosttyKit
import UniformTypeIdentifiers

/// The only type that calls `ghostty_*`.
///
/// Ghostty's C API is the macOS embedding entry used by Ghostty.app. The
/// header of `src/main_c.zig` says it is not a stable general-purpose
/// embedding interface. Upgrade the `vendor/ghostty` submodule by changing
/// this file, not the rest of the shell.
final class GhosttyHost: NSObject {
    static let shared = GhosttyHost()

    enum Cycle {
        case previous
        case next
        case last
        case index(Int)
    }

    enum CursorStyle {
        case arrow
        case text
        case crosshair
        case pointingHand
        case openHand
        case closedHand
        case notAllowed
        case resizeHorizontal
        case resizeVertical
        case hidden

        var cursor: NSCursor {
            switch self {
            case .arrow, .hidden: NSCursor.arrow
            case .text: NSCursor.iBeam
            case .crosshair: NSCursor.crosshair
            case .pointingHand: NSCursor.pointingHand
            case .openHand: NSCursor.openHand
            case .closedHand: NSCursor.closedHand
            case .notAllowed: NSCursor.operationNotAllowed
            case .resizeHorizontal: NSCursor.resizeLeftRight
            case .resizeVertical: NSCursor.resizeUpDown
            }
        }
    }

    enum KeyAction {
        case press
        case `repeat`
        case release
    }

    struct KeyInput {
        var action: KeyAction
        var keyCode: UInt32
        var modifiers: NSEvent.ModifierFlags
        var translationModifiers: NSEvent.ModifierFlags
        var characters: String?
        var unshifted: String?
        var composing: Bool
    }

    final class Surface {
        fileprivate let raw: ghostty_surface_t
        let view: NSView
        fileprivate init(raw: ghostty_surface_t, view: NSView) {
            self.raw = raw
            self.view = view
        }
    }

    weak var delegate: GhosttyHostDelegate?

    private var app: ghostty_app_t?
    private var config: ghostty_config_t?
    private var surfaces: [ObjectIdentifier: Surface] = [:]
    private var byUserdata: [UnsafeMutableRawPointer: Surface] = [:]

    private override init() {
        super.init()
    }

    func start() {
        precondition(
            UInt32(GHOSTTY_ACTION_CLOSE_TAB.rawValue) == LibraryActionRoute.closeTab
                && UInt32(GHOSTTY_ACTION_CLOSE_WINDOW.rawValue) == LibraryActionRoute.closeWindow,
            "close action tags drifted from the pinned Ghostty header"
        )
        if app != nil { return }
        let code = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if code != GHOSTTY_SUCCESS {
            fputs("ghostty_init failed (\(code))\n", stderr)
            exit(1)
        }
        ghostty_cli_try_action()

        guard let config = ghostty_config_new() else {
            fputs("ghostty_config_new failed\n", stderr)
            exit(1)
        }
        self.config = config
        ghostty_config_load_default_files(config)
        ghostty_config_load_cli_args(config)
        ghostty_config_load_recursive_files(config)
        ghostty_config_finalize(config)
        logConfigDiagnostics(config)

        var runtime = ghostty_runtime_config_s()
        runtime.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtime.supports_selection_clipboard = true
        runtime.wakeup_cb = { GhosttyHost.wakeup($0) }
        runtime.action_cb = { app, target, action in
            GhosttyHost.action(app, target, action)
        }
        runtime.read_clipboard_cb = { userdata, location, state in
            GhosttyHost.readClipboard(userdata, location, state)
        }
        runtime.confirm_read_clipboard_cb = { userdata, string, state, request in
            GhosttyHost.confirmReadClipboard(userdata, string, state, request)
        }
        runtime.write_clipboard_cb = { userdata, location, content, length, confirm in
            GhosttyHost.writeClipboard(userdata, location, content, length, confirm)
        }
        runtime.close_surface_cb = { userdata, processAlive in
            GhosttyHost.closeSurface(userdata, processAlive)
        }

        guard let app = ghostty_app_new(&runtime, config) else {
            fputs("ghostty_app_new failed\n", stderr)
            exit(1)
        }
        self.app = app
        ghostty_app_set_focus(app, true)
        applySystemColorScheme()
    }

    func shutdown() {
        let open = Array(surfaces.values)
        for surface in open {
            destroy(surface)
        }
        if let app {
            ghostty_app_free(app)
            self.app = nil
        }
        if let config {
            ghostty_config_free(config)
            self.config = nil
        }
    }

    func makeSurface(view: NSView, workingDirectory: String?, contextTab: Bool) -> Surface? {
        guard let app else { return nil }
        var options = ghostty_surface_config_new()
        let userdata = Unmanaged.passUnretained(view).toOpaque()
        options.userdata = userdata
        options.platform_tag = GHOSTTY_PLATFORM_MACOS
        options.platform = ghostty_platform_u(
            macos: ghostty_platform_macos_s(nsview: userdata)
        )
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        options.scale_factor = scale
        options.font_size = 0
        options.context = contextTab ? GHOSTTY_SURFACE_CONTEXT_TAB : GHOSTTY_SURFACE_CONTEXT_WINDOW

        let created: ghostty_surface_t? = workingDirectory.withCString { directory in
            options.working_directory = directory
            return ghostty_surface_new(app, &options)
        }
        guard let raw = created else {
            fputs("ghostty_surface_new failed\n", stderr)
            return nil
        }
        let surface = Surface(raw: raw, view: view)
        surfaces[ObjectIdentifier(view)] = surface
        byUserdata[userdata] = surface
        syncGeometry(surface)
        ghostty_surface_set_focus(raw, true)
        ghostty_surface_set_occlusion(raw, true)
        return surface
    }

    /// Directory the library would give a new tab opened from this surface.
    /// Nil when shell integration has not reported one, or when Ghostty's
    /// `tab-inherit-working-directory` is off.
    func inheritedWorkingDirectory(from surface: Surface) -> String? {
        let config = ghostty_surface_inherited_config(surface.raw, GHOSTTY_SURFACE_CONTEXT_TAB)
        guard let pointer = config.working_directory else { return nil }
        let path = String(cString: pointer)
        return path.isEmpty ? nil : path
    }

    func destroy(_ surface: Surface) {
        let userdata = Unmanaged.passUnretained(surface.view).toOpaque()
        surfaces.removeValue(forKey: ObjectIdentifier(surface.view))
        byUserdata.removeValue(forKey: userdata)
        ghostty_surface_free(surface.raw)
    }

    func requestClose(_ surface: Surface) {
        ghostty_surface_request_close(surface.raw)
    }

    func focusApp(_ focused: Bool) {
        guard let app else { return }
        ghostty_app_set_focus(app, focused)
    }

    func setSurfaceFocus(_ surface: Surface, focused: Bool) {
        ghostty_surface_set_focus(surface.raw, focused)
    }

    /// `visible` is what the library's occlusion call expects.
    func setSurfaceVisible(_ surface: Surface, visible: Bool) {
        ghostty_surface_set_occlusion(surface.raw, visible)
    }

    func syncGeometry(_ surface: Surface) {
        let view = surface.view
        guard let window = view.window ?? view.superview?.window else {
            let bounds = view.bounds
            guard bounds.width >= 1, bounds.height >= 1 else { return }
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            ghostty_surface_set_content_scale(surface.raw, scale, scale)
            ghostty_surface_set_size(
                surface.raw,
                UInt32(bounds.width * scale),
                UInt32(bounds.height * scale)
            )
            return
        }
        if let screen = window.screen,
           let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface.raw, number.uint32Value)
        }
        let backing = view.convertToBacking(view.bounds)
        let width = view.bounds.width
        let height = view.bounds.height
        guard width >= 1, height >= 1, backing.width >= 1, backing.height >= 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer?.contentsScale = window.backingScaleFactor
        CATransaction.commit()
        ghostty_surface_set_content_scale(
            surface.raw,
            backing.width / width,
            backing.height / height
        )
        ghostty_surface_set_size(
            surface.raw,
            UInt32(backing.width.rounded()),
            UInt32(backing.height.rounded())
        )
    }

    /// Resolved `background` from the config libghostty already loaded.
    func terminalBackground() -> NSColor {
        guard let config else { return BoomeChrome.fallbackBackground }
        var color = ghostty_config_color_s()
        let key = "background"
        guard ghostty_config_get(config, &color, key, UInt(key.utf8.count)) else {
            return BoomeChrome.fallbackBackground
        }
        return NSColor(
            srgbRed: CGFloat(color.r) / 255,
            green: CGFloat(color.g) / 255,
            blue: CGFloat(color.b) / 255,
            alpha: 1
        )
    }

    func applySystemColorScheme() {
        guard let app else { return }
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ghostty_app_set_color_scheme(app, dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT)
        for surface in surfaces.values {
            ghostty_surface_set_color_scheme(
                surface.raw,
                dark ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
            )
        }
    }

    func translatedModifiers(for surface: Surface, flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        let translated = ghostty_surface_key_translation_mods(surface.raw, Self.mods(flags))
        var result = flags
        let pairs: [(NSEvent.ModifierFlags, UInt32)] = [
            (.shift, GHOSTTY_MODS_SHIFT.rawValue),
            (.control, GHOSTTY_MODS_CTRL.rawValue),
            (.option, GHOSTTY_MODS_ALT.rawValue),
            (.command, GHOSTTY_MODS_SUPER.rawValue),
        ]
        for (flag, bit) in pairs {
            if translated.rawValue & bit != 0 {
                result.insert(flag)
            } else {
                result.remove(flag)
            }
        }
        return result
    }

    func sendKey(_ surface: Surface, _ input: KeyInput) {
        var event = ghostty_input_key_s()
        switch input.action {
        case .press: event.action = GHOSTTY_ACTION_PRESS
        case .repeat: event.action = GHOSTTY_ACTION_REPEAT
        case .release: event.action = GHOSTTY_ACTION_RELEASE
        }
        event.keycode = input.keyCode
        event.mods = Self.mods(input.modifiers)
        event.consumed_mods = Self.mods(
            input.translationModifiers.subtracting([.control, .command])
        )
        event.composing = input.composing
        if let unshifted = input.unshifted?.unicodeScalars.first {
            event.unshifted_codepoint = unshifted.value
        }
        let text = input.characters
        if let text, let first = text.utf8.first, first >= 0x20 {
            text.withCString { pointer in
                event.text = pointer
                _ = ghostty_surface_key(surface.raw, event)
            }
        } else {
            _ = ghostty_surface_key(surface.raw, event)
        }
    }

    func sendPreedit(_ surface: Surface, _ text: String) {
        text.withCString { pointer in
            ghostty_surface_preedit(surface.raw, pointer, UInt(text.utf8.count))
        }
    }

    func sendMouseButton(
        _ surface: Surface,
        pressed: Bool,
        button: Int,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        let mapped: ghostty_input_mouse_button_e
        switch button {
        case 0: mapped = GHOSTTY_MOUSE_LEFT
        case 1: mapped = GHOSTTY_MOUSE_RIGHT
        case 2: mapped = GHOSTTY_MOUSE_MIDDLE
        case 3: mapped = GHOSTTY_MOUSE_FOUR
        case 4: mapped = GHOSTTY_MOUSE_FIVE
        default: mapped = GHOSTTY_MOUSE_UNKNOWN
        }
        return ghostty_surface_mouse_button(
            surface.raw,
            pressed ? GHOSTTY_MOUSE_PRESS : GHOSTTY_MOUSE_RELEASE,
            mapped,
            Self.mods(modifiers)
        )
    }

    func sendMousePosition(_ surface: Surface, x: Double, y: Double, modifiers: NSEvent.ModifierFlags) {
        ghostty_surface_mouse_pos(surface.raw, x, y, Self.mods(modifiers))
    }

    func sendScroll(_ surface: Surface, x: Double, y: Double, mods: Int32) {
        ghostty_surface_mouse_scroll(surface.raw, x, y, mods)
    }

    func performBinding(_ surface: Surface, _ action: String) -> Bool {
        action.withCString { pointer in
            ghostty_surface_binding_action(surface.raw, pointer, UInt(action.utf8.count))
        }
    }

    func imeRect(for surface: Surface) -> (x: Double, y: Double, width: Double, height: Double) {
        var x: Double = 0
        var y: Double = 0
        var width: Double = 0
        var height: Double = 0
        ghostty_surface_ime_point(surface.raw, &x, &y, &width, &height)
        return (x, y, width, height)
    }

    func cellSize(for surface: Surface) -> NSSize {
        let size = ghostty_surface_size(surface.raw)
        let scale = surface.view.window?.backingScaleFactor ?? 2
        return NSSize(
            width: Double(size.cell_width_px) / scale,
            height: Double(size.cell_height_px) / scale
        )
    }

    private func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    private func surface(for userdata: UnsafeMutableRawPointer?) -> Surface? {
        guard let userdata else { return nil }
        return byUserdata[userdata]
    }

    private static func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var bits: UInt32 = 0
        if flags.contains(.shift) { bits |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { bits |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { bits |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { bits |= GHOSTTY_MODS_SUPER.rawValue }
        if flags.contains(.capsLock) { bits |= GHOSTTY_MODS_CAPS.rawValue }
        let raw = flags.rawValue
        if raw & 0x4 != 0 { bits |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
        if raw & 0x2000 != 0 { bits |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
        if raw & 0x40 != 0 { bits |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
        if raw & 0x10 != 0 { bits |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
        return ghostty_input_mods_e(bits)
    }

    private func logConfigDiagnostics(_ config: ghostty_config_t) {
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return }
        fputs("Boome: Ghostty config reported \(count) diagnostic(s)\n", stderr)
        for index in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            if let message = diagnostic.message {
                fputs("  \(String(cString: message))\n", stderr)
            }
        }
    }

    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let host = Unmanaged<GhosttyHost>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async {
            host.tick()
        }
    }

    private static func action(
        _ app: ghostty_app_t?,
        _ target: ghostty_target_s,
        _ action: ghostty_action_s
    ) -> Bool {
        guard let app else { return false }
        let userdata = ghostty_app_userdata(app)
        guard let userdata else { return false }
        let host = Unmanaged<GhosttyHost>.fromOpaque(userdata).takeUnretainedValue()
        return host.handle(action, target: target)
    }

    private func handle(_ action: ghostty_action_s, target: ghostty_target_s) -> Bool {
        let surface = target.tag == GHOSTTY_TARGET_SURFACE ? target.target.surface.flatMap { raw in
            surfaces.values.first { $0.raw == raw }
        } : nil

        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            NSApp.terminate(nil)
            return true
        case GHOSTTY_ACTION_NEW_TAB, GHOSTTY_ACTION_NEW_WINDOW:
            delegate?.ghosttyHostOpenNewTab(self)
            return true
        case GHOSTTY_ACTION_CLOSE_TAB, GHOSTTY_ACTION_CLOSE_WINDOW:
            switch LibraryActionRoute.close(tag: UInt32(action.tag.rawValue)) {
            case .tab:
                delegate?.ghosttyHostCloseCurrentTab(self)
            case .window:
                delegate?.ghosttyHostCloseWindow(self)
            case nil:
                return false
            }
            return true
        case GHOSTTY_ACTION_GOTO_TAB:
            let raw = action.action.goto_tab.rawValue
            let cycle: Cycle
            switch raw {
            case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: cycle = .previous
            case GHOSTTY_GOTO_TAB_NEXT.rawValue: cycle = .next
            case GHOSTTY_GOTO_TAB_LAST.rawValue: cycle = .last
            default:
                if raw > 0 {
                    cycle = .index(Int(raw))
                } else {
                    return false
                }
            }
            delegate?.ghosttyHost(self, cycle: cycle)
            return true
        case GHOSTTY_ACTION_SET_TITLE:
            guard let surface, let title = cString(action.action.set_title.title) else { return false }
            delegate?.ghosttyHost(self, surface: surface, setTitle: title)
            return true
        case GHOSTTY_ACTION_SET_TAB_TITLE:
            guard let surface, let title = cString(action.action.set_tab_title.title) else { return false }
            delegate?.ghosttyHost(self, surface: surface, setTabTitle: title)
            return true
        case GHOSTTY_ACTION_PWD:
            guard let surface, let path = cString(action.action.pwd.pwd) else { return false }
            delegate?.ghosttyHost(self, surface: surface, setWorkingDirectory: path)
            return true
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            guard let surface else { return false }
            delegate?.ghosttyHost(self, surface: surface, cursor: cursorStyle(action.action.mouse_shape))
            return true
        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            guard let surface else { return false }
            let hidden = action.action.mouse_visibility == GHOSTTY_MOUSE_HIDDEN
            delegate?.ghosttyHost(self, surface: surface, cursorHidden: hidden)
            return true
        case GHOSTTY_ACTION_OPEN_CONFIG:
            let opened = ghostty_config_open_path()
            let path = GhosttyString(opened).value
            if !path.isEmpty {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            return true
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true
        default:
            return false
        }
    }

    private func cursorStyle(_ shape: ghostty_action_mouse_shape_e) -> CursorStyle {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_TEXT, GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
            return .text
        case GHOSTTY_MOUSE_SHAPE_POINTER:
            return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR, GHOSTTY_MOUSE_SHAPE_CELL:
            return .crosshair
        case GHOSTTY_MOUSE_SHAPE_GRAB:
            return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING:
            return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED, GHOSTTY_MOUSE_SHAPE_NO_DROP:
            return .notAllowed
        case GHOSTTY_MOUSE_SHAPE_EW_RESIZE, GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_W_RESIZE, GHOSTTY_MOUSE_SHAPE_E_RESIZE:
            return .resizeHorizontal
        case GHOSTTY_MOUSE_SHAPE_NS_RESIZE, GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_N_RESIZE, GHOSTTY_MOUSE_SHAPE_S_RESIZE:
            return .resizeVertical
        default:
            return .arrow
        }
    }

    private func cString(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        return String(cString: pointer)
    }

    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        let host = GhosttyHost.shared
        guard let surface = host.surface(for: userdata),
              let pasteboard = Self.pasteboard(location),
              let text = Self.pasteboardString(pasteboard) else { return false }
        text.withCString { pointer in
            ghostty_surface_complete_clipboard_request(surface.raw, pointer, state, false)
        }
        return true
    }

    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ string: UnsafePointer<CChar>?,
        _ state: UnsafeMutableRawPointer?,
        _ request: ghostty_clipboard_request_e
    ) {
        guard let string else { return }
        let text = String(cString: string)
        let host = GhosttyHost.shared
        guard let surface = host.surface(for: userdata) else { return }
        let prompt: String
        switch request {
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_READ:
            prompt = "A program in this terminal wants to read the clipboard."
        case GHOSTTY_CLIPBOARD_REQUEST_OSC_52_WRITE:
            prompt = "A program in this terminal wants to write the clipboard."
        default:
            prompt = "Paste the clipboard into this terminal?"
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = prompt
            alert.informativeText = text.count > 240 ? String(text.prefix(240)) + "…" : text
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            let allowed = alert.runModal() == .alertFirstButtonReturn
            let payload = allowed ? text : ""
            payload.withCString { pointer in
                ghostty_surface_complete_clipboard_request(surface.raw, pointer, state, true)
            }
        }
    }

    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ content: UnsafePointer<ghostty_clipboard_content_s>?,
        _ length: Int,
        _ confirm: Bool
    ) {
        guard let content, length > 0, let pasteboard = pasteboard(location) else { return }
        var items: [(mime: String, data: String)] = []
        for index in 0..<length {
            let item = content[index]
            guard let mime = item.mime, let data = item.data else { continue }
            items.append((String(cString: mime), String(cString: data)))
        }
        guard !items.isEmpty else { return }
        let apply = {
            pasteboard.clearContents()
            for item in items {
                let type = Self.pasteboardType(mime: item.mime)
                pasteboard.setString(item.data, forType: type)
            }
        }
        if !confirm {
            apply()
            return
        }
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "A program in this terminal wants to write the clipboard."
            alert.addButton(withTitle: "Allow")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                apply()
            }
        }
    }

    private static func closeSurface(_ userdata: UnsafeMutableRawPointer?, _ processAlive: Bool) {
        let host = GhosttyHost.shared
        guard let surface = host.surface(for: userdata) else { return }
        DispatchQueue.main.async {
            host.delegate?.ghosttyHost(host, surface: surface, closeProcessAlive: processAlive)
        }
    }

    private static func pasteboard(_ location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD:
            return .general
        case GHOSTTY_CLIPBOARD_SELECTION:
            return NSPasteboard(name: NSPasteboard.Name("com.boom.boome.selection"))
        default:
            return nil
        }
    }

    private static func pasteboardString(_ pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return urls.map { $0.isFileURL ? $0.path : $0.absoluteString }.joined(separator: " ")
        }
        return pasteboard.string(forType: .string)
    }

    private static func pasteboardType(mime: String) -> NSPasteboard.PasteboardType {
        if mime == "text/plain" { return .string }
        if let type = UTType(mimeType: mime) {
            return NSPasteboard.PasteboardType(type.identifier)
        }
        return NSPasteboard.PasteboardType(mime)
    }
}

protocol GhosttyHostDelegate: AnyObject {
    func ghosttyHostOpenNewTab(_ host: GhosttyHost)
    func ghosttyHostCloseCurrentTab(_ host: GhosttyHost)
    func ghosttyHostCloseWindow(_ host: GhosttyHost)
    func ghosttyHost(_ host: GhosttyHost, cycle: GhosttyHost.Cycle)
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setTitle title: String)
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setTabTitle title: String)
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, setWorkingDirectory path: String)
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, closeProcessAlive alive: Bool)
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursor: GhosttyHost.CursorStyle)
    func ghosttyHost(_ host: GhosttyHost, surface: GhosttyHost.Surface, cursorHidden hidden: Bool)
}

private struct GhosttyString {
    let value: String
    init(_ string: ghostty_string_s) {
        if let pointer = string.ptr, string.len > 0 {
            let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
            value = String(bytes: UnsafeBufferPointer(start: bytes, count: Int(string.len)), encoding: .utf8) ?? ""
        } else {
            value = ""
        }
        ghostty_string_free(string)
    }
}

private extension Optional where Wrapped == String {
    func withCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        switch self {
        case .some(let value):
            return value.withCString { body($0) }
        case .none:
            return body(nil)
        }
    }
}
