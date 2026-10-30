const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const text = @import("../text.zig");
const c = @import("c.zig").c;

pub const Framesetter = opaque {
    pub fn createWithAttributedString(str: *foundation.AttributedString) Allocator.Error!*Framesetter {
        return @as(
            ?*Framesetter,
            @ptrFromInt(@intFromPtr(c.CTFramesetterCreateWithAttributedString(
                @ptrCast(str),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Framesetter) void {
        foundation.CFRelease(self);
    }

    pub fn createFrame(
        self: *Framesetter,
        range: foundation.Range,
        path: *graphics.Path,
        attrs: ?*foundation.Dictionary,
    ) !*text.Frame {
        return @as(
            ?*text.Frame,
            @ptrFromInt(@intFromPtr(c.CTFramesetterCreateFrame(
                @ptrCast(self),
                @bitCast(range),
                @ptrCast(path),
                @ptrCast(attrs),
            ))),
        ) orelse error.FrameCreateFailed;
    }
};
