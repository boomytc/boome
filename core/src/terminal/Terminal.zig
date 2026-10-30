//! The primary terminal emulation structure. This represents a single
//! "terminal" containing a grid of characters and exposes various operations
//! on that grid. This also maintains the scrollback buffer.
const Terminal = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const unicode = @import("../unicode/main.zig");
const uucode = @import("uucode");

const ansi = @import("ansi.zig");
const modespkg = @import("modes.zig");
const charsets = @import("charsets.zig");
const csi = @import("csi.zig");
const hyperlink = @import("hyperlink.zig");
const kitty = @import("kitty.zig");
const osc = @import("osc.zig");
const sgr = @import("sgr.zig");
const Tabstops = @import("Tabstops.zig");
const color = @import("color.zig");
const mouse_shape_pkg = @import("mouse_shape.zig");
const ReadonlyHandler = @import("stream_readonly.zig").Handler;
const ReadonlyStream = @import("stream_readonly.zig").Stream;

const size = @import("size.zig");
const pagepkg = @import("page.zig");
const style = @import("style.zig");
const Screen = @import("Screen.zig");
const ScreenSet = @import("ScreenSet.zig");
const Page = pagepkg.Page;
const Cell = pagepkg.Cell;
const Row = pagepkg.Row;

const log = std.log.scoped(.terminal);

/// Default tabstop interval
const TABSTOP_INTERVAL = 8;

/// The set of screens behind this terminal (e.g. primary vs alternate).
screens: ScreenSet,

/// Whether we're currently writing to the status line (DECSASD and DECSSDT).
/// We don't support a status line currently so we just black hole this
/// data so that it doesn't mess up our main display.
status_display: ansi.StatusDisplay = .main,

/// Where the tabstops are.
tabstops: Tabstops,

/// The size of the terminal.
rows: size.CellCountInt,
cols: size.CellCountInt,

/// The size of the screen in pixels. This is used for pty events and images
width_px: u32 = 0,
height_px: u32 = 0,

/// The current scrolling region.
scrolling_region: ScrollingRegion,

/// The last reported pwd, if any.
pwd: std.ArrayList(u8),

/// The color state for this terminal.
colors: Colors,

/// The previous printed character. This is used for the repeat previous
/// char CSI (ESC [ <n> b).
previous_char: ?u21 = null,

/// The modes that this terminal currently has active.
modes: modespkg.ModeState = .{},

/// The most recently set mouse shape for the terminal.
mouse_shape: mouse_shape_pkg.MouseShape = .text,

/// These are just a packed set of flags we may set on the terminal.
flags: packed struct {
    // This supports a Kitty extension where programs using semantic
    // prompts (OSC133) can annotate their new prompts with `redraw=0` to
    // disable clearing the prompt on resize.
    shell_redraws_prompt: osc.semantic_prompt.Redraw = .true,

    // This is set via ESC[4;2m. Any other modify key mode just sets
    // this to false and we act in mode 1 by default.
    modify_other_keys_2: bool = false,

    /// The mouse event mode and format. These are set to the last
    /// set mode in modes. You can't get the right event/format to use
    /// based on modes alone because modes don't show you what order
    /// this was called so we have to track it separately.
    mouse_event: MouseEvents = .none,
    mouse_format: MouseFormat = .x10,

    /// Set via the XTSHIFTESCAPE sequence. If true (XTSHIFTESCAPE = 1)
    /// then we want to capture the shift key for the mouse protocol
    /// if the configuration allows it.
    mouse_shift_capture: enum(u2) { null, false, true } = .null,

    /// True if the window is focused.
    focused: bool = true,

    /// True if the terminal is in a password entry mode. This is set
    /// to true based on termios state. This is set
    /// to true based on termios state.
    password_input: bool = false,

    /// True if the terminal should perform selection scrolling.
    selection_scroll: bool = false,

    /// Dirty flag used only by the search thread. The renderer is expected
    /// to set this to true if the viewport was dirty as it was rendering.
    /// This is used by the search thread to more efficiently re-search the
    /// viewport and active area.
    ///
    /// Since the renderer is going to inspect the viewport/active area ANYWAYS,
    /// this lets our search thread do less work and hold the lock less time,
    /// resulting in more throughput for everything.
    search_viewport_dirty: bool = false,

    /// Dirty flags for the renderer.
    dirty: Dirty = .{},
} = .{},

/// The various color configurations a terminal maintains and that can
/// be set dynamically via OSC, with defaults usually coming from a
/// configuration.
pub const Colors = struct {
    background: color.DynamicRGB,
    foreground: color.DynamicRGB,
    cursor: color.DynamicRGB,
    palette: color.DynamicPalette,

    pub const default: Colors = .{
        .background = .unset,
        .foreground = .unset,
        .cursor = .unset,
        .palette = .default,
    };
};

/// This is a set of dirty flags the renderer can use to determine
/// what parts of the screen need to be redrawn. It is up to the renderer
/// to clear these flags.
///
/// This only contains dirty flags for terminal state, not for the screen
/// state. The screen state has its own dirty flags.
pub const Dirty = packed struct {
    /// Set when the color palette is modified in any way.
    palette: bool = false,

    /// Set when the reverse colors mode is modified.
    reverse_colors: bool = false,

    /// Screen clear of some kind. This can be due to a screen change,
    /// erase display, etc.
    clear: bool = false,

    /// Set when the pre-edit is modified.
    preedit: bool = false,
};

/// The event types that can be reported for mouse-related activities.
/// These are all mutually exclusive (hence in a single enum).
pub const MouseEvents = enum(u3) {
    none = 0,
    x10 = 1, // 9
    normal = 2, // 1000
    button = 3, // 1002
    any = 4, // 1003

    /// Returns true if this event sends motion events.
    pub fn motion(self: MouseEvents) bool {
        return self == .button or self == .any;
    }
};

/// The format of mouse events when enabled.
/// These are all mutually exclusive (hence in a single enum).
pub const MouseFormat = enum(u3) {
    x10 = 0,
    utf8 = 1, // 1005
    sgr = 2, // 1006
    urxvt = 3, // 1015
    sgr_pixels = 4, // 1016
};

/// Scrolling region is the area of the screen designated where scrolling
/// occurs. When scrolling the screen, only this viewport is scrolled.
pub const ScrollingRegion = struct {
    // Top and bottom of the scroll region (0-indexed)
    // Precondition: top < bottom
    top: size.CellCountInt,
    bottom: size.CellCountInt,

    // Left/right scroll regions.
    // Precondition: right > left
    // Precondition: right <= cols - 1
    left: size.CellCountInt,
    right: size.CellCountInt,
};

pub const Options = struct {
    cols: size.CellCountInt,
    rows: size.CellCountInt,
    max_scrollback: usize = 10_000,
    colors: Colors = .default,

    /// The default mode state. When the terminal gets a reset, it
    /// will revert back to this state.
    default_modes: modespkg.ModePacked = .{},
};

/// Initialize a new terminal.
pub fn init(
    alloc: Allocator,
    opts: Options,
) !Terminal {
    const cols = opts.cols;
    const rows = opts.rows;

    var screen_set: ScreenSet = try .init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = opts.max_scrollback,
    });
    errdefer screen_set.deinit(alloc);

    return .{
        .cols = cols,
        .rows = rows,
        .screens = screen_set,
        .tabstops = try .init(alloc, cols, TABSTOP_INTERVAL),
        .scrolling_region = .{
            .top = 0,
            .bottom = rows - 1,
            .left = 0,
            .right = cols - 1,
        },
        .pwd = .empty,
        .colors = opts.colors,
        .modes = .{
            .values = opts.default_modes,
            .default = opts.default_modes,
        },
    };
}

pub fn deinit(self: *Terminal, alloc: Allocator) void {
    self.tabstops.deinit(alloc);
    self.screens.deinit(alloc);
    self.pwd.deinit(alloc);
    self.* = undefined;
}

/// Return a terminal.Stream that can process VT streams and update this
/// terminal state. The streams will only process read-only data that
/// modifies terminal state. Sequences that query or otherwise require
/// output will be ignored.
pub fn vtStream(self: *Terminal) ReadonlyStream {
    return .initAlloc(self.gpa(), self.vtHandler());
}

/// This is the handler-side only for vtStream.
pub fn vtHandler(self: *Terminal) ReadonlyHandler {
    return .init(self);
}

/// The general allocator we should use for this terminal.
fn gpa(self: *Terminal) Allocator {
    return self.screens.active.alloc;
}

/// Print UTF-8 encoded string to the terminal.
pub fn printString(self: *Terminal, str: []const u8) !void {
    const view = try std.unicode.Utf8View.init(str);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            '\n' => {
                self.carriageReturn();
                try self.linefeed();
            },

            else => try self.print(cp),
        }
    }
}

/// Print the previous printed character a repeated amount of times.
pub fn printRepeat(self: *Terminal, count_req: usize) !void {
    if (self.previous_char) |c| {
        const count = @max(count_req, 1);
        for (0..count) |_| try self.print(c);
    }
}

