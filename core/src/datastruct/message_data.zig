const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;

/// Creates a union that can be used to accommodate data that fit within an array,
/// are a stable pointer, or require deallocation. This is helpful for thread
/// messaging utilities.
pub fn MessageData(comptime Elem: type, comptime small_size: comptime_int) type {
    return union(enum) {
        pub const Self = @This();

        pub const Small = struct {
            pub const Max = small_size;
            pub const Array = [Max]Elem;
            pub const Len = std.math.IntFittingRange(0, small_size);
            data: Array = undefined,
            len: Len = 0,
        };

        pub const Alloc = struct {
            alloc: Allocator,
            data: []Elem,
        };

        pub const Stable = []const Elem;

        /// A small write where the data fits into this union size.
        small: Small,

        /// A stable pointer so we can just pass the slice directly through.
        /// This is useful i.e. for const data.
        stable: Stable,

        /// Allocated and must be freed with the provided allocator. This
        /// should be rarely used.
        alloc: Alloc,

        /// Initializes the union for a given data type. This will
        /// attempt to fit into a small value if possible, otherwise
        /// will allocate and put into alloc.
        ///
        /// This can't and will never detect stable pointers.
        pub fn init(alloc: Allocator, data: anytype) !Self {
            switch (@typeInfo(@TypeOf(data))) {
                .pointer => |info| {
                    assert(info.size == .slice);
                    assert(info.child == Elem);

                    // If it fits in our small request, do that.
                    if (data.len <= Small.Max) {
                        var buf: Small.Array = undefined;
                        @memcpy(buf[0..data.len], data);
                        return Self{
                            .small = .{
                                .data = buf,
                                .len = @intCast(data.len),
                            },
                        };
                    }

                    // Otherwise, allocate
                    const buf = try alloc.dupe(Elem, data);
                    errdefer alloc.free(buf);
                    return Self{
                        .alloc = .{
                            .alloc = alloc,
                            .data = buf,
                        },
                    };
                },

                else => unreachable,
            }
        }

        pub fn deinit(self: Self) void {
            switch (self) {
                .small, .stable => {},
                .alloc => |v| v.alloc.free(v.data),
            }
        }

        /// Returns a const slice of the data pointed to by this request.
        pub fn slice(self: *const Self) []const Elem {
            return switch (self.*) {
                .small => |*v| v.data[0..v.len],
                .stable => |v| v,
                .alloc => |v| v.data,
            };
        }
    };
}
