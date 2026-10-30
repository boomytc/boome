const std = @import("std");

/// Decode date from the buffer that has been encoded in the same way that
/// `bash`'s `printf %q` encodes a string and write it to the writer. If an
/// error is returned garbage may have been written to the buffer.
pub fn printfQDecode(writer: *std.Io.Writer, buf: []const u8) (std.Io.Writer.Error || error{DecodeError})!void {
    const data: []const u8 = data: {
        // Strip off `$''` quoting.
        if (std.mem.startsWith(u8, buf, "$'")) {
            if (buf.len < 3 or !std.mem.endsWith(u8, buf, "'")) return error.DecodeError;
            break :data buf[2 .. buf.len - 1];
        }
        // Strip off `''` quoting.
        if (std.mem.startsWith(u8, buf, "'")) {
            if (buf.len < 2 or !std.mem.endsWith(u8, buf, "'")) return error.DecodeError;
            break :data buf[1 .. buf.len - 1];
        }
        break :data buf;
    };

    var src: usize = 0;

    while (src < data.len) {
        switch (data[src]) {
            else => {
                try writer.writeByte(data[src]);
                src += 1;
            },
            '\\' => {
                if (src + 1 >= data.len) return error.DecodeError;
                switch (data[src + 1]) {
                    ' ',
                    '\\',
                    '"',
                    '\'',
                    '$',
                    => |c| {
                        try writer.writeByte(c);
                        src += 2;
                    },
                    'e' => {
                        try writer.writeByte(std.ascii.control_code.esc);
                        src += 2;
                    },
                    'n' => {
                        try writer.writeByte(std.ascii.control_code.lf);
                        src += 2;
                    },
                    'r' => {
                        try writer.writeByte(std.ascii.control_code.cr);
                        src += 2;
                    },
                    't' => {
                        try writer.writeByte(std.ascii.control_code.ht);
                        src += 2;
                    },
                    'v' => {
                        try writer.writeByte(std.ascii.control_code.vt);
                        src += 2;
                    },
                    else => return error.DecodeError,
                }
            },
        }
    }
}

/// Decode data from the buffer that has been URL percent encoded and write
/// it to the given buffer. If an error is returned the garbage may have been
/// written to the writer.
pub fn urlPercentDecode(writer: *std.Io.Writer, buf: []const u8) (std.Io.Writer.Error || error{DecodeError})!void {
    var src: usize = 0;
    while (src < buf.len) {
        switch (buf[src]) {
            else => {
                try writer.writeByte(buf[src]);
                src += 1;
            },
            '%' => {
                if (src + 2 >= buf.len) return error.DecodeError;
                switch (buf[src + 1]) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        switch (buf[src + 2]) {
                            '0'...'9', 'a'...'f', 'A'...'F' => {
                                try writer.writeByte(std.math.shl(u8, hex(buf[src + 1]), 4) | hex(buf[src + 2]));
                                src += 3;
                            },
                            else => return error.DecodeError,
                        }
                    },
                    else => return error.DecodeError,
                }
            },
        }
    }
}

inline fn hex(c: u8) u4 {
    switch (c) {
        '0'...'9' => return @truncate(c - '0'),
        'a'...'f' => return @truncate(c - 'a' + 10),
        'A'...'F' => return @truncate(c - 'A' + 10),
        else => unreachable,
    }
}

/// Is the given character valid in URI percent encoding?
fn isValidChar(c: u8) bool {
    return switch (c) {
        ' ', ';', '=' => false,
        else => return std.ascii.isPrint(c),
    };
}

/// Write data to the writer after URI percent encoding.
pub fn urlPercentEncode(writer: *std.Io.Writer, data: []const u8) std.Io.Writer.Error!void {
    try std.Uri.Component.percentEncode(writer, data, isValidChar);
}