pub fn print(self: *Terminal, c: u21) !void {
    // log.debug("print={x} y={} x={}", .{ c, self.screens.active.cursor.y, self.screens.active.cursor.x });

    // If we're not on the main display, do nothing for now
    if (self.status_display != .main) {
        @branchHint(.cold);
        return;
    }

    // After doing any printing, wrapping, scrolling, etc. we want to ensure
    // that our screen remains in a consistent state.
    defer self.screens.active.assertIntegrity();

    // Our right margin depends where our cursor is now.
    const right_limit = if (self.screens.active.cursor.x > self.scrolling_region.right)
        self.cols
    else
        self.scrolling_region.right + 1;

    // Perform grapheme clustering if grapheme support is enabled (mode 2027).
    // This is MUCH slower than the normal path so the conditional below is
    // purposely ordered in least-likely to most-likely so we can drop out
    // as quickly as possible.
    if (c > 255 and
        self.modes.get(.grapheme_cluster) and
        self.screens.active.cursor.x > 0)
    grapheme: {
        @branchHint(.unlikely);
        // We need the previous cell to determine if we're at a grapheme
        // break or not. If we are NOT, then we are still combining the
        // same grapheme, and will be appending to prev.cell. Otherwise, we are
        // in a new cell.
        const Prev = struct { cell: *Cell, left: size.CellCountInt };
        var prev: Prev = prev: {
            const left: size.CellCountInt = left: {
                // If we have wraparound, then we use the prev col unless
                // there's a pending wrap, in which case we use the current.
                if (self.modes.get(.wraparound)) {
                    break :left @intFromBool(!self.screens.active.cursor.pending_wrap);
                }

                // If we do not have wraparound, the logic is trickier. If
                // we're not on the last column, then we just use the previous
                // column. Otherwise, we need to check if there is text to
                // figure out if we're attaching to the prev or current.
                if (self.screens.active.cursor.x != right_limit - 1) break :left 1;
                break :left @intFromBool(self.screens.active.cursor.page_cell.codepoint() == 0);
            };

            // If the previous cell is a wide spacer tail, then we actually
            // want to use the cell before that because that has the actual
            // content.
            const immediate = self.screens.active.cursorCellLeft(left);
            break :prev switch (immediate.wide) {
                else => .{ .cell = immediate, .left = left },
                .spacer_tail => .{
                    .cell = self.screens.active.cursorCellLeft(left + 1),
                    .left = left + 1,
                },
            };
        };

        // If our cell has no content, then this is a new cell and
        // necessarily a grapheme break.
        if (prev.cell.codepoint() == 0) break :grapheme;

        const grapheme_break = brk: {
            var state: uucode.grapheme.BreakState = .default;
            var cp1: u21 = prev.cell.content.codepoint;
            if (prev.cell.hasGrapheme()) {
                const cps = self.screens.active.cursor.page_pin.node.data.lookupGrapheme(prev.cell).?;
                for (cps) |cp2| {
                    // log.debug("cp1={x} cp2={x}", .{ cp1, cp2 });
                    assert(!unicode.graphemeBreak(cp1, cp2, &state));
                    cp1 = cp2;
                }
            }

            // log.debug("cp1={x} cp2={x} end", .{ cp1, c });
            break :brk unicode.graphemeBreak(cp1, c, &state);
        };

        // If we can NOT break, this means that "c" is part of a grapheme
        // with the previous char.
        if (!grapheme_break) {
            var desired_wide: enum { no_change, wide, narrow } = .no_change;

            // If this is an emoji variation selector then we need to modify
            // the cell width accordingly. VS16 makes the character wide and
            // VS15 makes it narrow.
            if (c == 0xFE0F or c == 0xFE0E) {
                const prev_props = unicode.table.get(prev.cell.content.codepoint);
                // Check if it is a valid variation sequence in
                // emoji-variation-sequences.txt, and if not, ignore the char.
                if (!prev_props.emoji_vs_base) return;

                switch (c) {
                    0xFE0F => desired_wide = .wide,
                    0xFE0E => desired_wide = .narrow,
                    else => unreachable,
                }
            } else if (!unicode.table.get(c).width_zero_in_grapheme) {
                // If we have a code point that contributes to the width of a
                // grapheme, it necessarily means that we're at least at width
                // 2, since the first code point must be at least width 1 to
                // start. (Note that Prepend code points could effectively mean
                // the first code point should be width 0, but we don't handle
                // that yet.)
                desired_wide = .wide;
            }

            switch (desired_wide) {
                .wide => wide: {
                    if (prev.cell.wide == .wide) break :wide;

                    // Move our cursor back to the previous. We'll move
                    // the cursor within this block to the proper location.
                    self.screens.active.cursorLeft(prev.left);

                    // If we don't have space for the wide char, we need to
                    // insert spacers and wrap. We need special handling if the
                    // previous cell has grapheme data.
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        if (!self.modes.get(.wraparound)) return;

                        // This path can write a spacer_head before printWrap
                        // which can trigger integrity violations so mark
                        // the wrap first to keep the intermediary state valid
                        // if we're wrapping.
                        const row_wrap = right_limit == self.cols;
                        if (row_wrap) self.screens.active.cursor.page_row.wrap = true;

                        const prev_cp = prev.cell.content.codepoint;
                        if (prev.cell.hasGrapheme()) {
                            // This is like printCell but without clearing the
                            // grapheme data from the cell, so we can move it
                            // later.
                            prev.cell.wide = if (row_wrap) .spacer_head else .narrow;
                            prev.cell.content.codepoint = 0;

                            try self.printWrap();
                            self.printCell(prev_cp, .wide);

                            const new_pin = self.screens.active.cursor.page_pin.*;
                            const new_rac = new_pin.rowAndCell();

                            transfer_graphemes: {
                                var old_pin = self.screens.active.cursor.page_pin.up(1) orelse break :transfer_graphemes;
                                old_pin.x = right_limit - 1;
                                const old_rac = old_pin.rowAndCell();

                                if (new_pin.node == old_pin.node) {
                                    new_pin.node.data.moveGrapheme(prev.cell, new_rac.cell);
                                    prev.cell.content_tag = .codepoint;
                                    new_rac.cell.content_tag = .codepoint_grapheme;
                                    new_rac.row.grapheme = true;
                                } else {
                                    const cps = old_pin.node.data.lookupGrapheme(old_rac.cell).?;
                                    for (cps) |cp| {
                                        try self.screens.active.appendGrapheme(new_rac.cell, cp);
                                    }
                                    old_pin.node.data.clearGrapheme(old_rac.cell);
                                }

                                old_pin.node.data.updateRowGraphemeFlag(old_rac.row);
                            }

                            // Point prev.cell to our new previous cell that
                            // we'll be appending graphemes to
                            prev.cell = new_rac.cell;
                        } else {
                            self.printCell(
                                0,
                                if (row_wrap) .spacer_head else .narrow,
                            );
                            try self.printWrap();
                            self.printCell(prev_cp, .wide);

                            // Point prev.cell to our new previous cell that
                            // we'll be appending graphemes to
                            prev.cell = self.screens.active.cursor.page_cell;
                        }
                    } else {
                        prev.cell.wide = .wide;
                    }

                    // Write our spacer, since prev.cell is now wide
                    self.screens.active.cursorRight(1);
                    self.printCell(0, .spacer_tail);

                    // Move the cursor again so we're beyond our spacer
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        self.screens.active.cursor.pending_wrap = true;
                    } else {
                        self.screens.active.cursorRight(1);
                    }
                },

                .narrow => narrow: {
                    // Prev cell is no longer wide
                    if (prev.cell.wide != .wide) break :narrow;
                    prev.cell.wide = .narrow;

                    // Remove the wide spacer tail
                    const cell = self.screens.active.cursorCellLeft(prev.left - 1);
                    cell.wide = .narrow;

                    // Back track the cursor so that we don't end up with
                    // an extra space after the character. Since xterm is
                    // not VS aware, it cannot be used as a reference for
                    // this behavior; but it does follow the principle of
                    // least surprise, and also matches the behavior that
                    // can be observed in Kitty, which is one of the only
                    // other VS aware terminals.
                    if (self.screens.active.cursor.x == right_limit - 1) {
                        // If we're already at the right edge, we stay
                        // here and set the pending wrap to false since
                        // when we pend a wrap, we only move our cursor once
                        // even for wide chars (tests verify).
                        self.screens.active.cursor.pending_wrap = false;
                    } else {
                        // Otherwise, move back.
                        self.screens.active.cursorLeft(1);
                    }

                    break :narrow;
                },

                else => {},
            }

            log.debug("c={X} grapheme attach to left={} primary_cp={X}", .{
                c,
                prev.left,
                prev.cell.codepoint(),
            });
            self.screens.active.cursorMarkDirty();
            try self.screens.active.appendGrapheme(prev.cell, c);
            return;
        }
    }

    // Determine the width of this character so we can handle
    // non-single-width characters properly. We have a fast-path for
    // byte-sized characters since they're so common. We can ignore
    // control characters because they're always filtered prior.
    const width: usize = if (c <= 0xFF) 1 else @intCast(unicode.table.get(c).width);

    // Note: it is possible to have a width of "3" and a width of "-1" from
    // uucode.x's wcwidth. We should look into those cases and handle them
    // appropriately.
    assert(width <= 2);
    // log.debug("c={x} width={}", .{ c, width });

    // Attach zero-width characters to our cell as grapheme data.
    if (width == 0) {
        @branchHint(.unlikely);
        // If we have grapheme clustering enabled, we don't blindly attach
        // any zero width character to our cells and we instead just ignore
        // it.
        if (self.modes.get(.grapheme_cluster)) return;

        // If we're at cell zero, then this is malformed data and we don't
        // print anything or even store this. Zero-width characters are ALWAYS
        // attached to some other non-zero-width character at the time of
        // writing.
        if (self.screens.active.cursor.x == 0) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // Find our previous cell
        const prev = prev: {
            const immediate = self.screens.active.cursorCellLeft(1);
            if (immediate.wide != .spacer_tail) break :prev immediate;
            break :prev self.screens.active.cursorCellLeft(2);
        };

        // If our previous cell has no text, just ignore the zero-width character
        if (!prev.hasText()) {
            log.warn("zero-width character with no prior character, ignoring", .{});
            return;
        }

        // If this is a emoji variation selector, prev must be an emoji
        if (c == 0xFE0F or c == 0xFE0E) {
            const prev_props = unicode.table.get(prev.content.codepoint);
            const emoji = prev_props.grapheme_break == .extended_pictographic;
            if (!emoji) return;
        }

        try self.screens.active.appendGrapheme(prev, c);
        return;
    }

    // We have a printable character, save it
    self.previous_char = c;

    // If we're soft-wrapping, then handle that first.
    if (self.screens.active.cursor.pending_wrap and self.modes.get(.wraparound)) {
        try self.printWrap();
    }

    // If we have insert mode enabled then we need to handle that. We
    // only do insert mode if we're not at the end of the line.
    if (self.modes.get(.insert) and
        self.screens.active.cursor.x + width < self.cols)
    {
        self.insertBlanks(width);
    }

    switch (width) {
        // Single cell is very easy: just write in the cell
        1 => {
            @branchHint(.likely);
            self.screens.active.cursorMarkDirty();
            @call(.always_inline, printCell, .{ self, c, .narrow });
        },

        // Wide character requires a spacer. We print this by
        // using two cells: the first is flagged "wide" and has the
        // wide char. The second is guaranteed to be a spacer if
        // we're not at the end of the line.
        2 => if ((right_limit - self.scrolling_region.left) > 1) {
            // If we don't have space for the wide char, we need
            // to insert spacers and wrap. Then we just print the wide
            // char as normal.
            if (self.screens.active.cursor.x == right_limit - 1) {
                // If we don't have wraparound enabled then we don't print
                // this character at all and don't move the cursor. This is
                // how xterm behaves.
                if (!self.modes.get(.wraparound)) return;

                // We only create a spacer head if we're at the real edge
                // of the screen. Otherwise, we clear the space with a narrow.
                // This allows soft wrapping to work correctly.
                if (right_limit == self.cols) {
                    // Special-case: we need to set wrap to true even
                    // though we call printWrap below because if there is
                    // a page resize during printCell then it'll fail
                    // integrity checks.
                    self.screens.active.cursor.page_row.wrap = true;
                    self.printCell(0, .spacer_head);
                } else {
                    self.printCell(0, .narrow);
                }
                try self.printWrap();
            }

            self.screens.active.cursorMarkDirty();
            self.printCell(c, .wide);
            self.screens.active.cursorRight(1);
            self.printCell(0, .spacer_tail);
        } else {
            // This is pretty broken, terminals should never be only 1-wide.
            // We should prevent this downstream.
            self.screens.active.cursorMarkDirty();
            self.printCell(0, .narrow);
        },

        else => unreachable,
    }

    // If we're at the column limit, then we need to wrap the next time.
    // In this case, we don't move the cursor.
    if (self.screens.active.cursor.x == right_limit - 1) {
        self.screens.active.cursor.pending_wrap = true;
        return;
    }

    // Move the cursor
    self.screens.active.cursorRight(1);
}

