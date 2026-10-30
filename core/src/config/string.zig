const std = @import("std");

/// Parse a string literal into a byte array. The string can contain
/// any valid Zig string literal escape sequences.
///
/// The output buffer never needs to be larger than the input buffer.
/// The buffers may alias.
pub fn parse(out: []u8, bytes: []const u8) ![]u8 {
    var dst_i: usize = 0;
    var src_i: usize = 0;
    while (src_i < bytes.len) {
        if (dst_i >= out.len) return error.OutOfMemory;

        // If this byte is not beginning an escape sequence we copy.
        const b = bytes[src_i];
        if (b != '\\') {
            out[dst_i] = b;
            dst_i += 1;
            src_i += 1;
            continue;
        }

        // Parse the escape sequence
        switch (std.zig.string_literal.parseEscapeSequence(
            bytes,
            &src_i,
        )) {
            .failure => return error.InvalidString,
            .success => |cp| dst_i += try std.unicode.utf8Encode(
                cp,
                out[dst_i..],
            ),
        }
    }

    return out[0..dst_i];
}

/// Creates an iterator that requires no allocation to extract codepoints
/// from the string literal, parsing escape sequences as it goes.
pub fn codepointIterator(bytes: []const u8) CodepointIterator {
    return .{ .bytes = bytes, .i = 0 };
}

pub const CodepointIterator = struct {
    bytes: []const u8,
    i: usize,

    pub fn next(self: *CodepointIterator) error{InvalidString}!?u21 {
        if (self.i >= self.bytes.len) return null;
        switch (self.bytes[self.i]) {
            // An escape sequence
            '\\' => return switch (std.zig.string_literal.parseEscapeSequence(
                self.bytes,
                &self.i,
            )) {
                .failure => error.InvalidString,
                .success => |cp| cp,
            },

            // Not an escape, parse as UTF-8
            else => |start| {
                const cp_len = std.unicode.utf8ByteSequenceLength(start) catch
                    return error.InvalidString;
                defer self.i += cp_len;
                return std.unicode.utf8Decode(self.bytes[self.i..][0..cp_len]) catch
                    return error.InvalidString;
            },
        }
    }
};
