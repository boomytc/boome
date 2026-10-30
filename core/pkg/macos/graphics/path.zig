const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const c = @import("c.zig").c;

pub const Path = opaque {
    pub fn createWithRect(
        rect: graphics.Rect,
        transform: ?*const graphics.AffineTransform,
    ) Allocator.Error!*Path {
        return @as(
            ?*Path,
            @ptrFromInt(@intFromPtr(c.CGPathCreateWithRect(
                @bitCast(rect),
                @ptrCast(transform),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Path) void {
        foundation.CFRelease(self);
    }
};

pub const MutablePath = opaque {
    pub fn create() Allocator.Error!*MutablePath {
        return @as(
            ?*MutablePath,
            @ptrFromInt(@intFromPtr(c.CGPathCreateMutable())),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *MutablePath) void {
        foundation.CFRelease(self);
    }

    pub fn addRect(
        self: *MutablePath,
        transform: ?*const graphics.AffineTransform,
        rect: graphics.Rect,
    ) void {
        c.CGPathAddRect(
            @ptrCast(self),
            @ptrCast(transform),
            @bitCast(rect),
        );
    }

    pub fn getBoundingBox(self: *MutablePath) graphics.Rect {
        return @bitCast(c.CGPathGetBoundingBox(@ptrCast(self)));
    }
};