fn printCell(
    self: *Terminal,
    unmapped_c: u21,
    wide: Cell.Wide,
) void {
    defer self.screens.active.assertIntegrity();

    // TODO: spacers should use a bgcolor only cell

    const c: u21 = c: {
        // TODO: non-utf8 handling, gr

        // If we're single shifting, then we use the key exactly once.
        const key = if (self.screens.active.charset.single_shift) |key_once| blk: {
            self.screens.active.charset.single_shift = null;
            break :blk key_once;
        } else self.screens.active.charset.gl;

        const set = self.screens.active.charset.charsets.get(key);

        // UTF-8 or ASCII is used as-is
        if (set == .utf8 or set == .ascii) {
            @branchHint(.likely);
            break :c unmapped_c;
        }

        // If we're outside of ASCII range this is an invalid value in
        // this table so we just return space.
        if (unmapped_c > std.math.maxInt(u8)) break :c ' ';

        // Get our lookup table and map it
        const table = charsets.table(set);
        break :c @intCast(table[@intCast(unmapped_c)]);
    };

    const cell = self.screens.active.cursor.page_cell;

    // If the wide property of this cell is the same, then we don't
    // need to do the special handling here because the structure will
    // be the same. If it is NOT the same, then we may need to clear some
    // cells.
    if (cell.wide != wide) {
        switch (cell.wide) {
            // Previous cell was narrow. Do nothing.
            .narrow => {},

            // Previous cell was wide. We need to clear the tail and head.
            .wide => wide: {
                if (self.screens.active.cursor.x >= self.cols - 1) break :wide;

                const spacer_cell = self.screens.active.cursorCellRight(1);
                self.screens.active.clearCells(
                    &self.screens.active.cursor.page_pin.node.data,
                    self.screens.active.cursor.page_row,
                    spacer_cell[0..1],
                );

                // If we're near the left edge, a wide char may have
                // wrapped from the previous row, leaving a spacer_head
                // at the end of that row. Clear it so the previous row
                // doesn't keep a stale spacer_head.
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    if (head_cell.wide == .spacer_head) head_cell.wide = .narrow;
                }
            },

            .spacer_tail => {
                assert(self.screens.active.cursor.x > 0);

                // So integrity checks pass. We fix this up later so we don't
                // need to do this without safety checks.
                if (comptime std.debug.runtime_safety) {
                    cell.wide = .narrow;
                }

                const wide_cell = self.screens.active.cursorCellLeft(1);
                self.screens.active.clearCells(
                    &self.screens.active.cursor.page_pin.node.data,
                    self.screens.active.cursor.page_row,
                    wide_cell[0..1],
                );
                // If we're near the left edge, a wide char may have
                // wrapped from the previous row, leaving a spacer_head
                // at the end of that row. Clear it so the previous row
                // doesn't keep a stale spacer_head.
                if (self.screens.active.cursor.y > 0 and self.screens.active.cursor.x <= 1) {
                    const head_cell = self.screens.active.cursorCellEndOfPrev();
                    if (head_cell.wide == .spacer_head) head_cell.wide = .narrow;
                }
            },

            // TODO: this case was not handled in the old terminal implementation
            // but it feels like we should do something. investigate other
            // terminals (xterm mainly) and see what's up.
            .spacer_head => {},
        }
    }

    // If the prior value had graphemes, clear those
    if (cell.hasGrapheme()) {
        const page = &self.screens.active.cursor.page_pin.node.data;
        page.clearGrapheme(cell);
        page.updateRowGraphemeFlag(self.screens.active.cursor.page_row);
    }

    // We don't need to update the style refs unless the
    // cell's new style will be different after writing.
    const style_changed = cell.style_id != self.screens.active.cursor.style_id;
    if (style_changed) {
        var page = &self.screens.active.cursor.page_pin.node.data;

        // Release the old style.
        if (cell.style_id != style.default_id) {
            assert(self.screens.active.cursor.page_row.styled);
            page.styles.release(page.memory, cell.style_id);
        }
    }

    // Keep track if we had a hyperlink so we can unset it.
    const had_hyperlink = cell.hyperlink;

    // Write
    cell.* = .{
        .content_tag = .codepoint,
        .content = .{ .codepoint = c },
        .style_id = self.screens.active.cursor.style_id,
        .wide = wide,
        .protected = self.screens.active.cursor.protected,
        .semantic_content = self.screens.active.cursor.semantic_content,
    };

    if (style_changed) {
        var page = &self.screens.active.cursor.page_pin.node.data;

        // Use the new style.
        if (cell.style_id != style.default_id) {
            page.styles.use(page.memory, cell.style_id);
            self.screens.active.cursor.page_row.styled = true;
        }
    }

    // If this is a Kitty unicode placeholder then we need to mark the
    // row so that the renderer can lookup rows with these much faster.
    if (comptime build_options.kitty_graphics) {
        if (c == kitty.graphics.unicode.placeholder) {
            @branchHint(.unlikely);
            self.screens.active.cursor.page_row.kitty_virtual_placeholder = true;
        }
    }

    // We check for an active hyperlink first because setHyperlink
    // handles clearing the old hyperlink and an optimization if we're
    // overwriting the same hyperlink.
    if (self.screens.active.cursor.hyperlink_id > 0) {
        self.screens.active.cursorSetHyperlink() catch |err| {
            @branchHint(.unlikely);
            log.warn("error reallocating for more hyperlink space, ignoring hyperlink err={}", .{err});
            assert(!cell.hyperlink);
        };
    } else if (had_hyperlink) {
        // If the previous cell had a hyperlink then we need to clear it.
        var page = &self.screens.active.cursor.page_pin.node.data;
        page.clearHyperlink(cell);
        page.updateRowHyperlinkFlag(self.screens.active.cursor.page_row);
    }
}

fn printWrap(self: *Terminal) !void {
    // We only mark that we soft-wrapped if we're at the edge of our
    // full screen. We don't mark the row as wrapped if we're in the
    // middle due to a right margin.
    const cursor: *Screen.Cursor = &self.screens.active.cursor;
    const mark_wrap = cursor.x == self.cols - 1;
    if (mark_wrap) cursor.page_row.wrap = true;

    // Get the old semantic prompt so we can extend it to the next
    // line. We need to do this before we index() because we may
    // modify memory.
    const old_semantic = cursor.semantic_content;
    const old_semantic_clear = cursor.semantic_content_clear_eol;

    // Move to the next line
    try self.index();
    self.screens.active.cursorHorizontalAbsolute(self.scrolling_region.left);

    // Our pointer should never move
    assert(cursor == &self.screens.active.cursor);

    // We always reset our semantic prompt state
    cursor.semantic_content = old_semantic;
    cursor.semantic_content_clear_eol = old_semantic_clear;
    switch (old_semantic) {
        .output, .input => {},
        .prompt => cursor.page_row.semantic_prompt = .prompt_continuation,
    }

    if (mark_wrap) {
        const row = self.screens.active.cursor.page_row;
        // Always mark the row as a continuation
        row.wrap_continuation = true;
    }

    // Assure that our screen is consistent
    self.screens.active.assertIntegrity();
}

/// Set the charset into the given slot.
pub fn configureCharset(self: *Terminal, slot: charsets.Slots, set: charsets.Charset) void {
    self.screens.active.charset.charsets.set(slot, set);
}

/// Invoke the charset in slot into the active slot. If single is true,
/// then this will only be invoked for a single character.
pub fn invokeCharset(
    self: *Terminal,
    active: charsets.ActiveSlot,
    slot: charsets.Slots,
    single: bool,
) void {
    if (single) {
        assert(active == .GL);
        self.screens.active.charset.single_shift = slot;
        return;
    }

    switch (active) {
        .GL => self.screens.active.charset.gl = slot,
        .GR => self.screens.active.charset.gr = slot,
    }
}

/// Carriage return moves the cursor to the first column.
pub fn carriageReturn(self: *Terminal) void {
    // Always reset pending wrap state
    self.screens.active.cursor.pending_wrap = false;

    // In origin mode we always move to the left margin
    self.screens.active.cursorHorizontalAbsolute(if (self.modes.get(.origin))
        self.scrolling_region.left
    else if (self.screens.active.cursor.x >= self.scrolling_region.left)
        self.scrolling_region.left
    else
        0);
}

/// Linefeed moves the cursor to the next line.
pub fn linefeed(self: *Terminal) !void {
    try self.index();
    if (self.modes.get(.linefeed)) self.carriageReturn();
}

/// Backspace moves the cursor back a column (but not less than 0).
pub fn backspace(self: *Terminal) void {
    self.cursorLeft(1);
}

/// Move the cursor up amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. If amount is
/// 0, adjust it to 1.
pub fn cursorUp(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The maximum amount the cursor can move up depends on scrolling regions
    const max = if (self.screens.active.cursor.y >= self.scrolling_region.top)
        self.screens.active.cursor.y - self.scrolling_region.top
    else
        self.screens.active.cursor.y;
    const count = @min(max, @max(count_req, 1));

    // We can safely intCast below because of the min/max clamping we did above.
    self.screens.active.cursorUp(@intCast(count));
}

/// Move the cursor down amount lines. If amount is greater than the maximum
/// move distance then it is internally adjusted to the maximum. This sequence
/// will not scroll the screen or scroll region. If amount is 0, adjust it to 1.
pub fn cursorDown(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screens.active.cursor.y <= self.scrolling_region.bottom)
        self.scrolling_region.bottom - self.screens.active.cursor.y
    else
        self.rows - self.screens.active.cursor.y - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorDown(@intCast(count));
}

/// Move the cursor right amount columns. If amount is greater than the
/// maximum move distance then it is internally adjusted to the maximum.
/// This sequence will not scroll the screen or scroll region. If amount is
/// 0, adjust it to 1.
pub fn cursorRight(self: *Terminal, count_req: usize) void {
    // Always resets pending wrap
    self.screens.active.cursor.pending_wrap = false;

    // The max the cursor can move to depends where the cursor currently is
    const max = if (self.screens.active.cursor.x <= self.scrolling_region.right)
        self.scrolling_region.right - self.screens.active.cursor.x
    else
        self.cols - self.screens.active.cursor.x - 1;
    const count = @min(max, @max(count_req, 1));
    self.screens.active.cursorRight(@intCast(count));
}

/// Move the cursor to the left amount cells. If amount is 0, adjust it to 1.
pub fn cursorLeft(self: *Terminal, count_req: usize) void {
    // Wrapping behavior depends on various terminal modes
    const WrapMode = enum { none, reverse, reverse_extended };
    const wrap_mode: WrapMode = wrap_mode: {
        if (!self.modes.get(.wraparound)) break :wrap_mode .none;
        if (self.modes.get(.reverse_wrap_extended)) break :wrap_mode .reverse_extended;
        if (self.modes.get(.reverse_wrap)) break :wrap_mode .reverse;
        break :wrap_mode .none;
    };

    var count = @max(count_req, 1);

    // If we are in no wrap mode, then we move the cursor left and exit
    // since this is the fastest and most typical path.
    if (wrap_mode == .none) {
        self.screens.active.cursorLeft(@min(count, self.screens.active.cursor.x));
        self.screens.active.cursor.pending_wrap = false;
        return;
    }

    // If we have a pending wrap state and we are in either reverse wrap
    // modes then we decrement the amount we move by one to match xterm.
    if (self.screens.active.cursor.pending_wrap) {
        count -= 1;
        self.screens.active.cursor.pending_wrap = false;
    }

    // The margins we can move to.
    const top = self.scrolling_region.top;
    const bottom = self.scrolling_region.bottom;
    const right_margin = self.scrolling_region.right;
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;

    // Handle some edge cases when our cursor is already on the left margin.
    if (self.screens.active.cursor.x == left_margin) {
        switch (wrap_mode) {
            // In reverse mode, if we're already before the top margin
            // then we just set our cursor to the top-left and we're done.
            .reverse => if (self.screens.active.cursor.y <= top) {
                self.screens.active.cursorAbsolute(left_margin, top);
                return;
            },

            // Handled in while loop
            .reverse_extended => {},

            // Handled above
            .none => unreachable,
        }
    }

    while (true) {
        // We can move at most to the left margin.
        const max = self.screens.active.cursor.x - left_margin;

        // We want to move at most the number of columns we have left
        // or our remaining count. Do the move.
        const amount = @min(max, count);
        count -= amount;
        self.screens.active.cursorLeft(amount);

        // If we have no more to move, then we're done.
        if (count == 0) break;

        // If we are at the top, then we are done.
        if (self.screens.active.cursor.y == top) {
            if (wrap_mode != .reverse_extended) break;

            self.screens.active.cursorAbsolute(right_margin, bottom);
            count -= 1;
            continue;
        }

        // UNDEFINED TERMINAL BEHAVIOR. This situation is not handled in xterm
        // and currently results in a crash in xterm. Given no other known
        // terminal [to me] implements XTREVWRAP2, I decided to just mimic
        // the behavior of xterm up and not including the crash by wrapping
        // up to the (0, 0) and stopping there. My reasoning is that for an
        // appropriately sized value of "count" this is the behavior that xterm
        // would have. This is unit tested.
        if (self.screens.active.cursor.y == 0) {
            assert(self.screens.active.cursor.x == left_margin);
            break;
        }

        // If our previous line is not wrapped then we are done.
        if (wrap_mode != .reverse_extended) {
            const prev_row = self.screens.active.cursorRowUp(1);
            if (!prev_row.wrap) break;
        }

        self.screens.active.cursorAbsolute(right_margin, self.screens.active.cursor.y - 1);
        count -= 1;
    }
}

/// Save cursor position and further state.
///
/// The primary and alternate screen have distinct save state. One saved state
/// is kept per screen (main / alternative). If for the current screen state
/// was already saved it is overwritten.
pub fn saveCursor(self: *Terminal) void {
    self.screens.active.saved_cursor = .{
        .x = self.screens.active.cursor.x,
        .y = self.screens.active.cursor.y,
        .style = self.screens.active.cursor.style,
        .protected = self.screens.active.cursor.protected,
        .pending_wrap = self.screens.active.cursor.pending_wrap,
        .origin = self.modes.get(.origin),
        .charset = self.screens.active.charset,
    };
}

