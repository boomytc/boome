const std = @import("std");
const Allocator = std.mem.Allocator;

const DynamicColor = @import("../../color.zig").Dynamic;
const SpecialColor = @import("../../color.zig").Special;
const RGB = @import("../../color.zig").RGB;
const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_color);

const ParseError = Allocator.Error || error{
    MissingOperation,
};

/// The possible operations we support for colors.
pub const Operation = enum {
    osc_4,
    osc_5,
    osc_10,
    osc_11,
    osc_12,
    osc_13,
    osc_14,
    osc_15,
    osc_16,
    osc_17,
    osc_18,
    osc_19,
    osc_104,
    osc_105,
    osc_110,
    osc_111,
    osc_112,
    osc_113,
    osc_114,
    osc_115,
    osc_116,
    osc_117,
    osc_118,
    osc_119,
};

/// Parse OSCs 4, 5, 10-19, 104, 110-119
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    const alloc = parser.alloc orelse {
        parser.state = .invalid;
        return null;
    };
    // If we've collected any extra data parse that, otherwise use an empty
    // string.
    const data = data: {
        const writer = parser.writer orelse break :data "";
        break :data writer.buffered();
    };
    // Check and make sure that we're parsing the correct OSCs
    const op: Operation = switch (parser.state) {
        .@"4" => .osc_4,
        .@"5" => .osc_5,
        .@"10" => .osc_10,
        .@"11" => .osc_11,
        .@"12" => .osc_12,
        .@"13" => .osc_13,
        .@"14" => .osc_14,
        .@"15" => .osc_15,
        .@"16" => .osc_16,
        .@"17" => .osc_17,
        .@"18" => .osc_18,
        .@"19" => .osc_19,
        .@"104" => .osc_104,
        .@"110" => .osc_110,
        .@"111" => .osc_111,
        .@"112" => .osc_112,
        .@"113" => .osc_113,
        .@"114" => .osc_114,
        .@"115" => .osc_115,
        .@"116" => .osc_116,
        .@"117" => .osc_117,
        .@"118" => .osc_118,
        .@"119" => .osc_119,
        else => {
            parser.state = .invalid;
            return null;
        },
    };
    parser.command = .{
        .color_operation = .{
            .op = op,
            .requests = parseColor(alloc, op, data) catch |err| list: {
                log.info(
                    "failed to parse OSC {t} color request err={} data={s}",
                    .{ parser.state, err, data },
                );
                break :list .{};
            },
            .terminator = .init(terminator_ch),
        },
    };
    return &parser.command;
}

/// Parse any color operation string. This should NOT include the operation
/// itself, but only the body of the operation. e.g. for "4;a;b;c" the body
/// should be "a;b;c" and the operation should be set accordingly.
///
/// Color parsing is fairly complicated so we pull this out to a specialized
/// function rather than go through our OSC parsing state machine. This is
/// much slower and requires more memory (since we need to buffer the full
/// request) but grants us an easier to understand and testable implementation.
///
/// If color changing ends up being a bottleneck we can optimize this later.
fn parseColor(
    alloc: Allocator,
    op: Operation,
    buf: []const u8,
) ParseError!List {
    var it = std.mem.tokenizeScalar(u8, buf, ';');
    return switch (op) {
        .osc_4 => try parseGetSetAnsiColor(alloc, .osc_4, &it),
        .osc_5 => try parseGetSetAnsiColor(alloc, .osc_5, &it),
        .osc_104 => try parseResetAnsiColor(alloc, .osc_104, &it),
        .osc_105 => try parseResetAnsiColor(alloc, .osc_105, &it),
        .osc_10 => try parseGetSetDynamicColor(alloc, .foreground, &it),
        .osc_11 => try parseGetSetDynamicColor(alloc, .background, &it),
        .osc_12 => try parseGetSetDynamicColor(alloc, .cursor, &it),
        .osc_13 => try parseGetSetDynamicColor(alloc, .pointer_foreground, &it),
        .osc_14 => try parseGetSetDynamicColor(alloc, .pointer_background, &it),
        .osc_15 => try parseGetSetDynamicColor(alloc, .tektronix_foreground, &it),
        .osc_16 => try parseGetSetDynamicColor(alloc, .tektronix_background, &it),
        .osc_17 => try parseGetSetDynamicColor(alloc, .highlight_background, &it),
        .osc_18 => try parseGetSetDynamicColor(alloc, .tektronix_cursor, &it),
        .osc_19 => try parseGetSetDynamicColor(alloc, .highlight_foreground, &it),
        .osc_110 => try parseResetDynamicColor(alloc, .foreground, &it),
        .osc_111 => try parseResetDynamicColor(alloc, .background, &it),
        .osc_112 => try parseResetDynamicColor(alloc, .cursor, &it),
        .osc_113 => try parseResetDynamicColor(alloc, .pointer_foreground, &it),
        .osc_114 => try parseResetDynamicColor(alloc, .pointer_background, &it),
        .osc_115 => try parseResetDynamicColor(alloc, .tektronix_foreground, &it),
        .osc_116 => try parseResetDynamicColor(alloc, .tektronix_background, &it),
        .osc_117 => try parseResetDynamicColor(alloc, .highlight_background, &it),
        .osc_118 => try parseResetDynamicColor(alloc, .tektronix_cursor, &it),
        .osc_119 => try parseResetDynamicColor(alloc, .highlight_foreground, &it),
    };
}

