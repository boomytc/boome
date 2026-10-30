const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const color = @import("color.zig");
const size = @import("size.zig");
const charsets = @import("charsets.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const modespkg = @import("modes.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const Cell = @import("page.zig").Cell;
const Coordinate = @import("point.zig").Coordinate;
const Page = @import("page.zig").Page;
const PageList = @import("PageList.zig");
const Pin = PageList.Pin;
const Row = @import("page.zig").Row;
const Selection = @import("Selection.zig");
const Style = @import("style.zig").Style;

/// Formats available.
pub const Format = enum {
    /// Plain text.
    plain,

    /// Include VT sequences to preserve colors, styles, URLs, etc.
    /// This is predominantly SGR sequences but may contain others as needed.
    ///
    /// Note that for reference colors, like palette indices, this will
    /// vary based on the formatter and you should see the docs. For example,
    /// PageFormatter with VT will emit SGR sequences with palette indices,
    /// not the color itself.
    ///
    /// For VT, newlines will be emitted as `\r\n` so that the cursor properly
    /// moves back to the beginning prior emitting follow-up lines.
    vt,

    /// HTML output.
    ///
    /// This will emit inline styles for as much styling as possible,
    /// in the interest of simplicity and ease of editing. This isn't meant
    /// to build the most beautiful or efficient HTML, but rather to be
    /// stylistically correct.
    ///
    /// For colors, RGB values are emitted as inline CSS (#RRGGBB) while palette
    /// indices use CSS variables (var(--vt-palette-N)). The palette colors are
    /// emitted by TerminalFormatter.Extra.palette as a <style> block if you
    /// want to also include that. But if you only format a screen or lower,
    /// the formatter doesn't have access to the current palette to render it.
    ///
    /// Newlines are emitted as actual '\n' characters. Consumers should use
    /// CSS white-space: pre or pre-wrap to preserve spacing and alignment.
    html,

    pub fn styled(self: Format) bool {
        return switch (self) {
            .plain => false,
            .html, .vt => true,
        };
    }
};

pub const CodepointMap = struct {
    /// Unicode codepoint range to replace.
    /// Asserts: range[0] <= range[1]
    range: [2]u21,

    /// Replacement value for this range.
    replacement: Replacement,

    pub const Replacement = union(enum) {
        /// A single replacement codepoint.
        codepoint: u21,

        /// A UTF-8 encoded string to replace with. Asserts the
        /// UTF-8 encoding (must be valid).
        string: []const u8,
    };
};

/// Common encoding options regardless of what exact formatter is used.
pub const Options = struct {
    /// The format to emit.
    emit: Format,

    /// Whether to unwrap soft-wrapped lines. If false, this will emit the
    /// screen contents as it is rendered on the page in the given size.
    unwrap: bool = false,

    /// Trim trailing whitespace on lines with other text. Trailing blank
    /// lines are always trimmed. This only affects trailing whitespace
    /// on rows that have at least one other cell with text. Whitespace
    /// is currently only space characters (0x20).
    trim: bool = true,

    /// Replace matching Unicode codepoints with some other values.
    /// This will use the last matching range found in the list.
    codepoint_map: ?std.MultiArrayList(CodepointMap) = .{},

    /// Set a background and foreground color to use for the "screen".
    /// For styled formats, this will emit the proper sequences or styles.
    background: ?color.RGB = null,
    foreground: ?color.RGB = null,

    /// If set, then styled formats in `emit` will use this palette to
    /// emit colors directly as RGB. If this is null, styled formats will
    /// still work but will use deferred palette styling (e.g. CSS variables
    /// for HTML or the actual palette indexes for VT).
    palette: ?*const color.Palette = null,

    pub const plain: Options = .{ .emit = .plain };
    pub const vt: Options = .{ .emit = .vt };
    pub const html: Options = .{ .emit = .html };
};

/// Maps byte positions in formatted output to PageList pins.
///
/// Used by formatters that operate on PageLists to track the source position
/// of each byte written. The caller is responsible for freeing the map.
pub const PinMap = struct {
    alloc: Allocator,
    map: *std.ArrayList(Pin),
};

/// Terminal formatter formats the active terminal screen.
///
/// This will always only emit data related to the currently active screen.
/// If you want to emit data for a specific screen (e.g. primary vs alt), then
/// switch to that screen in the terminal prior to using this.
///
/// If you want to emit data for all screens (a less common operation), then
/// you must create a no-content TerminalFormatter followed by multiple
/// explicit ScreenFormatter calls. This isn't a common operation so this
/// little extra work should be acceptable.
///
/// For styled formatting, this will emit the palette colors at the
/// beginning so that the output can be rendered properly according to
/// the current terminal state.
pub const TerminalFormatter = struct {
    /// The terminal to format.
    terminal: *const Terminal,

    /// The common options
    opts: Options,

    /// The content to include.
    content: ScreenFormatter.Content,

    /// Extra stuff to emit, such as terminal modes, palette, cursor, etc.
    /// This information is ONLY emitted when the format is "vt".
    extra: Extra,

    /// If non-null, then `map` will contain the Pin of every byte
    /// byte written to the writer offset by the byte index. It is the
    /// caller's responsibility to free the map.
    ///
    /// Note that some emitted bytes may not correspond to any Pin, such as
    /// the extra data around terminal state (palette, modes, etc.). For these,
    /// we'll map it to the most previous pin so there is some continuity but
    /// its an arbitrary choice.
    ///
    /// Warning: there is a significant performance hit to track this
    pin_map: ?PinMap,

    pub const Extra = packed struct {
        /// Emit the palette using OSC 4 sequences.
        palette: bool,

        /// Emit terminal modes that differ from their defaults using CSI h/l
        /// sequences. Defaults are according to the Ghostty defaults which
        /// are generally match most terminal defaults. This will include
        /// things like current screen, bracketed mode, mouse event reporting,
        /// etc.
        modes: bool,

        /// Emit scrolling region state using DECSTBM and DECSLRM sequences.
        scrolling_region: bool,

        /// Emit tabstop positions by clearing all tabs (CSI 3 g) and setting
        /// each configured tabstop with HTS.
        tabstops: bool,

        /// Emit the present working directory using OSC 7.
        pwd: bool,

        /// Emit keyboard modes such as ModifyOtherKeys using CSI > 4 m
        /// sequences.
        keyboard: bool,

        /// The screen extras to emit. TerminalFormatter always only
        /// emits data for the currently active screen. If you want to emit
        /// data for all screens, you should manually construct a no-content
        /// terminal formatter, followed by screen formatters.
        screen: ScreenFormatter.Extra,

        /// Emit nothing.
        pub const none: Extra = .{
            .palette = false,
            .modes = false,
            .scrolling_region = false,
            .tabstops = false,
            .pwd = false,
            .keyboard = false,
            .screen = .none,
        };

        /// Emit style-relevant information only such as palettes.
        pub const styles: Extra = .{
            .palette = true,
            .modes = false,
            .scrolling_region = false,
            .tabstops = false,
            .pwd = false,
            .keyboard = false,
            .screen = .styles,
        };

        /// Emit everything. This reconstructs the terminal state as closely
        /// as possible.
        pub const all: Extra = .{
            .palette = true,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = true,
            .keyboard = true,
            .screen = .all,
        };
    };

    pub fn init(
        terminal: *const Terminal,
        opts: Options,
    ) TerminalFormatter {
        return .{
            .terminal = terminal,
            .opts = opts,
            .content = .{ .selection = null },
            .extra = .styles,
            .pin_map = null,
        };
    }

    pub fn format(
        self: TerminalFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        // Emit palette before screen content if using VT format. Technically
        // we could do this after but this way if replay is slow for whatever
        // reason the colors will be right right away.
        if (self.extra.palette) palette: {
            switch (self.opts.emit) {
                .plain => break :palette,

                .vt => {
                    for (self.terminal.colors.palette.current, 0..) |rgb, i| {
                        try writer.print(
                            "\x1b]4;{d};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                            .{ i, rgb.r, rgb.g, rgb.b },
                        );
                    }
                },

                // For HTML, we emit CSS to setup our palette variables.
                .html => {
                    try writer.writeAll("<style>:root{");
                    for (self.terminal.colors.palette.current, 0..) |rgb, i| {
                        try writer.print(
                            "--vt-palette-{d}: #{x:0>2}{x:0>2}{x:0>2};",
                            .{ i, rgb.r, rgb.g, rgb.b },
                        );
                    }
                    try writer.writeAll("}</style>");
                },
            }

            // If we have a pin_map, add the bytes we wrote to map.
            if (self.pin_map) |*m| {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                var extra_formatter: TerminalFormatter = self;
                extra_formatter.content = .none;
                extra_formatter.pin_map = null;
                extra_formatter.extra = .none;
                extra_formatter.extra.palette = true;
                try extra_formatter.format(&discarding.writer);

                // Map all those bytes to the same pin. Use the top left to ensure
                // the node pointer is always properly initialized.
                m.map.appendNTimes(
                    m.alloc,
                    self.terminal.screens.active.pages.getTopLeft(.screen),
                    discarding.count,
                ) catch return error.WriteFailed;
            }
        }

        // Emit terminal modes that differ from defaults. We probably have
        // some modes we want to emit before and some after, but for now for
        // simplicity we just emit them all before. If we make this more complex
        // later we should add test cases for it.
        if (self.opts.emit == .vt and self.extra.modes) {
            inline for (@typeInfo(modespkg.Mode).@"enum".fields) |field| {
                const mode: modespkg.Mode = @enumFromInt(field.value);
                const current = self.terminal.modes.get(mode);
                const default_val = @field(self.terminal.modes.default, field.name);

                if (current != default_val) {
                    const tag: modespkg.ModeTag = @bitCast(@intFromEnum(mode));
                    const prefix = if (tag.ansi) "" else "?";
                    const suffix = if (current) "h" else "l";
                    try writer.print("\x1b[{s}{d}{s}", .{ prefix, tag.value, suffix });
                }
            }

            // If we have a pin_map, add the bytes we wrote to map.
            if (self.pin_map) |*m| {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                var extra_formatter: TerminalFormatter = self;
                extra_formatter.content = .none;
                extra_formatter.pin_map = null;
                extra_formatter.extra = .none;
                extra_formatter.extra.modes = true;
                try extra_formatter.format(&discarding.writer);

                // Map all those bytes to the same pin. Use the top left to ensure
                // the node pointer is always properly initialized.
                m.map.appendNTimes(
                    m.alloc,
                    self.terminal.screens.active.pages.getTopLeft(.screen),
                    discarding.count,
                ) catch return error.WriteFailed;
            }
        }

        var screen_formatter: ScreenFormatter = .init(self.terminal.screens.active, self.opts);
        screen_formatter.content = self.content;
        screen_formatter.extra = self.extra.screen;
        screen_formatter.pin_map = self.pin_map;
        try screen_formatter.format(writer);

        // Extra terminal state to emit after the screen contents so that
        // it doesn't impact the emitted contents.
        if (self.opts.emit == .vt) {
            // Emit scrolling region using DECSTBM and DECSLRM
            if (self.extra.scrolling_region) {
                const region = &self.terminal.scrolling_region;

                // DECSTBM: top and bottom margins (1-indexed)
                // Only emit if not the full screen
                if (region.top != 0 or region.bottom != self.terminal.rows - 1) {
                    try writer.print("\x1b[{d};{d}r", .{ region.top + 1, region.bottom + 1 });
                }

                // DECSLRM: left and right margins (1-indexed)
                // Only emit if not the full width
                if (region.left != 0 or region.right != self.terminal.cols - 1) {
                    try writer.print("\x1b[{d};{d}s", .{ region.left + 1, region.right + 1 });
                }
            }

            // Emit tabstop positions
            if (self.extra.tabstops) {
                // Clear all tabs (CSI 3 g)
                try writer.print("\x1b[3g", .{});

                // Set each configured tabstop by moving cursor and using HTS
                for (0..self.terminal.cols) |col| {
                    if (self.terminal.tabstops.get(col)) {
                        // Move cursor to the column (1-indexed)
                        try writer.print("\x1b[{d}G", .{col + 1});
                        // Set tab (HTS)
                        try writer.print("\x1bH", .{});
                    }
                }
            }

            // Emit keyboard modes such as ModifyOtherKeys
            if (self.extra.keyboard) {
                // Only emit if modify_other_keys_2 is true
                if (self.terminal.flags.modify_other_keys_2) {
                    try writer.print("\x1b[>4;2m", .{});
                }
            }

            // Emit present working directory using OSC 7
            if (self.extra.pwd) {
                const pwd = self.terminal.pwd.items;
                if (pwd.len > 0) try writer.print("\x1b]7;{s}\x1b\\", .{pwd});
            }

            // If we have a pin_map, add the bytes we wrote to map.
            if (self.pin_map) |*m| {
                var discarding: std.Io.Writer.Discarding = .init(&.{});
                var extra_formatter: TerminalFormatter = self;
                extra_formatter.content = .none;
                extra_formatter.pin_map = null;
                extra_formatter.extra = .none;
                extra_formatter.extra.scrolling_region = self.extra.scrolling_region;
                extra_formatter.extra.tabstops = self.extra.tabstops;
                extra_formatter.extra.keyboard = self.extra.keyboard;
                extra_formatter.extra.pwd = self.extra.pwd;
                try extra_formatter.format(&discarding.writer);

                m.map.appendNTimes(
                    m.alloc,
                    if (m.map.items.len > 0) pin: {
                        const last = m.map.items[m.map.items.len - 1];
                        break :pin .{
                            .node = last.node,
                            .x = last.x,
                            .y = last.y,
                        };
                    } else self.terminal.screens.active.pages.getTopLeft(.screen),
                    discarding.count,
                ) catch return error.WriteFailed;
            }
        }
    }
};

/// Screen formatter formats a single terminal screen (e.g. primary vs alt).
pub const ScreenFormatter = struct {
    /// The screen to format.
    screen: *const Screen,

    /// The common options
    opts: Options,

    /// The content to include.
    content: Content,

    /// Extra stuff to emit, such as cursor, style, hyperlinks, etc.
    /// This information is ONLY emitted when the format is "vt".
    extra: Extra,

    /// If non-null, then `map` will contain the Pin of every byte
    /// byte written to the writer offset by the byte index. It is the
    /// caller's responsibility to free the map.
    ///
    /// Note that some emitted bytes may not correspond to any Pin, such as
    /// the extra data around screen state. For these, we'll map it to the
    /// most previous pin so there is some continuity but its an arbitrary
    /// choice.
    ///
    /// Warning: there is a significant performance hit to track this
    pin_map: ?PinMap,

    pub const Content = union(enum) {
        /// Emit no content, only terminal state such as modes, palette, etc.
        /// via extra.
        none,

        /// Emit the content specified by the selection. Null for all.
        /// The selection is inclusive on both ends.
        selection: ?Selection,
    };

    pub const Extra = packed struct {
        /// Emit cursor position using CUP (CSI H).
        cursor: bool,

        /// Emit current SGR style state based on the cursor's active style_id.
        /// This reconstructs the SGR attributes (bold, italic, colors, etc.) at
        /// the cursor position.
        style: bool,

        /// Emit current hyperlink state using OSC 8 sequences.
        /// This sets the active hyperlink based on cursor.hyperlink_id.
        hyperlink: bool,

        /// Emit character protection mode using DECSCA.
        protection: bool,

        /// Emit Kitty keyboard protocol state using CSI > u and CSI = sequences.
        kitty_keyboard: bool,

        /// Emit character set designations and invocations.
        /// This includes G0-G3 designations (ESC ( ) * +) and GL/GR invocations.
        charsets: bool,

        /// Emit nothing.
        pub const none: Extra = .{
            .cursor = false,
            .style = false,
            .hyperlink = false,
            .protection = false,
            .kitty_keyboard = false,
            .charsets = false,
        };

        /// Emit style-relevant information only.
        pub const styles: Extra = .{
            .cursor = false,
            .style = true,
            .hyperlink = true,
            .protection = false,
            .kitty_keyboard = false,
            .charsets = false,
        };

        /// Emit everything. This reconstructs the screen state as closely
        /// as possible.
        pub const all: Extra = .{
            .cursor = true,
            .style = true,
            .hyperlink = true,
            .protection = true,
            .kitty_keyboard = true,
            .charsets = true,
        };

        fn isSet(self: Extra) bool {
            const Int = @typeInfo(Extra).@"struct".backing_integer.?;
            const v: Int = @bitCast(self);
            return v != 0;
        }
    };

    pub fn init(
        screen: *const Screen,
        opts: Options,
    ) ScreenFormatter {
        return .{
            .screen = screen,
            .opts = opts,
            .content = .{ .selection = null },
            .extra = .none,
            .pin_map = null,
        };
    }

    pub fn format(
        self: ScreenFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.content) {
            .none => {},

            .selection => |selection_| {
                // Emit our pagelist contents according to our selection.
                var list_formatter: PageListFormatter = .init(&self.screen.pages, self.opts);
                list_formatter.pin_map = self.pin_map;
                if (selection_) |sel| {
                    list_formatter.top_left = sel.topLeft(self.screen);
                    list_formatter.bottom_right = sel.bottomRight(self.screen);
                    list_formatter.rectangle = sel.rectangle;
                }
                try list_formatter.format(writer);
            },
        }

        // Emit extra screen state after content if we care. The state has
        // to be emitted after since some state such as cursor position and
        // style are impacted by content rendering.
        switch (self.opts.emit) {
            .plain => return,
            .vt => if (!self.extra.isSet()) return,

            // HTML doesn't preserve any screen state because it has
            // nothing to do with rendering.
            .html => return,
        }

        // Emit current SGR style state
        if (self.extra.style) {
            const cursor = &self.screen.cursor;
            try writer.print("{f}", .{cursor.style.formatterVt()});
        }

        // Emit current hyperlink state using OSC 8
        if (self.extra.hyperlink) {
            const cursor = &self.screen.cursor;
            if (cursor.hyperlink) |link| {
                // Start hyperlink with uri (and explicit id if present)
                switch (link.id) {
                    .explicit => |id| try writer.print(
                        "\x1b]8;id={s};{s}\x1b\\",
                        .{ id, link.uri },
                    ),
                    .implicit => try writer.print(
                        "\x1b]8;;{s}\x1b\\",
                        .{link.uri},
                    ),
                }
            }
        }

        // Emit character protection mode using DECSCA
        if (self.extra.protection) {
            const cursor = &self.screen.cursor;
            if (cursor.protected) {
                // DEC protected mode
                try writer.print("\x1b[1\"q", .{});
            }
        }

        // Emit Kitty keyboard protocol state using CSI = u
        if (self.extra.kitty_keyboard) {
            const current_flags = self.screen.kitty_keyboard.current();
            if (current_flags.int() != kitty.KeyFlags.disabled.int()) {
                const flags = current_flags.int();
                try writer.print("\x1b[={d};1u", .{flags});
            }
        }

        // Emit character set designations and invocations
        if (self.extra.charsets) {
            const charset = &self.screen.charset;

            // Emit G0-G3 designations
            for (std.enums.values(charsets.Slots)) |slot| {
                const cs = charset.charsets.get(slot);
                if (cs != .utf8) { // Only emit non-default charsets
                    const intermediate: u8 = switch (slot) {
                        .G0 => '(',
                        .G1 => ')',
                        .G2 => '*',
                        .G3 => '+',
                    };
                    const final: u8 = switch (cs) {
                        .ascii => 'B',
                        .british => 'A',
                        .dec_special => '0',
                        else => continue,
                    };
                    try writer.print("\x1b{c}{c}", .{ intermediate, final });
                }
            }

            // Emit GL invocation if not G0
            if (charset.gl != .G0) {
                const seq = switch (charset.gl) {
                    .G0 => unreachable,
                    .G1 => "\x0e", // SO - Shift Out
                    .G2 => "\x1bn", // LS2
                    .G3 => "\x1bo", // LS3
                };
                try writer.print("{s}", .{seq});
            }

            // Emit GR invocation if not G2
            if (charset.gr != .G2) {
                const seq = switch (charset.gr) {
                    .G0 => unreachable, // GR can't be G0
                    .G1 => "\x1b~", // LS1R
                    .G2 => unreachable,
                    .G3 => "\x1b|", // LS3R
                };
                try writer.print("{s}", .{seq});
            }
        }

        // Emit cursor position using CUP (CSI H)
        if (self.extra.cursor) {
            const cursor = &self.screen.cursor;
            // CUP is 1-indexed
            try writer.print("\x1b[{d};{d}H", .{ cursor.y + 1, cursor.x + 1 });
        }

        // If we have a pin_map, we need to count how many bytes the extras
        // will emit so we can map them all to the same pin. We do this by
        // formatting to a discarding writer with content=none.
        if (self.pin_map) |*m| {
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            var extra_formatter: ScreenFormatter = self;
            extra_formatter.content = .none;
            extra_formatter.pin_map = null;
            try extra_formatter.format(&discarding.writer);

            // Map all those bytes to the same pin. Use the first page node
            // to ensure the node pointer is always properly initialized.
            m.map.appendNTimes(
                m.alloc,
                if (m.map.items.len > 0) pin: {
                    // There is a weird Zig miscompilation here on 0.15.2.
                    // If I return the m.map.items value directly then we
                    // get undefined memory (even though we're copying a
                    // Pin struct). If we duplicate here like this we do
                    // not.
                    const last = m.map.items[m.map.items.len - 1];
                    break :pin .{
                        .node = last.node,
                        .x = last.x,
                        .y = last.y,
                    };
                } else self.screen.pages.getTopLeft(.screen),
                discarding.count,
            ) catch return error.WriteFailed;
        }
    }
};