/// Restore cursor position and other state.
///
/// The primary and alternate screen have distinct save state.
/// If no save was done before values are reset to their initial values.
pub fn restoreCursor(self: *Terminal) void {
    const saved: Screen.SavedCursor = self.screens.active.saved_cursor orelse .{
        .x = 0,
        .y = 0,
        .style = .{},
        .protected = false,
        .pending_wrap = false,
        .origin = false,
        .charset = .{},
    };

    // Set the style first because it can fail
    self.screens.active.cursor.style = saved.style;
    self.screens.active.manualStyleUpdate() catch |err| {
        // Regardless of the error here, we revert back to an unstyled
        // cursor. It is more important that the restore succeeds in
        // other attributes because terminals have no way to communicate
        // failure back.
        log.warn("restoreCursor error updating style err={}", .{err});
        const screen: *Screen = self.screens.active;
        screen.cursor.style = .{};
        self.screens.active.manualStyleUpdate() catch unreachable;
    };

    self.screens.active.charset = saved.charset;
    self.modes.set(.origin, saved.origin);
    self.screens.active.cursor.pending_wrap = saved.pending_wrap;
    self.screens.active.cursor.protected = saved.protected;
    self.screens.active.cursorAbsolute(
        @min(saved.x, self.cols - 1),
        @min(saved.y, self.rows - 1),
    );

    // Ensure our screen is consistent
    self.screens.active.assertIntegrity();
}

/// Set the character protection mode for the terminal.
pub fn setProtectedMode(self: *Terminal, mode: ansi.ProtectedMode) void {
    switch (mode) {
        .off => {
            self.screens.active.cursor.protected = false;

            // screen.protected_mode is NEVER reset to ".off" because
            // logic such as eraseChars depends on knowing what the
            // _most recent_ mode was.
        },

        .iso => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .iso;
        },

        .dec => {
            self.screens.active.cursor.protected = true;
            self.screens.active.protected_mode = .dec;
        },
    }
}

/// Perform a semantic prompt command.
///
/// If there is an error, we do our best to get the terminal into
/// some coherent state, since callers typically can't handle errors
/// (since they're sending sequences via the pty).
pub fn semanticPrompt(
    self: *Terminal,
    cmd: osc.Command.SemanticPrompt,
) !void {
    switch (cmd.action) {
        .fresh_line => try self.semanticPromptFreshLine(),

        .fresh_line_new_prompt => {
            // "First do a fresh-line."
            try self.semanticPromptFreshLine();

            const screen: *Screen = self.screens.active;

            // "Subsequent text (until a OSC "133;B" or OSC "133;I" command)
            // is a prompt string (as if followed by OSC 133;P;k=i\007)."
            screen.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });

            // This is a kitty-specific flag that notes that the shell
            // is NOT capable of redraw. Redraw defaults to true so this
            // usually just disables it, but either is possible.
            if (cmd.readOption(.redraw)) |v| {
                self.flags.shell_redraws_prompt = v;
            }

            click: {
                // Handle click_events as a priority over cl. click_events
                // is another Kitty-specific extension that converts clicks
                // within a prompt area to SGR mouse events and defers to the
                // shell to handle them.
                if (cmd.readOption(.click_events)) |v| {
                    if (v) {
                        screen.semantic_prompt.click = .click_events;
                        break :click;
                    }
                }

                // If click_events was not set or disabled, fallback to `cl`.
                if (cmd.readOption(.cl)) |v| {
                    screen.semantic_prompt.click = .{ .cl = v };
                }
            }

            // The "aid" and "cl" options are also valid for this
            // command but we don't yet handle these in any meaningful way.
        },

        .new_command => {
            // Spec:
            // Same as OSC "133;A" but may first implicitly terminate a
            // previous command: if the options specify an aid and there
            // is an active (open) command with matching aid, finish the
            // innermost such command (as well as any other commands
            // nested more deeply). If no aid is specified, treat as an
            // aid whose value is the empty string.

            // Ghostty:
            // We don't currently do explicit command tracking in any way
            // so there is no need to terminate prior commands. We just
            // perform the `A` action.
            try self.semanticPrompt(.{
                .action = .fresh_line_new_prompt,
                .options_unvalidated = cmd.options_unvalidated,
            });
        },

        .prompt_start => {
            // Explicit start of prompt. Optional after an A or N command.
            // The k (kind) option specifies the type of prompt:
            // regular primary prompt (k=i or default),
            // right-side prompts (k=r), or prompts for continuation lines (k=c or k=s).
            self.screens.active.cursorSetSemanticContent(.{
                .prompt = cmd.readOption(.prompt_kind) orelse .initial,
            });
        },

        .end_prompt_start_input => {
            // End of prompt and start of user input, terminated by a OSC
            // "133;C" or another prompt (OSC "133;P").
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_explicit,
            });
        },

        .end_prompt_start_input_terminate_eol => {
            // End of prompt and start of user input, terminated by end-of-line.
            self.screens.active.cursorSetSemanticContent(.{
                .input = .clear_eol,
            });
        },

        .end_input_start_output => {
            // "End of input, and start of output."
            self.screens.active.cursorSetSemanticContent(.output);

            // If our current row is marked as a prompt and we're
            // at column zero then we assume we're un-prompting. This
            // is a heuristic to deal with fish, mostly. The issue that
            // fish brings up is that it has no PS2 equivalent and its
            // builtin OSC133 marking doesn't output continuation lines
            // as k=s. So, we assume when we get a newline with a prompt
            // cursor that the new line is also a prompt. But fish changes
            // to output on the newline. So if we're at col 0 we just assume
            // we're overwriting the prompt.
            if (self.screens.active.cursor.page_row.semantic_prompt != .none and
                self.screens.active.cursor.x == 0)
            {
                self.screens.active.cursor.page_row.semantic_prompt = .none;
            }
        },

        .end_command => {
            // From a terminal state perspective, this doesn't really do
            // anything. Other terminals appear to do nothing here. I think
            // its reasonable at this point to reset our semantic content
            // state but the spec doesn't really say what to do.
            self.screens.active.cursorSetSemanticContent(.output);
        },
    }
}

// OSC 133;L
fn semanticPromptFreshLine(self: *Terminal) !void {
    const left_margin = if (self.screens.active.cursor.x < self.scrolling_region.left)
        0
    else
        self.scrolling_region.left;

    // Spec: "If the cursor is the initial column (left, assuming
    // left-to-right writing), do nothing" This specification is very under
    // specified. We are taking the liberty to assume that in a left/right
    // margin context, if the cursor is outside of the left margin, we treat
    // it as being at the left margin for the purposes of this command.
    // This is arbitrary. If someone has a better reasonable idea we can
    // apply it.
    if (self.screens.active.cursor.x == left_margin) return;

    self.carriageReturn();
    try self.index();
}

/// The semantic prompt type. This is used when tracking a line type and
/// requires integration with the shell. By default, we mark a line as "none"
/// meaning we don't know what type it is.
///
/// See: https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
pub const SemanticPrompt = enum {
    prompt,
    prompt_continuation,
    input,
    command,
};

/// Returns true if the cursor is currently at a prompt. Another way to look
/// at this is it returns false if the shell is currently outputting something.
/// This requires shell integration (semantic prompt integration).
///
/// If the shell integration doesn't exist, this will always return false.
pub fn cursorIsAtPrompt(self: *Terminal) bool {
    // If we're on the secondary screen, we're never at a prompt.
    if (self.screens.active_key == .alternate) return false;

    // If our page row is a prompt then we're always at a prompt
    const cursor: *const Screen.Cursor = &self.screens.active.cursor;
    if (cursor.page_row.semantic_prompt != .none) return true;

    // Otherwise, determine our cursor state
    return switch (cursor.semantic_content) {
        .input, .prompt => true,
        .output => false,
    };
}

/// Viewport row where the current prompt starts, measured from the top of the
/// visible screen. Nil when the cursor is not at a prompt, the alternate
/// screen is active, or the prompt is outside the viewport.
pub fn promptViewportRow(self: *Terminal) ?u32 {
    if (self.screens.active_key == .alternate) return null;
    if (!self.cursorIsAtPrompt()) return null;
    const screen = self.screens.active;
    var iterator = screen.cursor.page_pin.promptIterator(.left_up, null);
    const prompt = iterator.next() orelse return null;
    const located = screen.pages.pointFromPin(.viewport, prompt) orelse return null;
    const y = located.coord().y;
    if (y >= @as(u32, self.rows)) return null;
    return y;
}

