// The contents of this file is largely based on testing.zig from the Zig 0.15.1
// stdlib, distributed under the MIT license, copyright (c) Zig contributors
const std = @import("std");

/// A deep equality comparison function that works for most types. We
/// add types as necessary. It defers to `equal` decls on types that support
/// decls.
pub fn deepEqual(comptime T: type, old: T, new: T) bool {
    // Do known named types first
    switch (T) {
        inline []const u8,
        [:0]const u8,
        => return std.mem.eql(u8, old, new),

        []const [:0]const u8,
        => {
            if (old.len != new.len) return false;
            for (old, new) |a, b| {
                if (!std.mem.eql(u8, a, b)) return false;
            }

            return true;
        },

        else => {},
    }

    // Back into types of types
    switch (@typeInfo(T)) {
        .void => return true,

        inline .bool,
        .int,
        .float,
        .@"enum",
        => return old == new,

        .optional => |info| {
            if (old == null and new == null) return true;
            if (old == null or new == null) return false;
            return deepEqual(info.child, old.?, new.?);
        },

        .array => |info| for (old, new) |old_elem, new_elem| {
            if (!deepEqual(
                info.child,
                old_elem,
                new_elem,
            )) return false;
        } else return true,

        .@"struct" => |info| {
            if (@hasDecl(T, "equal")) return old.equal(new);

            // If a struct doesn't declare an "equal" function, we fall back
            // to a recursive field-by-field compare.
            inline for (info.fields) |field_info| {
                if (!deepEqual(
                    field_info.type,
                    @field(old, field_info.name),
                    @field(new, field_info.name),
                )) return false;
            }
            return true;
        },

        .@"union" => |info| {
            if (@hasDecl(T, "equal")) return old.equal(new);

            const tag_type = info.tag_type.?;
            const old_tag = std.meta.activeTag(old);
            const new_tag = std.meta.activeTag(new);
            if (old_tag != new_tag) return false;

            inline for (info.fields) |field_info| {
                if (@field(tag_type, field_info.name) == old_tag) {
                    return deepEqual(
                        field_info.type,
                        @field(old, field_info.name),
                        @field(new, field_info.name),
                    );
                }
            }

            unreachable;
        },

        else => {
            @compileLog(T);
            @compileError("unsupported field type");
        },
    }
}
