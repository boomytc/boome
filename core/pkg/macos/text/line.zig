const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const graphics = @import("../graphics.zig");
const c = @import("c.zig").c;

pub const Line = opaque {
    pub fn createWithAttributedString(str: *foundation.AttributedString) Allocator.Error!*Line {
        return @as(
            ?*Line,
            @ptrFromInt(@intFromPtr(c.CTLineCreateWithAttributedString(
                @ptrCast(str),
            ))),
        ) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *Line) void {
        foundation.CFRelease(self);
    }

    pub fn getGlyphCount(self: *Line) usize {
        return @intCast(c.CTLineGetGlyphCount(
            @ptrCast(self),
        ));
    }

    pub fn getBoundsWithOptions(
        self: *Line,
        opts: LineBoundsOptions,
    ) graphics.Rect {
        return @bitCast(c.CTLineGetBoundsWithOptions(
            @ptrCast(self),
            @bitCast(opts),
        ));
    }

    pub fn getTypographicBounds(
        self: *Line,
        ascent: ?*f64,
        descent: ?*f64,
        leading: ?*f64,
    ) f64 {
        return c.CTLineGetTypographicBounds(
            @ptrCast(self),
            ascent,
            descent,
            leading,
        );
    }

    pub fn getGlyphRuns(self: *Line) *foundation.Array {
        return @ptrCast(@constCast(c.CTLineGetGlyphRuns(@ptrCast(self))));
    }
};

pub const LineBoundsOptions = packed struct {
    exclude_leading: bool = false,
    exclude_shifts: bool = false,
    hanging_punctuation: bool = false,
    glyph_path_bounds: bool = false,
    use_optical_bounds: bool = false,
    language_extents: bool = false,
    _padding: u58 = 0,
};
