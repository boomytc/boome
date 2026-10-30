//! Implements a texture atlas (https://en.wikipedia.org/wiki/Texture_atlas).
//!
//! The implementation is based on "A Thousand Ways to Pack the Bin - A
//! Practical Approach to Two-Dimensional Rectangle Bin Packing" by Jukka
//! Jylänki. This specific implementation is based heavily on
//! Nicolas P. Rougier's freetype-gl project as well as Jukka's C++
//! implementation: https://github.com/juj/RectangleBinPack
//!
//! Limitations that are easy to fix, but I didn't need them:
//!
//!   * Written data must be packed, no support for custom strides.
//!   * Texture is always a square, no ability to set width != height. Note
//!     that regions written INTO the atlas do not have to be square, only
//!     the full atlas texture itself.
//!
const Atlas = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const fastmem = @import("../fastmem.zig");

const log = std.log.scoped(.atlas);

/// Data is the raw texture data.
data: []u8,

/// Width and height of the atlas texture. The current implementation is
/// always square so this is both the width and the height.
size: u32 = 0,

/// The nodes (rectangles) of available space.
nodes: std.ArrayListUnmanaged(Node) = .{},

/// The format of the texture data being written into the Atlas. This must be
/// uniform for all textures in the Atlas. If you have some textures with
/// different formats, you must use multiple atlases or convert the textures.
format: Format = .grayscale,

/// This will be incremented every time the atlas is modified. This is useful
/// for knowing if the texture data has changed since the last time it was
/// sent to the GPU. It is up the user of the atlas to read this value atomically
/// to observe it.
modified: std.atomic.Value(usize) = .{ .raw = 0 },

/// This will be incremented every time the atlas is resized. This is useful
/// for knowing if a GPU texture can be updated in-place or if it requires
/// a resize operation.
resized: std.atomic.Value(usize) = .{ .raw = 0 },

pub const Format = enum(u8) {
    /// 1 byte per pixel grayscale.
    grayscale = 0,
    /// 3 bytes per pixel BGR.
    bgr = 1,
    /// 4 bytes per pixel BGRA.
    bgra = 2,

    pub fn depth(self: Format) u8 {
        return switch (self) {
            .grayscale => 1,
            .bgr => 3,
            .bgra => 4,
        };
    }
};

const Node = struct {
    x: u32,
    y: u32,
    width: u32,
};

pub const Error = error{
    /// Atlas cannot fit the desired region. You must enlarge the atlas.
    AtlasFull,
};

/// A region within the texture atlas. These can be acquired using the
/// "reserve" function. A region reservation is required to write data.
pub const Region = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

/// Number of nodes to preallocate in the list on init.
///
/// TODO: figure out optimal prealloc based on real world usage
const node_prealloc: usize = 64;

pub fn init(alloc: Allocator, size: u32, format: Format) Allocator.Error!Atlas {
    var result = Atlas{
        .data = try alloc.alloc(u8, size * size * format.depth()),
        .size = size,
        .nodes = .{},
        .format = format,
    };
    errdefer result.deinit(alloc);

    // Prealloc some nodes.

    result.nodes = try .initCapacity(alloc, node_prealloc);

    // This sets up our initial state
    result.clear();

    return result;
}

pub fn deinit(self: *Atlas, alloc: Allocator) void {
    self.nodes.deinit(alloc);
    alloc.free(self.data);
    self.* = undefined;
}