/// Horizontal tab moves the cursor to the next tabstop, clearing
/// the screen to the left the tabstop.
pub fn horizontalTab(self: *Terminal) void {
    while (self.screens.active.cursor.x < self.scrolling_region.right) {
        // Move the cursor right
        self.screens.active.cursorRight(1);

        // If the last cursor position was a tabstop we return. We do
        // "last cursor position" because we want a space to be written
        // at the tabstop unless we're at the end (the while condition).
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}

// Same as horizontalTab but moves to the previous tabstop instead of the next.
pub fn horizontalTabBack(self: *Terminal) void {
    // With origin mode enabled, our leftmost limit is the left margin.
    const left_limit = if (self.modes.get(.origin)) self.scrolling_region.left else 0;

    while (true) {
        // If we're already at the edge of the screen, then we're done.
        if (self.screens.active.cursor.x <= left_limit) return;

        // Move the cursor left
        self.screens.active.cursorLeft(1);
        if (self.tabstops.get(self.screens.active.cursor.x)) return;
    }
}

/// Clear tab stops.
pub fn tabClear(self: *Terminal, cmd: csi.TabClear) void {
    switch (cmd) {
        .current => self.tabstops.unset(self.screens.active.cursor.x),
        .all => self.tabstops.reset(0),
        else => log.warn("invalid or unknown tab clear setting: {}", .{cmd}),
    }
}

/// Set a tab stop on the current cursor.
/// TODO: test
pub fn tabSet(self: *Terminal) void {
    self.tabstops.set(self.screens.active.cursor.x);
}

/// TODO: test
pub fn tabReset(self: *Terminal) void {
    self.tabstops.reset(TABSTOP_INTERVAL);
}

/// Move the cursor to the next line in the scrolling region, possibly scrolling.
///
/// If the cursor is outside of the scrolling region: move the cursor one line
/// down if it is not on the bottom-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///   If the cursor is on the bottom-most line of the scrolling region:
///     invoke scroll up with amount=1
///   If the cursor is not on the bottom-most line of the scrolling region:
///     move the cursor one line down
///
/// This unsets the pending wrap state without wrapping.
pub fn index(self: *Terminal) !void {
    const screen: *Screen = self.screens.active;

    // Unset pending wrap state
    screen.cursor.pending_wrap = false;

    // We handle our cursor semantic prompt state AFTER doing the
    // scrolling, because we may need to apply to new rows.
    defer if (screen.cursor.semantic_content != .output) {
        @branchHint(.unlikely);

        // Always reset any semantic content clear-eol state.
        //
        // The specification is not clear what "end-of-line" means. If we
        // discover that there are more scenarios we should be unsetting
        // this we should document and test it.
        if (screen.cursor.semantic_content_clear_eol) {
            screen.cursor.semantic_content = .output;
            screen.cursor.semantic_content_clear_eol = false;
        } else {
            // If we aren't clearing our state at EOL and we're not output,
            // then we mark the new row as a prompt continuation. This is
            // to work around shells that don't send OSC 133 k=s sequences
            // for continuations.
            //
            // This can be a false positive if the shell changes content
            // type later and outputs something. We handle that in the
            // semanticPrompt function.
            screen.cursor.page_row.semantic_prompt = .prompt_continuation;
        }
    } else {
        // This should never be set in the output mode.
        assert(!screen.cursor.semantic_content_clear_eol);
    };

    // Outside of the scroll region we move the cursor one line down.
    if (screen.cursor.y < self.scrolling_region.top or
        screen.cursor.y > self.scrolling_region.bottom)
    {
        // We only move down if we're not already at the bottom of
        // the screen.
        if (screen.cursor.y < self.rows - 1) {
            screen.cursorDown(1);
        }

        return;
    }

    // If the cursor is inside the scrolling region and on the bottom-most
    // line, then we scroll up. If our scrolling region is the full screen
    // we create scrollback.
    if (screen.cursor.y == self.scrolling_region.bottom and
        screen.cursor.x >= self.scrolling_region.left and
        screen.cursor.x <= self.scrolling_region.right)
    {
        if (comptime build_options.kitty_graphics) {
            // Scrolling dirties the images because it updates their placements pins.
            screen.kitty_images.dirty = true;
        }

        // If our scrolling region is at the top, we create scrollback.
        if (self.scrolling_region.top == 0 and
            self.scrolling_region.left == 0 and
            self.scrolling_region.right == self.cols - 1)
        {
            try screen.cursorScrollAbove();
            return;
        }

        // Slow path for left and right scrolling region margins.
        if (self.scrolling_region.left != 0 or
            self.scrolling_region.right != self.cols - 1 or

            // PERF(mitchellh): If we have an SGR background set then
            // we need to preserve that background in our erased rows.
            // scrollUp does that but eraseRowBounded below does not.
            // However, scrollUp is WAY slower. We should optimize this
            // case to work in the eraseRowBounded codepath and remove
            // this check.
            !screen.blankCell().isZero())
        {
            try self.scrollUp(1);
            return;
        }

        // Otherwise use a fast path function from PageList to efficiently
        // scroll the contents of the scrolling region.

        // Preserve old cursor just for assertions
        const old_cursor = screen.cursor;

        try screen.pages.eraseRowBounded(
            .{ .active = .{ .y = self.scrolling_region.top } },
            self.scrolling_region.bottom - self.scrolling_region.top,
        );

        // eraseRow and eraseRowBounded will end up moving the cursor pin
        // up by 1, so we need to move it back down. A `cursorReload`
        // would be better option but this is more efficient and this is
        // a super hot path so we do this instead.
        assert(screen.cursor.x == old_cursor.x);
        assert(screen.cursor.y == old_cursor.y);
        screen.cursor.y -= 1;
        screen.cursorDown(1);

        // The operations above can prune our cursor style so we need to
        // update. This should never fail because the above can only FREE
        // memory.
        screen.manualStyleUpdate() catch |err| {
            std.log.warn("deleteLines manualStyleUpdate err={}", .{err});
            screen.cursor.style = .{};
            screen.manualStyleUpdate() catch unreachable;
        };

        return;
    }

    // Increase cursor by 1, maximum to bottom of scroll region
    if (screen.cursor.y < self.scrolling_region.bottom) {
        screen.cursorDown(1);
    }
}

/// Move the cursor to the previous line in the scrolling region, possibly
/// scrolling.
///
/// If the cursor is outside of the scrolling region, move the cursor one
/// line up if it is not on the top-most line of the screen.
///
/// If the cursor is inside the scrolling region:
///
///   * If the cursor is on the top-most line of the scrolling region:
///     invoke scroll down with amount=1
///   * If the cursor is not on the top-most line of the scrolling region:
///     move the cursor one line up
pub fn reverseIndex(self: *Terminal) void {
    if (self.screens.active.cursor.y != self.scrolling_region.top or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right)
    {
        self.cursorUp(1);
        return;
    }

    self.scrollDown(1);
}

/// Set Cursor Position. Move cursor to the position indicated
/// by row and column (1-indexed). If column is 0, it is adjusted to 1.
/// If column is greater than the right-most column it is adjusted to
/// the right-most column. If row is 0, it is adjusted to 1. If row is
/// greater than the bottom-most row it is adjusted to the bottom-most
/// row.
pub fn setCursorPos(self: *Terminal, row_req: usize, col_req: usize) void {
    // If cursor origin mode is set the cursor row will be moved relative to
    // the top margin row and adjusted to be above or at bottom-most row in
    // the current scroll region.
    //
    // If origin mode is set and left and right margin mode is set the cursor
    // will be moved relative to the left margin column and adjusted to be on
    // or left of the right margin column.
    const params: struct {
        x_offset: size.CellCountInt = 0,
        y_offset: size.CellCountInt = 0,
        x_max: size.CellCountInt,
        y_max: size.CellCountInt,
    } = if (self.modes.get(.origin)) .{
        .x_offset = self.scrolling_region.left,
        .y_offset = self.scrolling_region.top,
        .x_max = self.scrolling_region.right + 1, // We need this 1-indexed
        .y_max = self.scrolling_region.bottom + 1, // We need this 1-indexed
    } else .{
        .x_max = self.cols,
        .y_max = self.rows,
    };

    // Unset pending wrap state
    self.screens.active.cursor.pending_wrap = false;

    // Calculate our new x/y
    const row = if (row_req == 0) 1 else row_req;
    const col = if (col_req == 0) 1 else col_req;
    const x = @min(params.x_max, col + params.x_offset) -| 1;
    const y = @min(params.y_max, row + params.y_offset) -| 1;

    // If the y is unchanged then this is fast pointer math
    if (y == self.screens.active.cursor.y) {
        if (x > self.screens.active.cursor.x) {
            self.screens.active.cursorRight(x - self.screens.active.cursor.x);
        } else {
            self.screens.active.cursorLeft(self.screens.active.cursor.x - x);
        }

        return;
    }

    // If everything changed we do an absolute change which is slightly slower
    self.screens.active.cursorAbsolute(x, y);
    // log.info("set cursor position: col={} row={}", .{ self.screens.active.cursor.x, self.screens.active.cursor.y });
}

/// Set Top and Bottom Margins If bottom is not specified, 0 or bigger than
/// the number of the bottom-most row, it is adjusted to the number of the
/// bottom most row.
///
/// If top < bottom set the top and bottom row of the scroll region according
/// to top and bottom and move the cursor to the top-left cell of the display
/// (when in cursor origin mode is set to the top-left cell of the scroll region).
///
/// Otherwise: Set the top and bottom row of the scroll region to the top-most
/// and bottom-most line of the screen.
///
/// Top and bottom are 1-indexed.
pub fn setTopAndBottomMargin(self: *Terminal, top_req: usize, bottom_req: usize) void {
    const top = @max(1, top_req);
    const bottom = @min(self.rows, if (bottom_req == 0) self.rows else bottom_req);
    if (top >= bottom) return;

    self.scrolling_region.top = @intCast(top - 1);
    self.scrolling_region.bottom = @intCast(bottom - 1);
    self.setCursorPos(1, 1);
}

/// DECSLRM
pub fn setLeftAndRightMargin(self: *Terminal, left_req: usize, right_req: usize) void {
    // We must have this mode enabled to do anything
    if (!self.modes.get(.enable_left_and_right_margin)) return;

    const left = @max(1, left_req);
    const right = @min(self.cols, if (right_req == 0) self.cols else right_req);
    if (left >= right) return;

    self.scrolling_region.left = @intCast(left - 1);
    self.scrolling_region.right = @intCast(right - 1);
    self.setCursorPos(1, 1);
}

/// Scroll the text down by one row.
pub fn scrollDown(self: *Terminal, count: usize) void {
    // Preserve our x/y to restore.
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }

    // Move to the top of the scroll region
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.insertLines(count);
}

/// Removes amount lines from the top of the scroll region. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up
/// is filled with empty lines.
///
/// The new lines are created according to the current SGR state.
///
/// Does not change the (absolute) cursor position.
pub fn scrollUp(self: *Terminal, count: usize) !void {
    // Preserve our x/y to restore.
    const old_x = self.screens.active.cursor.x;
    const old_y = self.screens.active.cursor.y;
    const old_wrap = self.screens.active.cursor.pending_wrap;
    defer {
        self.screens.active.cursorAbsolute(old_x, old_y);
        self.screens.active.cursor.pending_wrap = old_wrap;
    }

    // If our scroll region is at the top and we have no left/right
    // margins then we move the scrolled out text into the scrollback.
    if (self.scrolling_region.top == 0 and
        self.scrolling_region.left == 0 and
        self.scrolling_region.right == self.cols - 1)
    {
        // Scrolling dirties the images because it updates their placements pins.
        if (comptime build_options.kitty_graphics) {
            self.screens.active.kitty_images.dirty = true;
        }

        // Clamp count to the scroll region height.
        const region_height = self.scrolling_region.bottom + 1;
        const adjusted_count = @min(count, region_height);

        // TODO: Create an optimized version that can scroll N times
        // This isn't critical because in most cases, scrollUp is used
        // with count=1, but it's still a big optimization opportunity.

        // Move our cursor to the bottom of the scroll region so we can
        // use the cursorScrollAbove function to create scrollback
        self.screens.active.cursorAbsolute(0, self.scrolling_region.bottom);
        for (0..adjusted_count) |_| try self.screens.active.cursorScrollAbove();
        return;
    }

    // Move to the top of the scroll region
    self.screens.active.cursorAbsolute(self.scrolling_region.left, self.scrolling_region.top);
    self.deleteLines(count);
}

/// Options for scrolling the viewport of the terminal grid.
pub const ScrollViewport = union(enum) {
    /// Scroll to the top of the scrollback
    top,

    /// Scroll to the bottom, i.e. the top of the active area
    bottom,

    /// Scroll by some delta amount, up is negative.
    delta: isize,
};

/// Scroll the viewport of the terminal grid.
pub fn scrollViewport(self: *Terminal, behavior: ScrollViewport) void {
    self.screens.active.scroll(switch (behavior) {
        .top => .{ .top = {} },
        .bottom => .{ .active = {} },
        .delta => |delta| .{ .delta_row = delta },
    });
}

/// To be called before shifting a row (as in insertLines and deleteLines)
///
/// Takes care of boundary conditions such as potentially split wide chars
/// across scrolling region boundaries and orphaned spacer heads at line
/// ends.
fn rowWillBeShifted(
    self: *Terminal,
    page: *Page,
    row: *Row,
) void {
    const cells = row.cells.ptr(page.memory.ptr);

    // If our scrolling region includes the rightmost column then we
    // need to turn any spacer heads in to normal empty cells, since
    // once we move them they no longer correspond with soft-wrapped
    // wide characters.
    //
    // If it contains either of the 2 leftmost columns, then the wide
    // characters in the first column which may be associated with a
    // spacer head will be either moved or cleared, so we also need
    // to turn the spacer heads in to empty cells in that case.
    if (self.scrolling_region.right == self.cols - 1 or
        self.scrolling_region.left < 2)
    {
        const end_cell: *Cell = &cells[page.size.cols - 1];
        if (end_cell.wide == .spacer_head) {
            end_cell.wide = .narrow;
        }
    }

    // If the leftmost or rightmost cells of our scrolling region
    // are parts of wide chars, we need to clear the cells' contents
    // since they'd be split by the move.
    const left_cell: *Cell = &cells[self.scrolling_region.left];
    const right_cell: *Cell = &cells[self.scrolling_region.right];

    if (left_cell.wide == .spacer_tail) {
        const wide_cell: *Cell = &cells[self.scrolling_region.left - 1];
        if (wide_cell.hasGrapheme()) {
            page.clearGrapheme(wide_cell);
            page.updateRowGraphemeFlag(row);
        }
        wide_cell.content.codepoint = 0;
        wide_cell.wide = .narrow;
        left_cell.wide = .narrow;
    }

    if (right_cell.wide == .wide) {
        const tail_cell: *Cell = &cells[self.scrolling_region.right + 1];
        if (right_cell.hasGrapheme()) {
            page.clearGrapheme(right_cell);
            page.updateRowGraphemeFlag(row);
        }
        right_cell.content.codepoint = 0;
        right_cell.wide = .narrow;
        tail_cell.wide = .narrow;
    }
}

// TODO(qwerasd): `insertLines` and `deleteLines` are 99% identical,
// the majority of their logic can (and should) be abstracted in to
// a single shared helper function, probably on `Screen` not here.
// I'm just too lazy to do that rn :p

