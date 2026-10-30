const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const graphics = @import("../graphics.zig");
const Context = @import("context.zig").Context;
const c = @import("c.zig").c;

pub const BitmapContext = opaque {
    pub const context = Context(BitmapContext);

    pub fn create(
        data: ?[]u8,
        width: usize,
        height: usize,
        bits_per_component: usize,
        bytes_per_row: usize,
        space: *graphics.ColorSpace,
        opts: c_uint,
    ) Allocator.Error!*BitmapContext {
        return @as(
            ?*BitmapContext,
            @ptrFromInt(@intFromPtr(c.CGBitmapContextCreate(
                @ptrCast(if (data) |d| d.ptr else null),
                width,
                height,
                bits_per_component,
                bytes_per_row,
                @ptrCast(space),
                opts,
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }
};