/// Reserve a region within the atlas with the given width and height.
///
/// May allocate to add a new rectangle into the internal list of rectangles.
/// This will not automatically enlarge the texture if it is full.
pub fn reserve(
    self: *Atlas,
    alloc: Allocator,
    width: u32,
    height: u32,
) (Allocator.Error || Error)!Region {

    // x, y are populated within :best_idx below
    var region: Region = .{ .x = 0, .y = 0, .width = width, .height = height };

    // If our width/height are 0, then we return the region as-is. This
    // may seem like an error case but it simplifies downstream callers who
    // might be trying to write empty data.
    if (width == 0 and height == 0) return region;

    // Find the location in our nodes list to insert the new node for this region.
    const best_idx: usize = best_idx: {
        var best_height: u32 = std.math.maxInt(u32);
        var best_width: u32 = best_height;
        var chosen: ?usize = null;

        var i: usize = 0;
        while (i < self.nodes.items.len) : (i += 1) {
            // Check if our region fits within this node.
            const y = self.fit(i, width, height) orelse continue;

            const node = self.nodes.items[i];
            if ((y + height) < best_height or
                ((y + height) == best_height and
                    (node.width > 0 and node.width < best_width)))
            {
                chosen = i;
                best_width = node.width;
                best_height = y + height;
                region.x = node.x;
                region.y = y;
            }
        }

        // If we never found a chosen index, the atlas cannot fit our region.
        break :best_idx chosen orelse return Error.AtlasFull;
    };

    // Insert our new node for this rectangle at the exact best index

    try self.nodes.insert(alloc, best_idx, .{
        .x = region.x,
        .y = region.y + height,
        .width = width,
    });
    errdefer comptime unreachable;

    // Optimize our rectangles
    var i: usize = best_idx + 1;
    while (i < self.nodes.items.len) : (i += 1) {
        const node = &self.nodes.items[i];
        const prev = self.nodes.items[i - 1];
        if (node.x < (prev.x + prev.width)) {
            const shrink = prev.x + prev.width - node.x;
            node.x += shrink;
            node.width -|= shrink;
            if (node.width <= 0) {
                _ = self.nodes.orderedRemove(i);
                i -= 1;
                continue;
            }
        }

        break;
    }
    self.merge();

    return region;
}

/// Attempts to fit a rectangle of width x height into the node at idx.
/// The return value is the y within the texture where the rectangle can be
/// placed. The x is the same as the node.
fn fit(self: Atlas, idx: usize, width: u32, height: u32) ?u32 {
    // If the added width exceeds our texture size, it doesn't fit.
    const node = self.nodes.items[idx];
    if ((node.x + width) > (self.size - 1)) return null;

    // Go node by node looking for space that can fit our width.
    var y = node.y;
    var i = idx;
    var width_left = width;
    while (width_left > 0) : (i += 1) {
        const n = self.nodes.items[i];
        if (n.y > y) y = n.y;

        // If the added height exceeds our texture size, it doesn't fit.
        if ((y + height) > (self.size - 1)) return null;

        width_left -|= n.width;
    }

    return y;
}

/// Merge adjacent nodes with the same y value.
fn merge(self: *Atlas) void {
    var i: usize = 0;
    while (i < self.nodes.items.len - 1) {
        const node = &self.nodes.items[i];
        const next = self.nodes.items[i + 1];
        if (node.y == next.y) {
            node.width += next.width;
            _ = self.nodes.orderedRemove(i + 1);
            continue;
        }

        i += 1;
    }
}

/// Set the data associated with a reserved region. The data is expected
/// to fit exactly within the region. The data must be formatted with the
/// proper bpp configured on init.
pub fn set(self: *Atlas, reg: Region, data: []const u8) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));

    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const data_offset = i * reg.width * depth;
        fastmem.copy(
            u8,
            self.data[tex_offset..],
            data[data_offset .. data_offset + (reg.width * depth)],
        );
    }

    _ = self.modified.fetchAdd(1, .monotonic);
}

/// Like `set` but allows specifying a width for the source data and an
/// offset x and y, so that a section of a larger buffer may be copied
/// in to the atlas.
pub fn setFromLarger(
    self: *Atlas,
    reg: Region,
    src: []const u8,
    src_width: u32,
    src_x: u32,
    src_y: u32,
) void {
    assert(reg.x < (self.size - 1));
    assert((reg.x + reg.width) <= (self.size - 1));
    assert(reg.y < (self.size - 1));
    assert((reg.y + reg.height) <= (self.size - 1));

    const depth = self.format.depth();
    var i: u32 = 0;
    while (i < reg.height) : (i += 1) {
        const tex_offset = (((reg.y + i) * self.size) + reg.x) * depth;
        const src_offset = (((src_y + i) * src_width) + src_x) * depth;
        fastmem.copy(
            u8,
            self.data[tex_offset..],
            src[src_offset .. src_offset + (reg.width * depth)],
        );
    }

    _ = self.modified.fetchAdd(1, .monotonic);
}