/// Insert amount lines at the current cursor row. The contents of the line
/// at the current cursor row and below (to the bottom-most line in the
/// scrolling region) are shifted down by amount lines. The contents of the
/// amount bottom-most lines in the scroll region are lost.
///
/// This unsets the pending wrap state without wrapping. If the current cursor
/// position is outside of the current scroll region it does nothing.
///
/// If amount is greater than the remaining number of lines in the scrolling
/// region it is adjusted down (still allowing for scrolling out every remaining
/// line in the scrolling region)
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// All cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn insertLines(self: *Terminal, count: usize) void {
    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    if (comptime build_options.kitty_graphics) {
        // Scrolling dirties the images because it updates their placements pins.
        self.screens.active.kitty_images.dirty = true;
    }

    // At the end we need to return the cursor to the row it started on.
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);

        // Always unset pending wrap
        self.screens.active.cursor.pending_wrap = false;
    }

    // We have a slower path if we have left or right scroll margins.
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;

    // Remaining rows from our cursor to the bottom of the scroll region.
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;

    // We can only insert lines up to our remaining lines in the scroll
    // region. So we take whichever is smaller.
    const adjusted_count = @min(count, rem);

    // Create a new tracked pin which we'll use to navigate the page list
    // so that if we need to adjust capacity it will be properly tracked.
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.down(rem - 1).?,
    ) catch |err| {
        comptime assert(@TypeOf(err) == error{OutOfMemory});

        // This error scenario means that our GPA is OOM. This is not a
        // situation we can gracefully handle. We can't just ignore insertLines
        // because it'll result in a corrupted screen. Ideally in the future
        // we flag the state as broken and show an error message to the user.
        // For now, we panic.
        log.err("insertLines trackPin error err={}", .{err});
        @panic("insertLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);

    // Our current y position relative to the cursor
    var y: usize = rem;

    // Traverse from the bottom up
    while (y > 0) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;

        // If this is one of the lines we need to shift, do so
        if (y > adjusted_count) {
            const off_p = cur_p.up(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;

            self.rowWillBeShifted(&cur_p.node.data, cur_row);
            self.rowWillBeShifted(&off_p.node.data, off_row);

            // If our scrolling region is full width, then we unset wrap.
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }

            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;

            // If our page doesn't match, then we need to do a copy from
            // one page to another. This is the slow path.
            if (src_p.node != dst_p.node) {
                dst_p.node.data.clonePartialRowFrom(
                    &src_p.node.data,
                    dst_row,
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                ) catch |err| {
                    // Adjust our page capacity to make
                    // room for we didn't have space for
                    _ = self.screens.active.increaseCapacity(
                        dst_p.node,
                        switch (err) {
                            // Rehash the sets
                            error.StyleSetNeedsRehash,
                            error.HyperlinkSetNeedsRehash,
                            => null,

                            // Increase style memory
                            error.StyleSetOutOfMemory,
                            => .styles,

                            // Increase string memory
                            error.StringAllocOutOfMemory,
                            => .string_bytes,

                            // Increase hyperlink memory
                            error.HyperlinkSetOutOfMemory,
                            error.HyperlinkMapOutOfMemory,
                            => .hyperlink_bytes,

                            // Increase grapheme memory
                            error.GraphemeMapOutOfMemory,
                            error.GraphemeAllocOutOfMemory,
                            => .grapheme_bytes,
                        },
                    ) catch |e| switch (e) {
                        // System OOM. We have no way to recover from this
                        // currently. We should probably change insertLines
                        // to raise an error here.
                        error.OutOfMemory,
                        => @panic("increaseCapacity system allocator OOM"),

                        // The page can't accommodate the managed memory required
                        // for this operation. We previously just corrupted
                        // memory here so a crash is better. The right long
                        // term solution is to allocate a new page here
                        // move this row to the new page, and start over.
                        error.OutOfSpace,
                        => @panic("increaseCapacity OutOfSpace"),
                    };

                    // Continue the loop to try handling this row again.
                    continue;
                };
            } else {
                if (!left_right) {
                    // Swap the src/dst cells. This ensures that our dst gets the
                    // proper shifted rows and src gets non-garbage cell data that
                    // we can clear.
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;

                    // Ensure what we did didn't corrupt the page
                    cur_p.node.data.assertIntegrity();
                } else {
                    // Left/right scroll margins we have to
                    // copy cells, which is much slower...
                    const page = &cur_p.node.data;
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            // Clear the cells for this row, it has been shifted.
            self.rowWillBeShifted(&cur_p.node.data, cur_row);
            const page = &cur_p.node.data;
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );
        }

        // Mark the row as dirty
        cur_p.markDirty();

        // We have successfully processed a line.
        y -= 1;
        // Move our pin up to the next row.
        if (cur_p.up(1)) |p| cur_p.* = p;
    }
}

/// Removes amount lines from the current cursor row down. The remaining lines
/// to the bottom margin are shifted up and space from the bottom margin up is
/// filled with empty lines.
///
/// If the current cursor position is outside of the current scroll region it
/// does nothing. If amount is greater than the remaining number of lines in the
/// scrolling region it is adjusted down.
///
/// In left and right margin mode the margins are respected; lines are only
/// scrolled in the scroll region.
///
/// If the cell movement splits a multi cell character that character cleared,
/// by replacing it by spaces, keeping its current attributes. All other
/// cleared space is colored according to the current SGR state.
///
/// Moves the cursor to the left margin.
pub fn deleteLines(self: *Terminal, count: usize) void {
    // Rare, but happens
    if (count == 0) return;

    // If the cursor is outside the scroll region we do nothing.
    if (self.screens.active.cursor.y < self.scrolling_region.top or
        self.screens.active.cursor.y > self.scrolling_region.bottom or
        self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    if (comptime build_options.kitty_graphics) {
        // Scrolling dirties the images because it updates their placements pins.
        self.screens.active.kitty_images.dirty = true;
    }

    // At the end we need to return the cursor to the row it started on.
    const start_y = self.screens.active.cursor.y;
    defer {
        self.screens.active.cursorAbsolute(self.scrolling_region.left, start_y);
        // Always unset pending wrap
        self.screens.active.cursor.pending_wrap = false;
    }

    // We have a slower path if we have left or right scroll margins.
    const left_right = self.scrolling_region.left > 0 or
        self.scrolling_region.right < self.cols - 1;

    // Remaining rows from our cursor to the bottom of the scroll region.
    const rem = self.scrolling_region.bottom - self.screens.active.cursor.y + 1;

    // We can only insert lines up to our remaining lines in the scroll
    // region. So we take whichever is smaller.
    const adjusted_count = @min(count, rem);

    // Create a new tracked pin which we'll use to navigate the page list
    // so that if we need to adjust capacity it will be properly tracked.
    var cur_p = self.screens.active.pages.trackPin(
        self.screens.active.cursor.page_pin.*,
    ) catch |err| {
        // See insertLines
        comptime assert(@TypeOf(err) == error{OutOfMemory});
        log.err("deleteLines trackPin error err={}", .{err});
        @panic("deleteLines trackPin OOM");
    };
    defer self.screens.active.pages.untrackPin(cur_p);

    // Our current y position relative to the cursor
    var y: usize = 0;

    // Traverse from the top down
    while (y < rem) {
        const cur_rac = cur_p.rowAndCell();
        const cur_row: *Row = cur_rac.row;

        // If this is one of the lines we need to shift, do so
        if (y < rem - adjusted_count) {
            const off_p = cur_p.down(adjusted_count).?;
            const off_rac = off_p.rowAndCell();
            const off_row: *Row = off_rac.row;

            self.rowWillBeShifted(&cur_p.node.data, cur_row);
            self.rowWillBeShifted(&off_p.node.data, off_row);

            // If our scrolling region is full width, then we unset wrap.
            if (!left_right) {
                off_row.wrap = false;
                cur_row.wrap = false;
                off_row.wrap_continuation = false;
                cur_row.wrap_continuation = false;
            }

            const src_p = off_p;
            const src_row = off_row;
            const dst_p = cur_p;
            const dst_row = cur_row;

            // If our page doesn't match, then we need to do a copy from
            // one page to another. This is the slow path.
            if (src_p.node != dst_p.node) {
                dst_p.node.data.clonePartialRowFrom(
                    &src_p.node.data,
                    dst_row,
                    src_row,
                    self.scrolling_region.left,
                    self.scrolling_region.right + 1,
                ) catch |err| {
                    // Adjust our page capacity to make
                    // room for we didn't have space for
                    _ = self.screens.active.increaseCapacity(
                        dst_p.node,
                        switch (err) {
                            // Rehash the sets
                            error.StyleSetNeedsRehash,
                            error.HyperlinkSetNeedsRehash,
                            => null,

                            // Increase style memory
                            error.StyleSetOutOfMemory,
                            => .styles,

                            // Increase string memory
                            error.StringAllocOutOfMemory,
                            => .string_bytes,

                            // Increase hyperlink memory
                            error.HyperlinkSetOutOfMemory,
                            error.HyperlinkMapOutOfMemory,
                            => .hyperlink_bytes,

                            // Increase grapheme memory
                            error.GraphemeMapOutOfMemory,
                            error.GraphemeAllocOutOfMemory,
                            => .grapheme_bytes,
                        },
                    ) catch |e| switch (e) {
                        // See insertLines
                        error.OutOfMemory,
                        => @panic("increaseCapacity system allocator OOM"),

                        error.OutOfSpace,
                        => @panic("increaseCapacity OutOfSpace"),
                    };

                    // Continue the loop to try handling this row again.
                    continue;
                };
            } else {
                if (!left_right) {
                    // Swap the src/dst cells. This ensures that our dst gets the
                    // proper shifted rows and src gets non-garbage cell data that
                    // we can clear.
                    const dst = dst_row.*;
                    dst_row.* = src_row.*;
                    src_row.* = dst;

                    // Ensure what we did didn't corrupt the page
                    cur_p.node.data.assertIntegrity();
                } else {
                    // Left/right scroll margins we have to
                    // copy cells, which is much slower...
                    const page = &cur_p.node.data;
                    page.moveCells(
                        src_row,
                        self.scrolling_region.left,
                        dst_row,
                        self.scrolling_region.left,
                        (self.scrolling_region.right - self.scrolling_region.left) + 1,
                    );
                }
            }
        } else {
            // Clear the cells for this row, it's from out of bounds.
            self.rowWillBeShifted(&cur_p.node.data, cur_row);
            const page = &cur_p.node.data;
            const cells = page.getCells(cur_row);
            self.screens.active.clearCells(
                page,
                cur_row,
                cells[self.scrolling_region.left .. self.scrolling_region.right + 1],
            );
        }

        // Mark the row as dirty
        cur_p.markDirty();

        // We have successfully processed a line.
        y += 1;
        // Move our pin down to the next row.
        if (cur_p.down(1)) |p| cur_p.* = p;
    }
}

/// Inserts spaces at current cursor position moving existing cell contents
/// to the right. The contents of the count right-most columns in the scroll
/// region are lost. The cursor position is not changed.
///
/// This unsets the pending wrap state without wrapping.
///
/// The inserted cells are colored according to the current SGR state.
pub fn insertBlanks(self: *Terminal, count: usize) void {
    // Unset pending wrap state without wrapping. Note: this purposely
    // happens BEFORE the scroll region check below, because that's what
    // xterm does.
    self.screens.active.cursor.pending_wrap = false;

    // If we're given a zero then we do nothing. The rest of this function
    // assumes count > 0 and will crash if zero so return early. Note that
    // this shouldn't be possible with real CSI sequences because the value
    // is clamped to 1 min.
    if (count == 0) return;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    // If our count is larger than the remaining amount, we just erase right.
    // We only do this if we can erase the entire line (no right margin).
    // if (right_limit == self.cols and
    //     count > right_limit - self.screens.active.cursor.x)
    // {
    //     self.eraseLine(.right, false);
    //     return;
    // }

    // left is just the cursor position but as a multi-pointer
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = &self.screens.active.cursor.page_pin.node.data;

    // If our X is a wide spacer tail then we need to erase the
    // previous cell too so we don't split a multi-cell character.
    if (self.screens.active.cursor.page_cell.wide == .spacer_tail) {
        assert(self.screens.active.cursor.x > 0);
        self.screens.active.clearCells(page, self.screens.active.cursor.page_row, (left - 1)[0..2]);
    }

    // Remaining cols from our cursor to the right margin.
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;

    // If the cell at the right margin is wide, its spacer tail is
    // outside the scroll region and would be orphaned by either the
    // shift or the clear. Clean up both halves up front.
    {
        const right_cell: *Cell = @ptrCast(left + (rem - 1));
        if (right_cell.wide == .wide) self.screens.active.clearCells(
            page,
            self.screens.active.cursor.page_row,
            @as([*]Cell, @ptrCast(right_cell))[0..2],
        );
    }

    // We can only insert blanks up to our remaining cols
    const adjusted_count = @min(count, rem);

    // This is the amount of space at the right of the scroll region
    // that will NOT be blank, so we need to shift the correct cols right.
    // "scroll_amount" is the number of such cols.
    const scroll_amount = rem - adjusted_count;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);

        var x: [*]Cell = left + (scroll_amount - 1);

        // If our last cell we're shifting is wide, then we need to clear
        // it to be empty so we don't split the multi-cell char.
        const end: *Cell = @ptrCast(x);
        if (end.wide == .wide) {
            const end_multi: [*]Cell = @ptrCast(end);
            assert(end_multi[1].wide == .spacer_tail);
            self.screens.active.clearCells(
                page,
                self.screens.active.cursor.page_row,
                end_multi[0..2],
            );
        }

        // We work backwards so we don't overwrite data.
        while (@intFromPtr(x) >= @intFromPtr(left)) : (x -= 1) {
            const src: *Cell = @ptrCast(x);
            const dst: *Cell = @ptrCast(x + adjusted_count);
            page.swapCells(src, dst);
        }
    }

    // Insert blanks. The blanks preserve the background color.
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, left[0..adjusted_count]);

    // Our row is always dirty
    self.screens.active.cursorMarkDirty();
}

