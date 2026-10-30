const std = @import("std");
const options = @import("build_options");
const assert = @import("../quirks.zig").inlineAssert;
const indexOf = @import("index_of.zig").indexOf;

// vt.cpp
extern "c" fn ghostty_simd_decode_utf8_until_control_seq(
    input: [*]const u8,
    count: usize,
    output: [*]u32,
    output_count: *usize,
) usize;

const DecodeResult = struct {
    consumed: usize,
    decoded: usize,
};

pub fn utf8DecodeUntilControlSeq(
    input: []const u8,
    output: []u32,
) DecodeResult {
    assert(output.len >= input.len);

    if (comptime options.simd) {
        var decoded: usize = 0;
        const consumed = ghostty_simd_decode_utf8_until_control_seq(
            input.ptr,
            input.len,
            output.ptr,
            &decoded,
        );

        return .{ .consumed = consumed, .decoded = decoded };
    }

    return utf8DecodeUntilControlSeqScalar(input, output);
}

fn utf8DecodeUntilControlSeqScalar(
    input: []const u8,
    output: []u32,
) DecodeResult {
    // Find our escape
    const idx = indexOf(input, 0x1B) orelse input.len;
    const decode = input[0..idx];

    // Go through and decode one item at a time.
    var decode_offset: usize = 0;
    var decode_count: usize = 0;
    while (decode_offset < decode.len) {
        const decode_rem = decode[decode_offset..];
        const cp_len = std.unicode.utf8ByteSequenceLength(decode_rem[0]) catch {
            // Note, this is matching our SIMD behavior, but it is admittedly
            // a bit weird. See our "decode invalid leading byte" test too.
            // SIMD should be our source of truth then we copy behavior here.
            break;
        };

        // If we don't have that number of bytes available. we finish. We
        // assume this is a partial input and we defer to the future.
        if (decode_rem.len < cp_len) break;

        // We have the bytes available, so move forward
        const cp_bytes = decode_rem[0..cp_len];
        decode_offset += cp_len;
        if (std.unicode.utf8Decode(cp_bytes)) |cp| {
            output[decode_count] = @intCast(cp);
            decode_count += 1;
        } else |_| {
            // If decoding failed, we replace the leading byte with the
            // replacement char and then continue decoding after that
            // byte. This matches the SIMD behavior and is tested by the
            // "invalid UTF-8" tests.
            output[decode_count] = 0xFFFD;
            decode_count += 1;
            decode_offset -= cp_len - 1;
        }
    }

    return .{
        .consumed = decode_offset,
        .decoded = decode_count,
    };
}
