const std = @import("std");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const kitty_color = @import("../../kitty/color.zig");
const RGB = @import("../../color.zig").RGB;

const log = std.log.scoped(.osc_kitty_color);

/// Parse OSC 21, the Kitty Color Protocol.
pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"21");

    const alloc = parser.alloc orelse {
        parser.state = .invalid;
        return null;
    };
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    parser.command = .{
        .kitty_color_protocol = .{
            .list = .empty,
            .terminator = .init(terminator_ch),
        },
    };
    const list = &parser.command.kitty_color_protocol.list;
    const data = writer.buffered();
    var kv_it = std.mem.splitScalar(u8, data, ';');
    while (kv_it.next()) |kv| {
        if (list.items.len >= @as(usize, kitty_color.Kind.max) * 2) {
            log.warn("exceeded limit for number of keys in kitty color protocol, ignoring", .{});
            parser.state = .invalid;
            return null;
        }
        var it = std.mem.splitScalar(u8, kv, '=');
        const k = it.next() orelse continue;
        if (k.len == 0) {
            log.warn("zero length key in kitty color protocol", .{});
            continue;
        }
        const key = kitty_color.Kind.parse(k) orelse {
            log.warn("unknown key in kitty color protocol: {s}", .{k});
            continue;
        };
        const value = std.mem.trim(u8, it.rest(), " ");
        if (value.len == 0) {
            list.append(alloc, .{ .reset = key }) catch |err| {
                log.warn("unable to append kitty color protocol option: {}", .{err});
                continue;
            };
        } else if (std.mem.eql(u8, "?", value)) {
            list.append(alloc, .{ .query = key }) catch |err| {
                log.warn("unable to append kitty color protocol option: {}", .{err});
                continue;
            };
        } else {
            list.append(alloc, .{
                .set = .{
                    .key = key,
                    .color = RGB.parse(value) catch |err| switch (err) {
                        error.InvalidFormat => {
                            log.warn("invalid color format in kitty color protocol: {s}", .{value});
                            continue;
                        },
                    },
                },
            }) catch |err| {
                log.warn("unable to append kitty color protocol option: {}", .{err});
                continue;
            };
        }
    }
    return &parser.command;
}
