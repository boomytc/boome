/// A single entry within our SSH entry cache. Our SSH entry cache
/// stores which hosts we've sent our terminfo to so that we don't have
/// to send it again. It doesn't store any sensitive information.
const Entry = @This();

const std = @import("std");

hostname: []const u8,
timestamp: i64,
terminfo_version: []const u8,

pub fn parse(line: []const u8) ?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Parse format: hostname|timestamp|terminfo_version
    var iter = std.mem.tokenizeScalar(u8, trimmed, '|');
    const hostname = iter.next() orelse return null;
    const timestamp_str = iter.next() orelse return null;
    const terminfo_version = iter.next() orelse "xterm-ghostty";
    const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch |err| {
        std.log.warn(
            "Invalid timestamp in cache entry: {s} err={}",
            .{ timestamp_str, err },
        );
        return null;
    };

    return .{
        .hostname = hostname,
        .timestamp = timestamp,
        .terminfo_version = terminfo_version,
    };
}

pub const FormatError = std.Io.Writer.Error;

pub fn format(self: Entry, writer: *std.Io.Writer) FormatError!void {
    try writer.print(
        "{s}|{d}|{s}\n",
        .{ self.hostname, self.timestamp, self.terminfo_version },
    );
}

pub fn isExpired(self: Entry, expire_days_: ?u32) bool {
    const expire_days = expire_days_ orelse return false;
    const now = std.time.timestamp();
    const age_days = @divTrunc(now -| self.timestamp, std.time.s_per_day);
    return age_days > expire_days;
}
