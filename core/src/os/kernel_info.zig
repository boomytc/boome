const std = @import("std");
const builtin = @import("builtin");

pub fn getKernelInfo(alloc: std.mem.Allocator) ?[]const u8 {
    if (comptime builtin.os.tag != .linux) return null;
    const path = "/proc/sys/kernel/osrelease";
    var file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    // 128 bytes should be enough to hold the kernel information
    const kernel_info = file.readToEndAlloc(alloc, 128) catch return null;
    defer alloc.free(kernel_info);
    return alloc.dupe(u8, std.mem.trim(u8, kernel_info, &std.ascii.whitespace)) catch return null;
}
