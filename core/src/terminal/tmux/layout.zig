const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// A tmux layout.
///
/// This is a tree structure so by definition it pretty much needs to be
/// allocated. We leave allocation up to the user of this struct, but
/// a general recommendation is to use an arena allocator for simplicity
/// in freeing the entire layout at once.
pub const Layout = struct {
    /// Width, height of the node
    width: usize,
    height: usize,

    /// X and Y offset from the top-left corner of the window.
    x: usize,
    y: usize,

    /// The content of this node, either a pane (leaf) or more nodes
    /// (split) horizontally or vertically.
    content: Content,

    pub const Content = union(enum) {
        pane: usize,
        horizontal: []const Layout,
        vertical: []const Layout,
    };

    pub const ParseError = Allocator.Error || error{SyntaxError};

    /// Parse a layout string that includes a 4-character checksum prefix.
    ///
    /// The expected format is: `XXXX,layout_string` where XXXX is the
    /// 4-character hexadecimal checksum and the layout string follows
    /// after the comma. For example: `f8f9,80x24,0,0{40x24,0,0,1,40x24,40,0,2}`.
    ///
    /// Returns `ChecksumMismatch` if the checksum doesn't match the layout.
    /// Returns `SyntaxError` if the format is invalid.
    pub fn parseWithChecksum(
        alloc: Allocator,
        str: []const u8,
    ) (ParseError || error{ChecksumMismatch})!Layout {
        // If the string is less than 5 characters, it can't possibly
        // be correct. 4-char checksum + comma. In practice it should
        // be even longer, but that'll fail parse later.
        if (str.len < 5) return error.SyntaxError;
        if (str[4] != ',') return error.SyntaxError;

        // The layout string should start with a 4-character checksum.
        const checksum: Checksum = .calculate(str[5..]);
        if (!std.mem.startsWith(
            u8,
            str,
            &checksum.asString(),
        )) return error.ChecksumMismatch;

        // Checksum matches, parse the rest.
        return try parse(alloc, str[5..]);
    }

    /// Parse a layout string into a Layout structure. The given allocator
    /// will be used for all allocations within the layout. Note that
    /// individual nodes can't be freed so this allocator must be some
    /// kind of arena allocator.
    ///
    /// The layout string must be fully provided as a single string.
    /// Layouts are generally small so this should not be a problem.
    ///
    /// Tmux layout strings have the following format:
    ///
    /// - WxH,X,Y,ID Leaf pane: width×height, x-offset, y-offset, pane ID
    /// - WxH,X,Y{...} Horizontal split (left-right), children comma-separated
    /// - WxH,X,Y[...] Vertical split (top-bottom), children comma-separated
    pub fn parse(alloc: Allocator, str: []const u8) ParseError!Layout {
        var offset: usize = 0;
        const root = try parseNext(
            alloc,
            str,
            &offset,
        );
        if (offset != str.len) return error.SyntaxError;
        return root;
    }

    fn parseNext(
        alloc: Allocator,
        str: []const u8,
        offset: *usize,
    ) ParseError!Layout {
        // Find the first `x` to grab the width.
        const width: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            'x',
        )) |idx| width: {
            defer offset.* += idx + 1; // Consume `x`
            break :width std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find the height, up to a comma.
        const height: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| height: {
            defer offset.* += idx + 1; // Consume `,`
            break :height std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find X
        const x: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| x: {
            defer offset.* += idx + 1; // Consume `,`
            break :x std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find Y, which can end in any of `,{,[`
        const y: usize = if (std.mem.indexOfAny(
            u8,
            str[offset.*..],
            ",{[",
        )) |idx| y: {
            defer offset.* += idx; // Don't consume the delimiter!
            break :y std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Determine our child node.
        const content: Layout.Content = switch (str[offset.*]) {
            ',' => content: {
                // Consume the delimiter
                offset.* += 1;

                // Leaf pane. Read up to `,}]` because we may be in
                // a set of nodes. If none exist, end of string is fine.
                const idx = std.mem.indexOfAny(
                    u8,
                    str[offset.*..],
                    ",}]",
                ) orelse str.len - offset.*;

                defer offset.* += idx; // Consume the pane ID, not the delimiter
                const pane_id = std.fmt.parseInt(
                    usize,
                    str[offset.* .. offset.* + idx],
                    10,
                ) catch return error.SyntaxError;

                break :content .{ .pane = pane_id };
            },

            '{', '[' => |opening| content: {
                var nodes: std.ArrayList(Layout) = .empty;
                defer nodes.deinit(alloc);

                // Move beyond our opening
                offset.* += 1;

                while (true) {
                    try nodes.append(alloc, try parseNext(
                        alloc,
                        str,
                        offset,
                    ));

                    // We should not reach the end of string here because
                    // we expect a closing bracket.
                    if (offset.* >= str.len) return error.SyntaxError;

                    // If it is a comma, we expect another node.
                    if (str[offset.*] == ',') {
                        offset.* += 1; // Consume
                        continue;
                    }

                    // We expect a closing bracket now.
                    switch (opening) {
                        '{' => if (str[offset.*] != '}') return error.SyntaxError,
                        '[' => if (str[offset.*] != ']') return error.SyntaxError,
                        else => return error.SyntaxError,
                    }

                    // Successfully parsed all children.
                    offset.* += 1; // Consume closing bracket
                    break :content switch (opening) {
                        '{' => .{ .horizontal = try nodes.toOwnedSlice(alloc) },
                        '[' => .{ .vertical = try nodes.toOwnedSlice(alloc) },
                        else => unreachable,
                    };
                }
            },

            // indexOfAny above guarantees we have only the above
            else => unreachable,
        };

        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .content = content,
        };
    }
};

pub const Checksum = enum(u16) {
    _,

    /// Calculate the checksum of a tmux layout string.
    /// The algorithm rotates the checksum right by 1 bit (with wraparound)
    /// and adds the ASCII value of each character.
    pub fn calculate(str: []const u8) Checksum {
        var result: u16 = 0;
        for (str) |c| {
            // Rotate right by 1: (result >> 1) + ((result & 1) << 15)
            result = (result >> 1) | ((result & 1) << 15);
            result +%= c;
        }

        return @enumFromInt(result);
    }

    /// Convert the checksum to a 4-character hexadecimal string. This
    /// is always zero-padded to match the tmux implementation
    /// (in layout-custom.c).
    pub fn asString(self: Checksum) [4]u8 {
        const value = @intFromEnum(self);
        const charset = "0123456789abcdef";
        return .{
            charset[(value >> 12) & 0xf],
            charset[(value >> 8) & 0xf],
            charset[(value >> 4) & 0xf],
            charset[value & 0xf],
        };
    }
};