/// Removes amount characters from the current cursor position to the right.
/// The remaining characters are shifted to the left and space from the right
/// margin is filled with spaces.
///
/// If amount is greater than the remaining number of characters in the
/// scrolling region, it is adjusted down.
///
/// Does not change the cursor position.
pub fn deleteChars(self: *Terminal, count_req: usize) void {
    if (count_req == 0) return;

    // If our cursor is outside the margins then do nothing. We DO reset
    // wrap state still so this must remain below the above logic.
    if (self.screens.active.cursor.x < self.scrolling_region.left or
        self.screens.active.cursor.x > self.scrolling_region.right) return;

    // left is just the cursor position but as a multi-pointer
    const left: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
    var page = &self.screens.active.cursor.page_pin.node.data;

    // Remaining cols from our cursor to the right margin.
    const rem = self.scrolling_region.right - self.screens.active.cursor.x + 1;

    // We can only insert blanks up to our remaining cols
    const count = @min(count_req, rem);

    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);
    self.screens.active.splitCellBoundary(self.scrolling_region.right + 1);

    // This is the amount of space at the right of the scroll region
    // that will NOT be blank, so we need to shift the correct cols right.
    // "scroll_amount" is the number of such cols.
    const scroll_amount = rem - count;
    var x: [*]Cell = left;
    if (scroll_amount > 0) {
        page.pauseIntegrityChecks(true);
        defer page.pauseIntegrityChecks(false);

        const right: [*]Cell = left + (scroll_amount - 1);

        while (@intFromPtr(x) <= @intFromPtr(right)) : (x += 1) {
            const src: *Cell = @ptrCast(x + count);
            const dst: *Cell = @ptrCast(x);
            page.swapCells(src, dst);
        }
    }

    // Insert blanks. The blanks preserve the background color.
    self.screens.active.clearCells(page, self.screens.active.cursor.page_row, x[0 .. rem - scroll_amount]);

    // Our row's soft-wrap is always reset.
    self.screens.active.cursorResetWrap();

    // Our row is always dirty
    self.screens.active.cursorMarkDirty();
}

pub fn eraseChars(self: *Terminal, count_req: usize) void {
    const count = end: {
        const remaining = self.cols - self.screens.active.cursor.x;
        var end = @min(remaining, @max(count_req, 1));

        // If our last cell is a wide char then we need to also clear the
        // cell beyond it since we can't just split a wide char.
        if (end != remaining) {
            const last = self.screens.active.cursorCellRight(end - 1);
            if (last.wide == .wide) end += 1;
        }

        break :end end;
    };

    // Handle any boundary conditions on the edges of the erased area.
    //
    // TODO(qwerasd): This isn't actually correct if you take in to account
    // protected modes. We need to figure out how to make `clearCells` or at
    // least `clearUnprotectedCells` handle boundary conditions...
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x);
    self.screens.active.splitCellBoundary(self.screens.active.cursor.x + count);

    // Reset our row's soft-wrap.
    self.screens.active.cursorResetWrap();

    // Mark our cursor row as dirty
    self.screens.active.cursorMarkDirty();

    // Clear the cells
    const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);

    // If we never had a protection mode, then we can assume no cells
    // are protected and go with the fast path. If the last protection
    // mode was not ISO we also always ignore protection attributes.
    if (self.screens.active.protected_mode != .iso) {
        self.screens.active.clearCells(
            &self.screens.active.cursor.page_pin.node.data,
            self.screens.active.cursor.page_row,
            cells[0..count],
        );
        return;
    }

    self.screens.active.clearUnprotectedCells(
        &self.screens.active.cursor.page_pin.node.data,
        self.screens.active.cursor.page_row,
        cells[0..count],
    );
}

/// Erase the line.
pub fn eraseLine(
    self: *Terminal,
    mode: csi.EraseLine,
    protected_req: bool,
) void {
    // Get our start/end positions depending on mode.
    const start, const end = switch (mode) {
        .right => right: {
            var x = self.screens.active.cursor.x;

            // If our X is a wide spacer tail then we need to erase the
            // previous cell too so we don't split a multi-cell character.
            if (x > 0 and self.screens.active.cursor.page_cell.wide == .spacer_tail) {
                x -= 1;
            }

            // Reset our row's soft-wrap.
            self.screens.active.cursorResetWrap();

            break :right .{ x, self.cols };
        },

        .left => left: {
            var x = self.screens.active.cursor.x;

            // If our x is a wide char we need to delete the tail too.
            if (self.screens.active.cursor.page_cell.wide == .wide) {
                x += 1;
            }

            break :left .{ 0, x + 1 };
        },

        // Note that it seems like complete should reset the soft-wrap
        // state of the line but in xterm it does not.
        .complete => .{ 0, self.cols },

        else => {
            log.err("unimplemented erase line mode: {}", .{mode});
            return;
        },
    };

    // All modes will clear the pending wrap state and we know we have
    // a valid mode at this point.
    self.screens.active.cursor.pending_wrap = false;

    // We always mark our row as dirty
    self.screens.active.cursorMarkDirty();

    // Start of our cells
    const cells: [*]Cell = cells: {
        const cells: [*]Cell = @ptrCast(self.screens.active.cursor.page_cell);
        break :cells cells - self.screens.active.cursor.x;
    };

    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screens.active.protected_mode == .iso or protected_req;

    // If we're not respecting protected attributes, we can use a fast-path
    // to fill the entire line.
    if (!protected) {
        self.screens.active.clearCells(
            &self.screens.active.cursor.page_pin.node.data,
            self.screens.active.cursor.page_row,
            cells[start..end],
        );
        return;
    }

    self.screens.active.clearUnprotectedCells(
        &self.screens.active.cursor.page_pin.node.data,
        self.screens.active.cursor.page_row,
        cells[start..end],
    );
}

/// Erase the display.
pub fn eraseDisplay(
    self: *Terminal,
    mode: csi.EraseDisplay,
    protected_req: bool,
) void {
    // We respect protected attributes if explicitly requested (probably
    // a DECSEL sequence) or if our last protected mode was ISO even if its
    // not currently set.
    const protected = self.screens.active.protected_mode == .iso or protected_req;

    switch (mode) {
        .scroll_complete => {
            self.screens.active.scrollClear() catch |err| {
                log.warn("scroll clear failed, doing a normal clear err={}", .{err});
                self.eraseDisplay(.complete, protected_req);
                return;
            };

            // Unsets pending wrap state
            self.screens.active.cursor.pending_wrap = false;

            if (comptime build_options.kitty_graphics) {
                // Clear all Kitty graphics state for this screen
                self.screens.active.kitty_images.delete(
                    self.screens.active.alloc,
                    self,
                    .{ .all = true },
                );
            }
        },

        .complete => {
            // If we're on the primary screen and our last non-empty row is
            // a prompt, then we do a scroll_complete instead. This is a
            // heuristic to get the generally desirable behavior that ^L
            // at a prompt scrolls the screen contents prior to clearing.
            // Most shells send `ESC [ H ESC [ 2 J` so we can't just check
            // our current cursor position. See #905
            if (self.screens.active_key == .primary) at_prompt: {
                // Go from the bottom of the active up and see if we're
                // at a prompt.
                const active_br = self.screens.active.pages.getBottomRight(
                    .active,
                ) orelse break :at_prompt;
                var it = active_br.rowIterator(
                    .left_up,
                    self.screens.active.pages.getTopLeft(.active),
                );
                while (it.next()) |p| {
                    const row = p.rowAndCell().row;
                    switch (row.semantic_prompt) {
                        // If we're at a prompt or input area, then we are at a prompt.
                        .prompt,
                        .prompt_continuation,
                        => break,

                        // If we have command output, then we're most certainly not
                        // at a prompt.
                        .none => break :at_prompt,
                    }
                } else break :at_prompt;

                self.screens.active.scrollClear() catch {
                    // If we fail, we just fall back to doing a normal clear
                    // so we don't worry about the error.
                };
            }

            // All active area
            self.screens.active.clearRows(
                .{ .active = .{} },
                null,
                protected,
            );

            // Unsets pending wrap state
            self.screens.active.cursor.pending_wrap = false;

            if (comptime build_options.kitty_graphics) {
                // Clear all Kitty graphics state for this screen
                self.screens.active.kitty_images.delete(
                    self.screens.active.alloc,
                    self,
                    .{ .all = true },
                );
            }

            // Cleared screen dirty bit
            self.flags.dirty.clear = true;
        },

        .below => {
            // All lines to the right (including the cursor)
            self.eraseLine(.right, protected_req);

            // All lines below
            if (self.screens.active.cursor.y + 1 < self.rows) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = self.screens.active.cursor.y + 1 } },
                    null,
                    protected,
                );
            }

            // Unsets pending wrap state. Should be done by eraseLine.
            assert(!self.screens.active.cursor.pending_wrap);
        },

        .above => {
            // Erase to the left (including the cursor)
            self.eraseLine(.left, protected_req);

            // All lines above
            if (self.screens.active.cursor.y > 0) {
                self.screens.active.clearRows(
                    .{ .active = .{ .y = 0 } },
                    .{ .active = .{ .y = self.screens.active.cursor.y - 1 } },
                    protected,
                );
            }

            // Unsets pending wrap state
            assert(!self.screens.active.cursor.pending_wrap);
        },

        .scrollback => self.screens.active.eraseRows(.{ .history = .{} }, null),
    }
}

/// Resets all margins and fills the whole screen with the character 'E'
///
/// Sets the cursor to the top left corner.
pub fn decaln(self: *Terminal) !void {
    // Clear our stylistic attributes. This is the only thing that can
    // fail so we do it first so we can undo it.
    const old_style = self.screens.active.cursor.style;
    self.screens.active.cursor.style = .{
        .bg_color = self.screens.active.cursor.style.bg_color,
        .fg_color = self.screens.active.cursor.style.fg_color,
    };
    errdefer self.screens.active.cursor.style = old_style;
    try self.screens.active.manualStyleUpdate();

    // Reset margins, also sets cursor to top-left
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };

    // Origin mode is disabled
    self.modes.set(.origin, false);

    // Move our cursor to the top-left
    self.setCursorPos(1, 1);

    // Use clearRows instead of eraseDisplay because we must NOT respect
    // protected attributes here.
    self.screens.active.clearRows(
        .{ .active = .{} },
        null,
        false,
    );

    // Fill with Es by moving the cursor but reset it after.
    while (true) {
        const page = &self.screens.active.cursor.page_pin.node.data;
        const row = self.screens.active.cursor.page_row;
        const cells_multi: [*]Cell = row.cells.ptr(page.memory);
        const cells = cells_multi[0..page.size.cols];
        @memset(cells, .{
            .content_tag = .codepoint,
            .content = .{ .codepoint = 'E' },
            .style_id = self.screens.active.cursor.style_id,

            // DECALN does not respect protected state. Verified with xterm.
            .protected = false,
        });

        // If we have a ref-counted style, increase
        if (self.screens.active.cursor.style_id != style.default_id) {
            page.styles.useMultiple(
                page.memory,
                self.screens.active.cursor.style_id,
                @intCast(cells.len),
            );
            row.styled = true;
        }

        // We messed with the page so assert its integrity here.
        page.assertIntegrity();

        self.screens.active.cursorMarkDirty();
        if (self.screens.active.cursor.y == self.rows - 1) break;
        self.screens.active.cursorDown(1);
    }

    // Reset the cursor to the top-left
    self.setCursorPos(1, 1);
}