/// PageList formatter formats multiple pages as represented by a PageList.
pub const PageListFormatter = struct {
    /// The pagelist to format.
    list: *const PageList,

    /// The common options
    opts: Options,

    /// The bounds of the PageList to format. The top left and bottom right
    /// MUST be ordered properly.
    top_left: ?PageList.Pin,
    bottom_right: ?PageList.Pin,

    /// If true, the boundaries define a rectangle selection where start_x
    /// and end_x apply to every row, not just the first and last.
    rectangle: bool,

    /// If non-null, then `map` will contain the Pin of every byte
    /// byte written to the writer offset by the byte index. It is the
    /// caller's responsibility to free the map.
    ///
    /// Warning: there is a significant performance hit to track this
    pin_map: ?PinMap,

    pub fn init(
        list: *const PageList,
        opts: Options,
    ) PageListFormatter {
        return PageListFormatter{
            .list = list,
            .opts = opts,
            .top_left = null,
            .bottom_right = null,
            .rectangle = false,
            .pin_map = null,
        };
    }

    pub fn format(
        self: PageListFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const tl: PageList.Pin = self.top_left orelse self.list.getTopLeft(.screen);
        const br: PageList.Pin = self.bottom_right orelse self.list.getBottomRight(.screen).?;

        // If we keep track of pins, we'll need this.
        var point_map: std.ArrayList(Coordinate) = .empty;
        defer if (self.pin_map) |*m| point_map.deinit(m.alloc);

        var page_state: ?PageFormatter.TrailingState = null;
        var iter = tl.pageIterator(.right_down, br);
        while (iter.next()) |chunk| {
            assert(chunk.start < chunk.end);
            assert(chunk.end > 0);

            var formatter: PageFormatter = .init(&chunk.node.data, self.opts);
            formatter.start_y = chunk.start;
            formatter.end_y = chunk.end - 1;
            formatter.trailing_state = page_state;
            formatter.rectangle = self.rectangle;

            // For rectangle selection, apply start_x and end_x to all chunks
            if (self.rectangle) {
                formatter.start_x = tl.x;
                formatter.end_x = br.x;
            } else {
                // Otherwise only on the first/last, respectively.
                if (chunk.node == tl.node) formatter.start_x = tl.x;
                if (chunk.node == br.node) formatter.end_x = br.x;
            }

            // If we're tracking pins, then we setup a point map for the
            // page formatter (cause it can't track pins). And then we convert
            // this to pins later.
            if (self.pin_map) |*m| {
                point_map.clearRetainingCapacity();
                formatter.point_map = .{ .alloc = m.alloc, .map = &point_map };
            }

            page_state = try formatter.formatWithState(writer);

            // If we're tracking pins then grab our points and write them
            // to our pin map.
            if (self.pin_map) |*m| {
                for (point_map.items) |coord| {
                    m.map.append(m.alloc, .{
                        .node = chunk.node,
                        .x = coord.x,
                        .y = @intCast(coord.y),
                    }) catch return error.WriteFailed;
                }
            }
        }
    }
};