// Grow the texture to the new size, preserving all previously written data.
pub fn grow(self: *Atlas, alloc: Allocator, size_new: u32) Allocator.Error!void {
    assert(size_new >= self.size);
    if (size_new == self.size) return;

    // We reserve space ahead of time for the new node, so that we
    // won't have to handle any errors after allocating our new data.

    try self.nodes.ensureUnusedCapacity(alloc, 1);

    const data_new = try alloc.alloc(
        u8,
        size_new * size_new * self.format.depth(),
    );

    // Function is infallible from this point.
    errdefer comptime unreachable;

    // Keep track of our old data so that we can copy it.
    const data_old = self.data;
    const size_old = self.size;

    // Update our data and size to our new ones.
    self.data = data_new;
    self.size = size_new;

    // Free the old data once we're done with it.
    defer alloc.free(data_old);

    // Zero the new data out and copy the old data over.
    @memset(self.data, 0);
    self.set(.{
        .x = 0, // don't bother skipping border so we can avoid strides
        .y = 1, // skip the first border row
        .width = size_old,
        .height = size_old - 2, // skip the last border row
    }, data_old[size_old * self.format.depth() ..]);

    // Add the new rectangle for our added righthand space.
    self.nodes.appendAssumeCapacity(.{
        .x = size_old - 1,
        .y = 1,
        .width = size_new - size_old,
    });

    // We are both modified and resized
    _ = self.modified.fetchAdd(1, .monotonic);
    _ = self.resized.fetchAdd(1, .monotonic);
}

// Empty the atlas. This doesn't reclaim any previously allocated memory.
pub fn clear(self: *Atlas) void {
    _ = self.modified.fetchAdd(1, .monotonic);
    @memset(self.data, 0);
    self.nodes.clearRetainingCapacity();

    // Add our initial rectangle. This is the size of the full texture
    // and is the initial rectangle we fit our regions in. We keep a 1px border
    // to avoid artifacting when sampling the texture.
    self.nodes.appendAssumeCapacity(.{ .x = 1, .y = 1, .width = self.size - 2 });
}

/// Dump the atlas as a PPM to a writer, for debug purposes.
/// Only supports grayscale and bgr atlases.
///
/// NOTE: BGR atlases will have the red and blue channels
///       swapped because PPM expects RGB. This would be
///       easy enough to fix so next time someone needs
///       to debug a color atlas they should fix it.
pub fn dump(self: Atlas, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.print(
        \\P{c}
        \\{d} {d}
        \\255
        \\
    , .{
        @as(u8, switch (self.format) {
            .grayscale => '5',
            .bgr => '6',
            else => {
                log.err("Unsupported format for dump: {}", .{self.format});
                @panic("Cannot dump this atlas format.");
            },
        }),
        self.size,
        self.size,
    });
    try writer.writeAll(self.data);
}