/// Execute a kitty graphics command. The buf is used to populate with
/// the response that should be sent as an APC sequence. The response will
/// be a full, valid APC sequence.
///
/// If an error occurs, the caller should response to the pty that a
/// an error occurred otherwise the behavior of the graphics protocol is
/// undefined.
pub fn kittyGraphics(
    self: *Terminal,
    alloc: Allocator,
    cmd: *kitty.graphics.Command,
) ?kitty.graphics.Response {
    return kitty.graphics.execute(alloc, self, cmd);
}

/// Set a style attribute.
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void {
    try self.screens.active.setAttribute(attr);
}

/// Print the active attributes as a string. This is used to respond to DECRQSS
/// requests.
///
/// Boolean attributes are printed first, followed by foreground color, then
/// background color. Each attribute is separated by a semicolon.
pub fn printAttributes(self: *Terminal, buf: []u8) ![]const u8 {
    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    // The SGR response always starts with a 0. See https://vt100.net/docs/vt510-rm/DECRPSS
    try writer.writeByte('0');

    const pen = self.screens.active.cursor.style;
    var attrs: [8]u8 = @splat(0);
    var i: usize = 0;

    if (pen.flags.bold) {
        attrs[i] = '1';
        i += 1;
    }

    if (pen.flags.faint) {
        attrs[i] = '2';
        i += 1;
    }

    if (pen.flags.italic) {
        attrs[i] = '3';
        i += 1;
    }

    if (pen.flags.underline != .none) {
        attrs[i] = '4';
        i += 1;
    }

    if (pen.flags.blink) {
        attrs[i] = '5';
        i += 1;
    }

    if (pen.flags.inverse) {
        attrs[i] = '7';
        i += 1;
    }

    if (pen.flags.invisible) {
        attrs[i] = '8';
        i += 1;
    }

    if (pen.flags.strikethrough) {
        attrs[i] = '9';
        i += 1;
    }

    for (attrs[0..i]) |c| {
        try writer.print(";{c}", .{c});
    }

    switch (pen.fg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";38:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";9{}", .{idx - 8})
        else
            try writer.print(";3{}", .{idx}),
        .rgb => |rgb| try writer.print(";38:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    switch (pen.bg_color) {
        .none => {},
        .palette => |idx| if (idx >= 16)
            try writer.print(";48:5:{}", .{idx})
        else if (idx >= 8)
            try writer.print(";10{}", .{idx - 8})
        else
            try writer.print(";4{}", .{idx}),
        .rgb => |rgb| try writer.print(";48:2::{[r]}:{[g]}:{[b]}", rgb),
    }

    return stream.getWritten();
}

/// The modes for DECCOLM.
pub const DeccolmMode = enum(u1) {
    @"80_cols" = 0,
    @"132_cols" = 1,
};

/// DECCOLM changes the terminal width between 80 and 132 columns. This
/// function call will do NOTHING unless `setDeccolmSupported` has been
/// called with "true".
///
/// This breaks the expectation around modern terminals that they resize
/// with the window. This will fix the grid at either 80 or 132 columns.
/// The rows will continue to be variable.
pub fn deccolm(self: *Terminal, alloc: Allocator, mode: DeccolmMode) !void {
    // If DEC mode 40 isn't enabled, then this is ignored. We also make
    // sure that we don't have deccolm set because we want to fully ignore
    // set mode.
    if (!self.modes.get(.enable_mode_3)) {
        self.modes.set(.@"132_column", false);
        return;
    }

    // Enable it
    self.modes.set(.@"132_column", mode == .@"132_cols");

    // Resize to the requested size
    try self.resize(
        alloc,
        switch (mode) {
            .@"132_cols" => 132,
            .@"80_cols" => 80,
        },
        self.rows,
    );

    // Erase our display and move our cursor.
    self.eraseDisplay(.complete, false);
    self.setCursorPos(1, 1);
}

/// Resize the underlying terminal.
pub fn resize(
    self: *Terminal,
    alloc: Allocator,
    cols: size.CellCountInt,
    rows: size.CellCountInt,
) !void {
    // If our cols/rows didn't change then we're done
    if (self.cols == cols and self.rows == rows) return;

    // Resize our tabstops
    if (self.cols != cols) {
        self.tabstops.deinit(alloc);
        self.tabstops = try .init(alloc, cols, 8);
    }

    // Resize primary screen, which supports reflow
    const primary = self.screens.get(.primary).?;
    try primary.resize(.{
        .cols = cols,
        .rows = rows,
        .reflow = self.modes.get(.wraparound),
        .prompt_redraw = self.flags.shell_redraws_prompt,
    });

    // Alternate screen, if it exists, doesn't reflow
    if (self.screens.get(.alternate)) |alt| try alt.resize(.{
        .cols = cols,
        .rows = rows,
        .reflow = false,
    });

    // Whenever we resize we just mark it as a screen clear
    self.flags.dirty.clear = true;

    // Set our size
    self.cols = cols;
    self.rows = rows;

    // Reset the scrolling region
    self.scrolling_region = .{
        .top = 0,
        .bottom = rows - 1,
        .left = 0,
        .right = cols - 1,
    };
}

/// Set the pwd for the terminal.
pub fn setPwd(self: *Terminal, pwd: []const u8) !void {
    self.pwd.clearRetainingCapacity();
    try self.pwd.appendSlice(self.gpa(), pwd);
}

/// Returns the pwd for the terminal, if any. The memory is owned by the
/// Terminal and is not copied. It is safe until a reset or setPwd.
pub fn getPwd(self: *const Terminal) ?[]const u8 {
    if (self.pwd.items.len == 0) return null;
    return self.pwd.items;
}

/// Switch to the given screen type (alternate or primary).
///
/// This does NOT handle behaviors such as clearing the screen,
/// copying the cursor, etc. This should be handled by downstream
/// callers.
///
/// After calling this function, the `self.screen` field will point
/// to the current screen, and the returned value will be the previous
/// screen. If the return value is null, then the screen was not
/// switched because it was already the active screen.
///
/// Note: This is written in a generic way so that we can support
/// more than two screens in the future if needed. There isn't
/// currently a spec for this, but it is something I think might
/// be useful in the future.
pub fn switchScreen(self: *Terminal, key: ScreenSet.Key) !?*Screen {
    // If we're already on the requested screen we do nothing.
    if (self.screens.active_key == key) return null;
    const old = self.screens.active;

    // We always end hyperlink state when switching screens.
    // We need to do this on the original screen.
    old.endHyperlink();

    // Switch the screens/
    const new = self.screens.get(key) orelse new: {
        const primary = self.screens.get(.primary).?;
        break :new try self.screens.getInit(
            old.alloc,
            key,
            .{
                .cols = self.cols,
                .rows = self.rows,
                .max_scrollback = switch (key) {
                    .primary => primary.pages.explicit_max_size,
                    .alternate => 0,
                },

                // Inherit our Kitty image storage limit from the primary
                // screen if we have to initialize.
                .kitty_image_storage_limit = if (comptime build_options.kitty_graphics)
                    primary.kitty_images.total_limit
                else
                    0,
            },
        );
    };

    // The new screen should not have any hyperlinks set
    assert(new.cursor.hyperlink_id == 0);

    // Bring our charset state with us
    new.charset = old.charset;

    // Clear our selection
    new.clearSelection();

    if (comptime build_options.kitty_graphics) {
        // Mark kitty images as dirty so they redraw. Without this set
        // the images will remain where they were (the dirty bit on
        // the screen only tracks the terminal grid, not the images).
        new.kitty_images.dirty = true;
    }

    // Mark our terminal as dirty to redraw the grid.
    self.flags.dirty.clear = true;

    // Finalize the switch
    self.screens.switchTo(key);

    return old;
}

/// Switch screen via a mode switch (e.g. mode 47, 1047, 1049).
/// This is a much more opinionated operation than `switchScreen`
/// since it also handles the behaviors of the specific mode,
/// such as clearing the screen, saving/restoring the cursor,
/// etc.
///
/// This should be used for legacy compatibility with VT protocols,
/// but more modern usage should use `switchScreen` instead and handle
/// details like clearing the screen, cursor saving, etc. manually.
pub fn switchScreenMode(
    self: *Terminal,
    mode: SwitchScreenMode,
    enabled: bool,
) !void {
    // The behavior in this function is completely based on reading
    // the xterm source, specifically "charproc.c" for
    // `srm_ALTBUF`, `srm_OPT_ALTBUF`, and `srm_OPT_ALTBUF_CURSOR`.
    // We shouldn't touch anything in here without adding a unit
    // test AND verifying the behavior with xterm.

    switch (mode) {
        .@"47" => {},

        // If we're disabling 1047 and we're on alt screen then
        // we clear the screen.
        .@"1047" => if (!enabled and self.screens.active_key == .alternate) {
            self.eraseDisplay(.complete, false);
        },

        // 1049 unconditionally saves the cursor on enabling, even
        // if we're already on the alternate screen.
        .@"1049" => if (enabled) self.saveCursor(),
    }

    // Switch screens first to whatever we're going to.
    const to: ScreenSet.Key = if (enabled) .alternate else .primary;
    const old_ = try self.switchScreen(to);

    switch (mode) {
        // For these modes, we need to copy the cursor. We only copy
        // the cursor if the screen actually changed, otherwise the
        // cursor is already copied. The cursor is copied regardless
        // of destination screen.
        .@"47", .@"1047" => if (old_) |old| {
            self.screens.active.cursorCopy(old.cursor, .{
                .hyperlink = false,
            }) catch |err| {
                log.warn(
                    "cursor copy failed entering alt screen err={}",
                    .{err},
                );
            };
        },

        // Mode 1049 restores cursor on the primary screen when
        // we disable it.
        .@"1049" => if (enabled) {
            assert(self.screens.active_key == .alternate);
            self.eraseDisplay(.complete, false);

            // When we enter alt screen with 1049, we always copy the
            // cursor from the primary screen (if we weren't already
            // on it).
            if (old_) |old| {
                self.screens.active.cursorCopy(old.cursor, .{
                    .hyperlink = false,
                }) catch |err| {
                    log.warn(
                        "cursor copy failed entering alt screen err={}",
                        .{err},
                    );
                };
            }
        } else {
            assert(self.screens.active_key == .primary);
            self.restoreCursor();
        },
    }
}

/// Modal screen changes. These map to the literal terminal
/// modes to enable or disable alternate screen modes. They each
/// have subtle behaviors so we define them as an enum here.
pub const SwitchScreenMode = enum {
    /// Legacy alternate screen mode. This goes to the alternate
    /// screen or primary screen and only copies the cursor. The
    /// screen is not erased.
    @"47",

    /// Alternate screen mode where the alternate screen is cleared
    /// on exit. The primary screen is never cleared. The cursor is
    /// copied.
    @"1047",

    /// Save primary screen cursor, switch to alternate screen,
    /// and clear the alternate screen on entry. On exit,
    /// do not clear the screen, and restore the cursor on the
    /// primary screen.
    @"1049",
};

/// Return the current string value of the terminal. Newlines are
/// encoded as "\n". This omits any formatting such as fg/bg.
///
/// The caller must free the string.
pub fn plainString(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAlloc(alloc, .{ .viewport = .{} });
}

/// Same as plainString, but respects row wrap state when building the string.
pub fn plainStringUnwrapped(self: *Terminal, alloc: Allocator) ![]const u8 {
    return try self.screens.active.dumpStringAllocUnwrapped(alloc, .{ .viewport = .{} });
}

/// Full reset.
///
/// This will attempt to free the existing screen memory but if that fails
/// this will reuse the existing memory. In the latter case, memory may
/// be wasted (since its unused) but it isn't leaked.
pub fn fullReset(self: *Terminal) void {
    // Ensure we're back on primary screen
    self.screens.switchTo(.primary);
    self.screens.remove(
        self.screens.active.alloc,
        .alternate,
    );

    // Reset our screens
    self.screens.active.reset();

    // Rest our basic state
    self.modes.reset();
    self.flags = .{};
    self.tabstops.reset(TABSTOP_INTERVAL);
    self.previous_char = null;
    self.pwd.clearRetainingCapacity();
    self.status_display = .main;
    self.scrolling_region = .{
        .top = 0,
        .bottom = self.rows - 1,
        .left = 0,
        .right = self.cols - 1,
    };

    // Always mark dirty so we redraw everything
    self.flags.dirty.clear = true;
}
