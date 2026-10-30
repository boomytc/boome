const paste = @import("../../input/paste.zig");

pub fn is_safe(data: ?[*]const u8, len: usize) callconv(.c) bool {
    const slice: []const u8 = if (data) |v| v[0..len] else &.{};
    return paste.isSafe(slice);
}