/// OSC 4/5
fn parseGetSetAnsiColor(
    alloc: Allocator,
    comptime op: Operation,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    // Note: in ANY error scenario below we return the accumulated results.
    // This matches the xterm behavior (see misc.c ChangeAnsiColorRequest)

    var result: List = .{};
    errdefer result.deinit(alloc);
    while (true) {
        // We expect a `c; spec` pair. If either doesn't exist then
        // we return the results up to this point.
        const color_str = it.next() orelse return result;
        const spec_str = it.next() orelse return result;

        // Color must be numeric. u9 because that'll fit our palette + special
        const color: u9 = std.fmt.parseInt(
            u9,
            color_str,
            10,
        ) catch return result;

        // Parse the color.
        const target: Target = switch (op) {
            // OSC5 maps directly to the Special enum.
            .osc_5 => .{ .special = std.meta.intToEnum(
                SpecialColor,
                std.math.cast(u3, color) orelse return result,
            ) catch return result },

            // OSC4 maps 0-255 to palette, 256-259 to special offset
            // by the palette count.
            .osc_4 => if (std.math.cast(u8, color)) |idx| .{
                .palette = idx,
            } else .{ .special = std.meta.intToEnum(
                SpecialColor,
                std.math.cast(u3, color - 256) orelse return result,
            ) catch return result },

            else => comptime unreachable,
        };

        // "?" always results in a query.
        if (std.mem.eql(u8, spec_str, "?")) {
            const req = try result.addOne(alloc);
            req.* = .{ .query = target };
            continue;
        }

        const rgb = RGB.parse(spec_str) catch return result;
        const req = try result.addOne(alloc);
        req.* = .{ .set = .{
            .target = target,
            .color = rgb,
        } };
    }
}

/// OSC 104/105: Reset ANSI Colors
fn parseResetAnsiColor(
    alloc: Allocator,
    comptime op: Operation,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    // Note: xterm stops parsing the reset list on any error, but we're
    // more flexible and try the next value. This matches the behavior of
    // Kitty and I don't see a downside to being more flexible here. Hopefully
    // no one depends on the exact behavior of xterm.

    var result: List = .{};
    errdefer result.deinit(alloc);
    while (true) {
        const color_str = it.next() orelse {
            // If no parameters are given, we reset the full table.
            if (result.count() == 0) {
                const req = try result.addOne(alloc);
                req.* = switch (op) {
                    .osc_104 => .reset_palette,
                    .osc_105 => .reset_special,
                    else => comptime unreachable,
                };
            }
            return result;
        };

        // Empty color strings are ignored, not treated as an error.
        if (color_str.len == 0) continue;

        // Color must be numeric. u9 because that'll fit our palette + special
        const color: u9 = std.fmt.parseInt(
            u9,
            color_str,
            10,
        ) catch continue;

        // Parse the color.
        const target: Target = switch (op) {
            // OSC105 maps directly to the Special enum.
            .osc_105 => .{ .special = std.meta.intToEnum(
                SpecialColor,
                std.math.cast(u3, color) orelse continue,
            ) catch continue },

            // OSC104 maps 0-255 to palette, 256-259 to special offset
            // by the palette count.
            .osc_104 => if (std.math.cast(u8, color)) |idx| .{
                .palette = idx,
            } else .{ .special = std.meta.intToEnum(
                SpecialColor,
                std.math.cast(u3, color - 256) orelse continue,
            ) catch continue },

            else => comptime unreachable,
        };

        const req = try result.addOne(alloc);
        req.* = .{ .reset = target };
    }
}

/// OSC 10-19: Get/Set Dynamic Colors
fn parseGetSetDynamicColor(
    alloc: Allocator,
    start: DynamicColor,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    // Note: in ANY error scenario below we return the accumulated results.
    // This matches the xterm behavior (see misc.c ChangeColorsRequest)

    var result: List = .{};
    var color: DynamicColor = start;
    while (true) {
        const spec_str = it.next() orelse return result;

        if (std.mem.eql(u8, spec_str, "?")) {
            const req = try result.addOne(alloc);
            req.* = .{ .query = .{ .dynamic = color } };
        } else {
            const rgb = RGB.parse(spec_str) catch return result;
            const req = try result.addOne(alloc);
            req.* = .{ .set = .{
                .target = .{ .dynamic = color },
                .color = rgb,
            } };
        }

        // Each successive value uses the next color so long as it exists.
        color = color.next() orelse return result;
    }
}

/// OSC 110-119: Reset Dynamic Colors
fn parseResetDynamicColor(
    alloc: Allocator,
    color: DynamicColor,
    it: *std.mem.TokenIterator(u8, .scalar),
) Allocator.Error!List {
    var result: List = .{};
    errdefer result.deinit(alloc);
    if (it.next() != null) return result;
    const req = try result.addOne(alloc);
    req.* = .{ .reset = .{ .dynamic = color } };
    return result;
}

/// A segmented list is used to avoid copying when many operations
/// are given in a single OSC. In most cases, OSC 4/104/etc. send
/// very few so the prealloc is optimized for that.
///
/// The exact prealloc value is chosen arbitrarily assuming most
/// color ops have very few. If we can get empirical data on more
/// typical values we can switch to that.
pub const List = std.SegmentedList(
    Request,
    2,
);

/// A single operation related to the terminal color palette.
pub const Request = union(enum) {
    set: ColoredTarget,
    query: Target,
    reset: Target,
    reset_palette,
    reset_special,
};

pub const Target = union(enum) {
    palette: u8,
    special: SpecialColor,
    dynamic: DynamicColor,
};

pub const ColoredTarget = struct {
    target: Target,
    color: RGB,
};
