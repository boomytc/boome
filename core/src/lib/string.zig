const std = @import("std");

// This is a copy of std.mem.cutPrefix from 0.16. Once Ghostty has been ported
// to 0.16 this can be removed.

/// If slice starts with prefix, returns the rest of slice starting at
/// prefix.len.
pub fn cutPrefix(comptime T: type, slice: []const T, prefix: []const T) ?[]const T {
    return if (std.mem.startsWith(T, slice, prefix)) slice[prefix.len..] else null;
}