/// Page formatter.
///
/// For styled formatting such as VT, this will emit references for palette
/// colors. If you want to capture the palette as-is at the type of formatting,
/// you'll have to emit the sequences for setting up the palette prior to
/// this formatting. (TODO: A function to do this)
pub const PageFormatter = struct {
    /// The page to format.
    page: *const Page,

    /// The common options
    opts: Options,

    /// Start and end points within the page to format. If end x is not given
    /// then it will be the full width. If end y is not given then it will be
    /// the full height.
    ///
    /// The start and end are both inclusive, so equal values will still
    /// return a non-empty result (i.e. a single cell or row).
    ///
    /// The start x is considered the X in the first row and end X is
    /// X in the final row. This isn't a rectangle selection by default.
    ///
    /// If start X falls on the second column of a wide character, then
    /// the entire character will be included (as if you specified the
    /// previous column).
    start_x: size.CellCountInt,
    start_y: size.CellCountInt,
    end_x: ?size.CellCountInt,
    end_y: ?size.CellCountInt,

    /// If true, the start x/y and end x/y define a rectangle selection.
    /// In this case, the boundaries will apply to every row, not just
    /// the first and last.
    rectangle: bool,

    /// If non-null, then `map` will contain the x/y coordinate of every
    /// byte written to the writer offset by the byte index. It is the
    /// caller's responsibility to free the map.
    ///
    /// The x/y coordinate will be the coordinates within the page.
    ///
    /// Warning: there is a significant performance hit to track this
    point_map: ?struct {
        alloc: Allocator,
        map: *std.ArrayList(Coordinate),
    },

    /// The previous trailing state from the prior page. If you're iterating
    /// over multiple pages this helps ensure that unwrapping and other
    /// accounting works properly.
    trailing_state: ?TrailingState,

    /// Trailing state. This is used to ensure that rows wrapped across
    /// multiple pages are unwrapped properly, as well as other accounting
    /// we may do in the future.
    pub const TrailingState = struct {
        rows: usize = 0,
        cells: usize = 0,

        pub const empty: TrailingState = .{ .rows = 0, .cells = 0 };
    };

    /// Initializes a page formatter. Other options can be set directly on the
    /// struct after initialization and before calling `format()`.
    pub fn init(page: *const Page, opts: Options) PageFormatter {
        return .{
            .page = page,
            .opts = opts,
            .start_x = 0,
            .start_y = 0,
            .end_x = null,
            .end_y = null,
            .rectangle = false,
            .point_map = null,
            .trailing_state = null,
        };
    }

    pub fn format(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        _ = try self.formatWithState(writer);
    }

    pub fn formatWithState(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!TrailingState {
        var blank_rows: usize = 0;
        var blank_cells: usize = 0;

        // Continue our prior trailing state if we have it, but only if we're
        // starting from the beginning (start_y and start_x are both 0).
        // If a non-zero start position is specified, ignore trailing state.
        if (self.trailing_state) |state| {
            if (self.start_y == 0 and self.start_x == 0) {
                blank_rows = state.rows;
                blank_cells = state.cells;
            }
        }

        // Setup our starting column and perform some validation for overflows.
        // Note: start_x only applies to the first row, end_x only applies to the last row.
        const start_x: size.CellCountInt = self.start_x;
        if (start_x >= self.page.size.cols) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_x_unclamped: size.CellCountInt = self.end_x orelse self.page.size.cols - 1;
        var end_x = @min(end_x_unclamped, self.page.size.cols - 1);

        // Setup our starting row and perform some validation for overflows.
        const start_y: size.CellCountInt = self.start_y;
        if (start_y >= self.page.size.rows) return .{ .rows = blank_rows, .cells = blank_cells };
        const end_y_unclamped: size.CellCountInt = self.end_y orelse self.page.size.rows - 1;
        if (start_y > end_y_unclamped) return .{ .rows = blank_rows, .cells = blank_cells };
        var end_y = @min(end_y_unclamped, self.page.size.rows - 1);

        // Edge case: if our end x/y falls on a spacer head AND we're unwrapping,
        // then we move the x/y to the start of the next row (if available).
        if (self.opts.unwrap and !self.rectangle) {
            const final_row = self.page.getRow(end_y);
            const cells = self.page.getCells(final_row);
            switch (cells[end_x].wide) {
                .spacer_head => {
                    // Move to next row if available
                    //
                    // TODO: if unavailable, we should add to our trailing state
                    //
                    // so the pagelist formatter can be aware and maybe add
                    // another page
                    if (end_y < self.page.size.rows - 1) {
                        end_y += 1;
                        end_x = 0;
                    }
                },

                else => {},
            }
        }

        // If we only have a single row, validate that start_x <= end_x
        if (start_y == end_y and start_x > end_x) {
            return .{ .rows = blank_rows, .cells = blank_cells };
        }

        // Wrap HTML output in monospace font styling
        switch (self.opts.emit) {
            .plain => {},

            .html => {
                // Setup our div. We use a buffer here that should always
                // fit the stuff we need, in order to make counting bytes easier.
                var buf: [1024]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buf);
                const buf_writer = stream.writer();

                // Monospace and whitespace preserving
                buf_writer.writeAll("<div style=\"font-family: monospace; white-space: pre;") catch return error.WriteFailed;

                // Background/foreground colors
                if (self.opts.background) |bg| buf_writer.print(
                    "background-color: #{x:0>2}{x:0>2}{x:0>2};",
                    .{ bg.r, bg.g, bg.b },
                ) catch return error.WriteFailed;
                if (self.opts.foreground) |fg| buf_writer.print(
                    "color: #{x:0>2}{x:0>2}{x:0>2};",
                    .{ fg.r, fg.g, fg.b },
                ) catch return error.WriteFailed;

                buf_writer.writeAll("\">") catch return error.WriteFailed;

                const header = stream.getWritten();
                try writer.writeAll(header);
                if (self.point_map) |*map| map.map.appendNTimes(
                    map.alloc,
                    .{ .x = 0, .y = 0 },
                    header.len,
                ) catch return error.WriteFailed;
            },

            .vt => {
                // OSC 10 sets foreground color, OSC 11 sets background color
                var buf: [512]u8 = undefined;
                var stream = std.io.fixedBufferStream(&buf);
                const buf_writer = stream.writer();
                if (self.opts.foreground) |fg| {
                    buf_writer.print(
                        "\x1b]10;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                        .{ fg.r, fg.g, fg.b },
                    ) catch return error.WriteFailed;
                }
                if (self.opts.background) |bg| {
                    buf_writer.print(
                        "\x1b]11;rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\",
                        .{ bg.r, bg.g, bg.b },
                    ) catch return error.WriteFailed;
                }

                const header = stream.getWritten();
                try writer.writeAll(header);
                if (self.point_map) |*map| map.map.appendNTimes(
                    map.alloc,
                    .{ .x = 0, .y = 0 },
                    header.len,
                ) catch return error.WriteFailed;
            },
        }

        // Our style for non-plain formats
        var style: Style = .{};

        // Track hyperlink state for HTML and VT. Close </a> or OSC 8 when
        // the hyperlink changes or ends. VT replaces an open hyperlink by
        // opening the next one, so it only writes a close when none follows.
        var current_hyperlink_id: ?hyperlink.Id = null;

        // Most pages hold no hyperlinks, so skip the per-cell lookup.
        const page_hyperlinks = self.page.hyperlinkCount() > 0;

        for (start_y..end_y + 1) |y_usize| {
            const y: size.CellCountInt = @intCast(y_usize);
            const row: *Row = self.page.getRow(y);
            const cells: []const Cell = self.page.getCells(row);

            // Determine the x range for this row
            // - First row: start_x to end of row (or end_x if single row)
            // - Last row: start of row to end_x
            // - Middle rows: full width
            const cells_subset, const row_start_x = cells_subset: {
                // The end is always straightforward
                const row_end_x: size.CellCountInt = if (self.rectangle or y == end_y)
                    end_x + 1
                else
                    self.page.size.cols;

                // The first we have to check if our start X falls on the
                // tail of a wide character.
                const row_start_x: size.CellCountInt = if (start_x > 0 and
                    (self.rectangle or y == start_y))
                start_x: {
                    break :start_x switch (cells[start_x].wide) {
                        // Include the prior cell to get the full wide char
                        .spacer_tail => start_x - 1,

                        // If we're a spacer head on our first row then we
                        // skip this whole row.
                        .spacer_head => continue,

                        .narrow, .wide => start_x,
                    };
                } else 0;

                const subset = cells[row_start_x..row_end_x];
                break :cells_subset .{ subset, row_start_x };
            };

            // If this row is blank, accumulate to avoid a bunch of extra
            // work later. If it isn't blank, make sure we dump all our
            // blanks.
            if (!Cell.hasTextAny(cells_subset)) {
                blank_rows += 1;
                continue;
            }

            if (blank_rows > 0) {
                // Reset style before emitting newlines to prevent background
                // colors from bleeding into the next line's leading cells.
                if (!style.default()) {
                    try self.formatStyleClose(writer);
                    style = .{};
                }

                const sequence: []const u8 = switch (self.opts.emit) {
                    // Plaintext just uses standard newlines because newlines
                    // on their own usually move the cursor back in anywhere
                    // you type plaintext.
                    .plain => "\n",

                    // VT uses \r\n because in a raw pty, \n alone doesn't
                    // guarantee moving the cursor back to column 0. \r
                    // makes it work for sure.
                    .vt => "\r\n",

                    // HTML uses just \n because HTML rendering will move
                    // the cursor back.
                    .html => "\n",
                };

                for (0..blank_rows) |_| try writer.writeAll(sequence);

                // \r and \n map to the row that ends with this newline.
                // If we're continuing (trailing state) then this will be
                // in a prior page, so we just map to the first row of this
                // page.
                if (self.point_map) |*map| {
                    const start: Coordinate = if (map.map.items.len > 0)
                        map.map.items[map.map.items.len - 1]
                    else
                        .{ .x = 0, .y = 0 };

                    // The first one inherits the x value.
                    map.map.appendNTimes(
                        map.alloc,
                        .{ .x = start.x, .y = start.y },
                        sequence.len,
                    ) catch return error.WriteFailed;

                    // All others have x = 0 since they reference their prior
                    // blank line.
                    for (1..blank_rows) |y_offset_usize| {
                        const y_offset: size.CellCountInt = @intCast(y_offset_usize);
                        map.map.appendNTimes(
                            map.alloc,
                            .{ .x = 0, .y = start.y + y_offset },
                            sequence.len,
                        ) catch return error.WriteFailed;
                    }
                }

                blank_rows = 0;
            }

            // If we're not wrapped, we always add a newline so after
            // the row is printed we can add a newline.
            if (!row.wrap or !self.opts.unwrap) blank_rows += 1;

            // If the row doesn't continue a wrap then we need to reset
            // our blank cell count.
            if (!row.wrap_continuation or !self.opts.unwrap) blank_cells = 0;

            // Go through each cell and print it
            for (cells_subset, row_start_x..) |*cell, x_usize| {
                const x: size.CellCountInt = @intCast(x_usize);

                // Skip spacers. These happen naturally when wide characters
                // are printed again on the screen (for well-behaved terminals!)
                switch (cell.wide) {
                    .narrow, .wide => {},
                    .spacer_head, .spacer_tail => continue,
                }

                // If we have a zero value, then we accumulate a counter. We
                // only want to turn zero values into spaces if we have a non-zero
                // char sometime later.
                blank: {
                    // If we're emitting styled output (not plaintext) and
                    // the cell has some kind of styling or is not empty
                    // then this isn't blank.
                    if (self.opts.emit.styled() and
                        (!cell.isEmpty() or cell.hasStyling())) break :blank;

                    // Cells with no text are blank
                    if (!cell.hasText()) {
                        blank_cells += 1;
                        continue;
                    }

                    // Trailing spaces are blank. We know it is trailing
                    // because if we get a non-empty cell later we'll
                    // fill the blanks.
                    if (cell.codepoint() == ' ' and self.opts.trim) {
                        blank_cells += 1;
                        continue;
                    }
                }

                // This cell is not blank. If we have accumulated blank cells
                // then we want to emit them now.
                if (blank_cells > 0) {
                    // Blank cells have no hyperlink. In VT an open OSC 8
                    // would apply to the spaces written for them.
                    if (self.opts.emit == .vt and current_hyperlink_id != null) {
                        try self.formatHyperlinkClose(writer);
                        current_hyperlink_id = null;
                    }

                    try writer.splatByteAll(' ', blank_cells);

                    if (self.point_map) |*map| {
                        // Map each blank cell to its coordinate. Blank cells can span
                        // multiple rows if they carry over from wrap continuation.
                        var remaining_blanks = blank_cells;
                        var blank_x = x;
                        var blank_y = y;
                        while (remaining_blanks > 0) : (remaining_blanks -= 1) {
                            if (blank_x > 0) {
                                // We have space in this row
                                blank_x -= 1;
                            } else if (blank_y > 0) {
                                // Wrap to previous row
                                blank_y -= 1;
                                blank_x = self.page.size.cols - 1;
                            } else {
                                // Can't go back further, just use (0, 0)
                                blank_x = 0;
                                blank_y = 0;
                            }

                            map.map.append(
                                map.alloc,
                                .{ .x = blank_x, .y = blank_y },
                            ) catch return error.WriteFailed;
                        }
                    }

                    blank_cells = 0;
                }

                style: {
                    // If we aren't emitting styled output then we don't
                    // have to worry about styles.
                    if (!self.opts.emit.styled()) break :style;

                    // Get our cell style.
                    const cell_style = self.cellStyle(cell);

                    // If the style hasn't changed, don't bloat output.
                    if (cell_style.eql(style)) break :style;

                    // If we had a previous style, we need to close it,
                    // because we've confirmed we have some new style
                    // (which is maybe default).
                    if (!style.default()) switch (self.opts.emit) {
                        .html => try self.formatStyleClose(writer),

                        // For VT, we only close if we're switching to a default
                        // style because any non-default style will emit
                        // a \x1b[0m as the start of a VT coloring sequence.
                        .vt => if (cell_style.default()) try self.formatStyleClose(writer),

                        // Unreachable because of the styled() check at the
                        // top of this block.
                        .plain => unreachable,
                    };

                    // At this point, we can copy our style over
                    style = cell_style;

                    // If we're just the default style now, we're done.
                    if (cell_style.default()) break :style;

                    // New style, emit it.
                    try self.formatStyleOpen(
                        writer,
                        &style,
                    );

                    // If we have a point map, we map the style to
                    // this cell.
                    if (self.point_map) |*map| {
                        var discarding: std.Io.Writer.Discarding = .init(&.{});
                        try self.formatStyleOpen(
                            &discarding.writer,
                            &style,
                        );
                        for (0..discarding.count) |_| map.map.append(map.alloc, .{
                            .x = x,
                            .y = y,
                        }) catch return error.WriteFailed;
                    }
                }

                // Hyperlink state
                hyperlink: {
                    // HTML emits anchors and VT emits OSC 8. Plain text
                    // has nowhere to put a hyperlink.
                    if (!self.opts.emit.styled() or !page_hyperlinks) break :hyperlink;

                    // Get the hyperlink ID. This ID is our internal ID,
                    // not necessarily the OSC8 ID.
                    const link_id_: ?u16 = if (cell.hyperlink)
                        self.page.lookupHyperlink(cell)
                    else
                        null;

                    // If our hyperlink IDs match (even null) then we have
                    // identical hyperlink state and we do nothing.
                    if (current_hyperlink_id == link_id_) break :hyperlink;

                    // HTML must close the previous anchor. VT opening a
                    // hyperlink replaces the open one, so a close is written
                    // only when no hyperlink follows.
                    if (current_hyperlink_id != null and
                        (self.opts.emit == .html or link_id_ == null))
                    {
                        try self.formatHyperlinkClose(writer);
                    }
                    current_hyperlink_id = null;

                    // Set our current hyperlink ID
                    const link_id = link_id_ orelse break :hyperlink;
                    current_hyperlink_id = link_id;

                    // Emit the opening hyperlink tag
                    const link = self.page.hyperlink_set.get(
                        self.page.memory,
                        link_id,
                    );
                    try self.formatHyperlinkOpen(writer, link);

                    // If we have a point map, we map the hyperlink to
                    // this cell.
                    if (self.point_map) |*map| {
                        var discarding: std.Io.Writer.Discarding = .init(&.{});
                        try self.formatHyperlinkOpen(
                            &discarding.writer,
                            link,
                        );
                        for (0..discarding.count) |_| map.map.append(map.alloc, .{
                            .x = x,
                            .y = y,
                        }) catch return error.WriteFailed;
                    }
                }

                switch (cell.content_tag) {
                    // We combine codepoint and graphemes because both have
                    // shared style handling. We use comptime to dup it.
                    inline .codepoint, .codepoint_grapheme => |tag| {
                        try self.writeCell(tag, writer, cell);

                        // If we have a point map, all codepoints map to this
                        // cell.
                        if (self.point_map) |*map| {
                            var discarding: std.Io.Writer.Discarding = .init(&.{});
                            try self.writeCell(tag, &discarding.writer, cell);
                            for (0..discarding.count) |_| map.map.append(map.alloc, .{
                                .x = x,
                                .y = y,
                            }) catch return error.WriteFailed;
                        }
                    },

                    // Cells with only background color (no text). Emit a space
                    // with the appropriate background color SGR sequence.
                    .bg_color_palette, .bg_color_rgb => {
                        try writer.writeByte(' ');
                        if (self.point_map) |*map| map.map.append(
                            map.alloc,
                            .{ .x = x, .y = y },
                        ) catch return error.WriteFailed;
                    },
                }
            }
        }

        // If the style is non-default, we need to close our style tag.
        if (!style.default()) try self.formatStyleClose(writer);

        // Close any open hyperlink.
        if (current_hyperlink_id != null) try self.formatHyperlinkClose(writer);

        // Close the monospace wrapper for HTML output
        if (self.opts.emit == .html) {
            const closing = "</div>";
            try writer.writeAll(closing);
            if (self.point_map) |*map| {
                map.map.ensureUnusedCapacity(
                    map.alloc,
                    closing.len,
                ) catch return error.WriteFailed;
                map.map.appendNTimesAssumeCapacity(
                    map.map.items[map.map.items.len - 1],
                    closing.len,
                );
            }
        }

        return .{ .rows = blank_rows, .cells = blank_cells };
    }

    fn writeCell(
        self: PageFormatter,
        comptime tag: Cell.ContentTag,
        writer: *std.Io.Writer,
        cell: *const Cell,
    ) !void {
        // Blank cells get an empty space that isn't replaced by anything
        // because it isn't really a space. We do this so that formatting
        // is preserved if we're emitting styles.
        if (!cell.hasText()) {
            try writer.writeByte(' ');
            return;
        }

        try self.writeCodepointWithReplacement(writer, cell.content.codepoint);
        if (comptime tag == .codepoint_grapheme) {
            for (self.page.lookupGrapheme(cell).?) |cp| {
                try self.writeCodepointWithReplacement(writer, cp);
            }
        }
    }

    fn writeCodepointWithReplacement(
        self: PageFormatter,
        writer: *std.Io.Writer,
        codepoint: u21,
    ) !void {
        // Search for our replacement
        const r_: ?CodepointMap.Replacement = replacement: {
            const map = self.opts.codepoint_map orelse break :replacement null;
            const items = map.items(.range);
            for (0..items.len) |forward_i| {
                const i = items.len - forward_i - 1;
                const range = items[i];
                if (range[0] <= codepoint and codepoint <= range[1]) {
                    const replacements = map.items(.replacement);
                    break :replacement replacements[i];
                }
            }

            break :replacement null;
        };

        // If no replacement, write it directly.
        const r = r_ orelse return try self.writeCodepoint(
            writer,
            codepoint,
        );

        switch (r) {
            .codepoint => |v| try self.writeCodepoint(
                writer,
                v,
            ),

            .string => |s| {
                const view = std.unicode.Utf8View.init(s) catch unreachable;
                var it = view.iterator();
                while (it.nextCodepoint()) |cp| try self.writeCodepoint(
                    writer,
                    cp,
                );
            },
        }
    }

    fn writeCodepoint(
        self: PageFormatter,
        writer: *std.Io.Writer,
        codepoint: u21,
    ) !void {
        switch (self.opts.emit) {
            .plain, .vt => try writer.print("{u}", .{codepoint}),
            .html => {
                switch (codepoint) {
                    '<' => try writer.writeAll("&lt;"),
                    '>' => try writer.writeAll("&gt;"),
                    '&' => try writer.writeAll("&amp;"),
                    '"' => try writer.writeAll("&quot;"),
                    '\'' => try writer.writeAll("&#39;"),
                    else => {
                        // For HTML, emit ASCII (< 0x80) directly, but encode
                        // all non-ASCII as numeric entities to avoid encoding
                        // detection issues (fixes #9426). We can't set the
                        // meta tag because we emit partial HTML so this ensures
                        // proper unicode handling.
                        if (codepoint < 0x80) {
                            try writer.print("{u}", .{codepoint});
                        } else {
                            try writer.print("&#{d};", .{codepoint});
                        }
                    },
                }
            },
        }
    }

    /// Returns the style for the given cell. If there is no styling this
    /// will return the default style.
    fn cellStyle(
        self: *const PageFormatter,
        cell: *const Cell,
    ) Style {
        return switch (cell.content_tag) {
            inline .codepoint, .codepoint_grapheme => if (!cell.hasStyling())
                .{}
            else
                self.page.styles.get(
                    self.page.memory,
                    cell.style_id,
                ).*,

            .bg_color_palette => .{
                .bg_color = .{
                    .palette = cell.content.color_palette,
                },
            },

            .bg_color_rgb => .{
                .bg_color = .{
                    .rgb = .{
                        .r = cell.content.color_rgb.r,
                        .g = cell.content.color_rgb.g,
                        .b = cell.content.color_rgb.b,
                    },
                },
            },
        };
    }

    /// Write a string with HTML escaping. Used for escaping href attributes
    /// and other HTML attribute values.
    fn formatStyleOpen(
        self: PageFormatter,
        writer: *std.Io.Writer,
        style: *const Style,
    ) std.Io.Writer.Error!void {
        switch (self.opts.emit) {
            .plain => unreachable,

            .vt => {
                var formatter = style.formatterVt();
                formatter.palette = self.opts.palette;
                try writer.print("{f}", .{formatter});
            },

            // We use `display: inline` so that the div doesn't impact
            // layout since we're primarily using it as a CSS wrapper.
            .html => {
                var formatter = style.formatterHtml();
                formatter.palette = self.opts.palette;
                try writer.print(
                    "<div style=\"display: inline;{f}\">",
                    .{formatter},
                );
            },
        }
    }

    fn formatStyleClose(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const str: []const u8 = switch (self.opts.emit) {
            .plain => return,
            .vt => "\x1b[0m",
            .html => "</div>",
        };

        try writer.writeAll(str);
        if (self.point_map) |*m| {
            assert(m.map.items.len > 0);
            m.map.ensureUnusedCapacity(
                m.alloc,
                str.len,
            ) catch return error.WriteFailed;
            m.map.appendNTimesAssumeCapacity(
                m.map.items[m.map.items.len - 1],
                str.len,
            );
        }
    }

    fn formatHyperlinkOpen(
        self: PageFormatter,
        writer: *std.Io.Writer,
        link: *const hyperlink.PageEntry,
    ) std.Io.Writer.Error!void {
        const uri = link.uri.slice(self.page.memory);
        switch (self.opts.emit) {
            .plain => unreachable,

            // OSC 8. An explicit id is kept; opening replaces any open link.
            .vt => switch (link.id) {
                .explicit => |id| try writer.print(
                    "\x1b]8;id={s};{s}\x1b\\",
                    .{ id.slice(self.page.memory), uri },
                ),
                .implicit => try writer.print("\x1b]8;;{s}\x1b\\", .{uri}),
            },

            // layout since we're primarily using it as a CSS wrapper.
            .html => {
                try writer.writeAll("<a href=\"");
                for (uri) |byte| try self.writeCodepoint(
                    writer,
                    byte,
                );
                try writer.writeAll("\">");
            },
        }
    }

    fn formatHyperlinkClose(
        self: PageFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const str: []const u8 = switch (self.opts.emit) {
            .html => "</a>",
            .vt => "\x1b]8;;\x1b\\",
            .plain => return,
        };

        try writer.writeAll(str);
        if (self.point_map) |*m| {
            assert(m.map.items.len > 0);
            m.map.ensureUnusedCapacity(
                m.alloc,
                str.len,
            ) catch return error.WriteFailed;
            m.map.appendNTimesAssumeCapacity(
                m.map.items[m.map.items.len - 1],
                str.len,
            );
        }
    }
};
