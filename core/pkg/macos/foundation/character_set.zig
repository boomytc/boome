const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const foundation = @import("../foundation.zig");
const c = @import("c.zig").c;

pub const CharacterSet = opaque {
    pub fn createWithCharactersInString(
        str: *foundation.String,
    ) Allocator.Error!*CharacterSet {
        return @as(?*CharacterSet, @ptrFromInt(@intFromPtr(c.CFCharacterSetCreateWithCharactersInString(
            null,
            @ptrCast(str),
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn createWithCharactersInRange(
        range: foundation.Range,
    ) Allocator.Error!*CharacterSet {
        return @as(?*CharacterSet, @ptrFromInt(@intFromPtr(c.CFCharacterSetCreateWithCharactersInRange(
            null,
            @bitCast(range),
        )))) orelse Allocator.Error.OutOfMemory;
    }

    pub fn release(self: *CharacterSet) void {
        c.CFRelease(self);
    }
};