/// The wasm-compatible API. This lacks documentation unless the API differs
/// from the standard Zig API. To learn what a function does, just look one
/// level deeper to what Zig function is called and read the documentation there.
pub const Wasm = struct {
    // If you're copying this file (Atlas.zig) out to a separate project,
    // just replace this with the allocator you want to use.
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;
    const js = @import("zig-js");

    export fn atlas_new(size: u32, format: u8) ?*Atlas {
        const atlas = init(
            alloc,
            size,
            @enumFromInt(format),
        ) catch return null;
        const result = alloc.create(Atlas) catch return null;
        result.* = atlas;
        return result;
    }

    export fn atlas_free(ptr: ?*Atlas) void {
        if (ptr) |v| {
            v.deinit(alloc);
            alloc.destroy(v);
        }
    }

    /// The return value for this should be freed by the caller with "free".
    export fn atlas_reserve(self: *Atlas, width: u32, height: u32) ?*Region {
        return atlas_reserve_(self, width, height) catch return null;
    }

    fn atlas_reserve_(self: *Atlas, width: u32, height: u32) !*Region {
        const reg = try self.reserve(alloc, width, height);
        const result = try alloc.create(Region);
        errdefer alloc.destroy(result);
        _ = try wasm.toHostOwned(result);
        result.* = reg;
        return result;
    }

    export fn atlas_set(self: *Atlas, reg: *Region, data: [*]const u8, len: usize) void {
        self.set(reg.*, data[0..len]);
    }

    export fn atlas_grow(self: *Atlas, size_new: u32) bool {
        self.grow(alloc, size_new) catch return false;
        return true;
    }

    export fn atlas_clear(self: *Atlas) void {
        self.clear();
    }

    /// This creates a Canvas element identified by the id returned that
    /// the caller can draw into the DOM to visualize the atlas. The returned
    /// ID must be freed from the JS runtime by calling "zigjs.deleteValue".
    export fn atlas_debug_canvas(self: *Atlas) u32 {
        return atlas_debug_canvas_(self) catch |err| {
            log.warn("error dumping atlas canvas err={}", .{err});
            return 0;
        };
    }

    fn atlas_debug_canvas_(self: *Atlas) !u32 {
        // Create our canvas
        const doc = try js.global.get(js.Object, "document");
        defer doc.deinit();
        const canvas = try doc.call(js.Object, "createElement", .{js.string("canvas")});
        errdefer canvas.deinit();

        // Setup our canvas size
        {
            try canvas.set("width", self.size);
            try canvas.set("height", self.size);

            const width_str = try std.fmt.allocPrint(alloc, "{d}px", .{self.size});
            defer alloc.free(width_str);

            const style = try canvas.get(js.Object, "style");
            defer style.deinit();
            try style.set("width", js.string(width_str));
            try style.set("height", js.string(width_str));
        }

        // This will return the same context on subsequent calls so it
        // is important to reset it.
        const ctx = try canvas.call(js.Object, "getContext", .{js.string("2d")});
        defer ctx.deinit();

        // We need to draw pixels so this is format dependent.
        const buf: []u8 = switch (self.format) {
            .bgra => buf: {
                // Convert from BGRA to RGBA by swapping every R and B.
                var buf: []u8 = try alloc.dupe(u8, self.data);
                errdefer alloc.free(buf);
                var i: usize = 0;
                while (i < self.data.len) : (i += 4) {
                    std.mem.swap(u8, &buf[i], &buf[i + 2]);
                }
                break :buf buf;
            },

            .grayscale => buf: {
                // Convert from A8 to RGBA so every 4th byte is set to a value.
                var buf: []u8 = try alloc.alloc(u8, self.data.len * 4);
                errdefer alloc.free(buf);
                @memset(buf, 0);
                for (self.data, 0..) |value, i| {
                    buf[(i * 4) + 3] = value;
                }
                break :buf buf;
            },

            else => return error.UnsupportedAtlasFormat,
        };
        defer if (buf.ptr != self.data.ptr) alloc.free(buf);

        // Create an ImageData from our buffer and then write it to the canvas
        const image_data: js.Object = data: {
            // Get our runtime memory
            const mem = try js.runtime.get(js.Object, "memory");
            defer mem.deinit();
            const mem_buf = try mem.get(js.Object, "buffer");
            defer mem_buf.deinit();

            // Create an array that points to our buffer
            const arr = arr: {
                const Uint8ClampedArray = try js.global.get(js.Object, "Uint8ClampedArray");
                defer Uint8ClampedArray.deinit();
                const arr = try Uint8ClampedArray.new(.{ mem_buf, buf.ptr, buf.len });
                if (!wasm.shared_mem) break :arr arr;

                // If we're sharing memory then we have to copy the data since
                // we can't set ImageData directly using a SharedArrayBuffer.
                defer arr.deinit();
                break :arr try arr.call(js.Object, "slice", .{});
            };
            defer arr.deinit();

            // Create the image data from our array
            const ImageData = try js.global.get(js.Object, "ImageData");
            defer ImageData.deinit();
            const data = try ImageData.new(.{ arr, self.size, self.size });
            errdefer data.deinit();

            break :data data;
        };
        defer image_data.deinit();

        // Draw it
        try ctx.call(void, "putImageData", .{ image_data, 0, 0 });

        const id = @as(js.Ref, @bitCast(@intFromEnum(canvas.value))).id;
        return id;
    }
};
