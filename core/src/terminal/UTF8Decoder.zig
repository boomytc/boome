//! DFA-based non-allocating error-replacing UTF-8 decoder.
//!
//! This implementation is based largely on the excellent work of
//! Bjoern Hoehrmann, with slight modifications to support error-
//! replacement.
//!
//! For details on Bjoern's DFA-based UTF-8 decoder, see
//! http://bjoern.hoehrmann.de/utf-8/decoder/dfa (MIT licensed)
const UTF8Decoder = @This();

const std = @import("std");

const log = std.log.scoped(.utf8decoder);

// zig fmt: off
const char_classes = [_]u4{
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,  0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
   1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,  9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,
   7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,  7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,
   8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2,  2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,
  10,3,3,3,3,3,3,3,3,3,3,3,3,4,3,3, 11,6,6,6,5,8,8,8,8,8,8,8,8,8,8,8,
};

const transitions = [_]u8 {
   0,12,24,36,60,96,84,12,12,12,48,72, 12,12,12,12,12,12,12,12,12,12,12,12,
  12, 0,12,12,12,12,12, 0,12, 0,12,12, 12,24,12,12,12,12,12,24,12,24,12,12,
  12,12,12,12,12,12,12,24,12,12,12,12, 12,24,12,12,12,12,12,12,12,24,12,12,
  12,12,12,12,12,12,12,36,12,36,12,12, 12,36,12,12,12,12,12,36,12,36,12,12,
  12,36,12,12,12,12,12,12,12,12,12,12,
};
// zig fmt: on

// DFA states
const ACCEPT_STATE = 0;
const REJECT_STATE = 12;

// This is where we accumulate our current codepoint.
accumulator: u21 = 0,
// The internal state of the DFA.
state: u8 = ACCEPT_STATE,

/// Takes the next byte in the utf-8 sequence and emits a tuple of
/// - The codepoint that was generated, if there is one.
/// - A boolean that indicates whether the provided byte was consumed.
///
/// The only case where the byte is not consumed is if an ill-formed
/// sequence is reached, in which case a replacement character will be
/// emitted and the byte will not be consumed.
///
/// If the byte is not consumed, the caller is responsible for calling
/// again with the same byte before continuing.
pub inline fn next(self: *UTF8Decoder, byte: u8) struct { ?u21, bool } {
    const char_class = char_classes[byte];

    const initial_state = self.state;

    if (self.state != ACCEPT_STATE) {
        self.accumulator <<= 6;
        self.accumulator |= (byte & 0x3F);
    } else {
        self.accumulator = (@as(u21, 0xFF) >> char_class) & (byte);
    }

    self.state = transitions[self.state + char_class];

    if (self.state == ACCEPT_STATE) {
        defer self.accumulator = 0;

        // Emit the fully decoded codepoint.
        return .{ self.accumulator, true };
    } else if (self.state == REJECT_STATE) {
        self.accumulator = 0;
        self.state = ACCEPT_STATE;
        // Emit a replacement character. If we rejected the first byte
        // in a sequence, then it was consumed, otherwise it was not.
        return .{ 0xFFFD, initial_state == ACCEPT_STATE };
    } else {
        // Emit nothing, we're in the middle of a sequence.
        return .{ null, true };
    }
}
