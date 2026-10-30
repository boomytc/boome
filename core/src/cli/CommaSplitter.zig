//! Iterator to split a string into fields by commas, taking into account
//! quotes and escapes.
//!
//! Supports the same escapes as in Zig literal strings.
//!
//! Quotes must begin and end with a double quote (`"`). It is an error to not
//! end a quote that was begun. To include a double quote inside a quote (or to
//! not have a double quote start a quoted section) escape it with a backslash.
//!
//! Single quotes (`'`) are not special, they do not begin a quoted block.
//!
//! Zig multiline string literals are NOT supported.
//!
//! Quotes and escapes are not stripped or decoded, that must be handled as a
//! separate step!
const CommaSplitter = @This();

pub const Error = error{
    UnclosedQuote,
    UnfinishedEscape,
    IllegalEscape,
};

/// the string that we are splitting
str: []const u8,
/// how much of the string has been consumed so far
index: usize,

/// initialize a splitter with the given string
pub fn init(str: []const u8) CommaSplitter {
    return .{
        .str = str,
        .index = 0,
    };
}

/// return the next field, null if no more fields
pub fn next(self: *CommaSplitter) Error!?[]const u8 {
    if (self.index >= self.str.len) return null;

    // where the current field starts
    const start = self.index;
    // state of state machine
    const State = enum {
        normal,
        quoted,
        escape,
        hexescape,
        unicodeescape,
    };
    // keep track of the state to return to when done processing an escape
    // sequence.
    var last: State = .normal;
    // used to count number of digits seen in a hex escape
    var hexescape_digits: usize = 0;
    // sub-state of parsing hex escapes
    var unicodeescape_state: enum {
        start,
        digits,
    } = .start;
    // number of digits in a unicode escape seen so far
    var unicodeescape_digits: usize = 0;
    // accumulator for value of unicode escape
    var unicodeescape_value: usize = 0;

    loop: switch (State.normal) {
        .normal => {
            if (self.index >= self.str.len) return self.str[start..];
            switch (self.str[self.index]) {
                ',' => {
                    self.index += 1;
                    return self.str[start .. self.index - 1];
                },
                '"' => {
                    self.index += 1;
                    continue :loop .quoted;
                },
                '\\' => {
                    self.index += 1;
                    last = .normal;
                    continue :loop .escape;
                },
                else => {
                    self.index += 1;
                    continue :loop .normal;
                },
            }
        },
        .quoted => {
            if (self.index >= self.str.len) return error.UnclosedQuote;
            switch (self.str[self.index]) {
                '"' => {
                    self.index += 1;
                    continue :loop .normal;
                },
                '\\' => {
                    self.index += 1;
                    last = .quoted;
                    continue :loop .escape;
                },
                else => {
                    self.index += 1;
                    continue :loop .quoted;
                },
            }
        },
        .escape => {
            if (self.index >= self.str.len) return error.UnfinishedEscape;
            switch (self.str[self.index]) {
                'n', 'r', 't', '\\', '\'', '"' => {
                    self.index += 1;
                    continue :loop last;
                },
                'x' => {
                    self.index += 1;
                    hexescape_digits = 0;
                    continue :loop .hexescape;
                },
                'u' => {
                    self.index += 1;
                    unicodeescape_state = .start;
                    unicodeescape_digits = 0;
                    unicodeescape_value = 0;
                    continue :loop .unicodeescape;
                },
                else => return error.IllegalEscape,
            }
        },
        .hexescape => {
            if (self.index >= self.str.len) return error.UnfinishedEscape;
            switch (self.str[self.index]) {
                '0'...'9', 'a'...'f', 'A'...'F' => {
                    self.index += 1;
                    hexescape_digits += 1;
                    if (hexescape_digits == 2) continue :loop last;
                    continue :loop .hexescape;
                },
                else => return error.IllegalEscape,
            }
        },
        .unicodeescape => {
            if (self.index >= self.str.len) return error.UnfinishedEscape;
            switch (unicodeescape_state) {
                .start => {
                    switch (self.str[self.index]) {
                        '{' => {
                            self.index += 1;
                            unicodeescape_value = 0;
                            unicodeescape_state = .digits;
                            continue :loop .unicodeescape;
                        },
                        else => return error.IllegalEscape,
                    }
                },
                .digits => {
                    switch (self.str[self.index]) {
                        '}' => {
                            self.index += 1;
                            if (unicodeescape_digits == 0) return error.IllegalEscape;
                            continue :loop last;
                        },
                        '0'...'9' => |d| {
                            self.index += 1;
                            unicodeescape_digits += 1;
                            unicodeescape_value <<= 4;
                            unicodeescape_value += d - '0';
                        },
                        'a'...'f' => |d| {
                            self.index += 1;
                            unicodeescape_digits += 1;
                            unicodeescape_value <<= 4;
                            unicodeescape_value += d - 'a';
                        },
                        'A'...'F' => |d| {
                            self.index += 1;
                            unicodeescape_digits += 1;
                            unicodeescape_value <<= 4;
                            unicodeescape_value += d - 'A';
                        },
                        else => return error.IllegalEscape,
                    }
                    if (unicodeescape_value > 0x10ffff) return error.IllegalEscape;
                    continue :loop .unicodeescape;
                },
            }
        },
    }
}

/// Return any remaining string data, whether it has a comma or not.
pub fn rest(self: *CommaSplitter) ?[]const u8 {
    if (self.index >= self.str.len) return null;
    defer self.index = self.str.len;
    return self.str[self.index..];
}
