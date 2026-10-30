//! Kitty's clipboard protocol (OSC 5522)
//! Specification: https://sw.kovidgoyal.net/kitty/clipboard/
//! https://rockorager.dev/misc/bracketed-paste-mime/

const std = @import("std");
const build_options = @import("terminal_options");

const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;
const Terminator = @import("../../osc.zig").Terminator;
const encoding = @import("../encoding.zig");

const log = std.log.scoped(.kitty_clipboard_protocol);

pub const OSC = struct {
    /// The raw metadata that was received. It can be parsed by using the `readOption` method.
    metadata: []const u8,
    /// The raw payload. It may be Base64 encoded, check the `e` option.
    payload: ?[]const u8,
    /// The terminator that was used in case we need to send a response.
    terminator: Terminator,

    /// Decode an option from the metadata.
    pub fn readOption(self: OSC, comptime key: Option) ?key.Type() {
        return key.read(self.metadata);
    }
};

pub const Location = enum {
    primary,

    pub fn init(str: []const u8) ?Location {
        return std.meta.stringToEnum(Location, str);
    }
};

pub const Operation = enum {
    read,
    walias,
    wdata,
    write,

    pub fn init(str: []const u8) ?Operation {
        return std.meta.stringToEnum(Operation, str);
    }
};

pub const Status = enum {
    DATA,
    DONE,
    EBUSY,
    EINVAL,
    EIO,
    ENOSYS,
    EPERM,
    OK,

    pub fn init(str: []const u8) ?Status {
        return std.meta.stringToEnum(Status, str);
    }
};

pub const Option = enum {
    id,
    loc,
    mime,
    name,
    password,
    pw,
    status,
    type,

    pub fn Type(comptime key: Option) type {
        return switch (key) {
            .id => []const u8,
            .loc => Location,
            .mime => []const u8,
            .name => []const u8,
            .password => []const u8,
            .pw => []const u8,
            .status => Status,
            .type => Operation,
        };
    }

    /// Read the option value from the raw metadata string.
    pub fn read(
        comptime key: Option,
        metadata: []const u8,
    ) ?key.Type() {
        const value: []const u8 = value: {
            var pos: usize = 0;
            while (pos < metadata.len) {
                // skip any whitespace
                while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
                // bail if we are out of metadata
                if (pos >= metadata.len) return null;
                if (!std.mem.startsWith(u8, metadata[pos..], @tagName(key))) {
                    // this isn't the key we are looking for, skip to the next option, or bail if
                    // there is no next option
                    pos = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse return null;
                    pos += 1;
                    continue;
                }
                // skip past the key
                pos += @tagName(key).len;
                // skip any whitespace
                while (pos < metadata.len and std.ascii.isWhitespace(metadata[pos])) pos += 1;
                // bail if we are out of metadata
                if (pos >= metadata.len) return null;
                // a valid option has an '='
                if (metadata[pos] != '=') return null;
                // the end of the value is bounded by a ':' or the end of the metadata
                const end = std.mem.indexOfScalarPos(u8, metadata, pos, ':') orelse metadata.len;
                const start = pos + 1;
                // strip any leading or trailing whitespace
                break :value std.mem.trim(u8, metadata[start..end], &std.ascii.whitespace);
            }
            // the key was not found
            return null;
        };

        // return the parsed value
        return switch (key) {
            .id => parseIdentifier(value),
            .loc => .init(value),
            .mime => value,
            .name => value,
            .password => value,
            .pw => value,
            .status => .init(value),
            .type => .init(value),
        };
    }
};

/// Characters that are valid in identifiers.
const valid_identifier_characters: []const u8 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_+.";

fn isValidIdentifier(str: []const u8) bool {
    if (str.len == 0) return false;
    return std.mem.indexOfNone(u8, str, valid_identifier_characters) == null;
}

fn parseIdentifier(str: []const u8) ?[]const u8 {
    if (isValidIdentifier(str)) return str;
    return null;
}

pub fn parse(parser: *Parser, terminator_ch: ?u8) ?*Command {
    assert(parser.state == .@"5522");

    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };

    const data = writer.buffered();

    const metadata: []const u8, const payload: ?[]const u8 = result: {
        const start = std.mem.indexOfScalar(u8, data, ';') orelse break :result .{ data, null };
        break :result .{ data[0..start], data[start + 1 .. data.len] };
    };

    parser.command = .{
        .kitty_clipboard_protocol = .{
            .metadata = metadata,
            .payload = payload,
            .terminator = .init(terminator_ch),
        },
    };

    return &parser.command;
}
