const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 52
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"52");
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    if (data.len == 1) {
        parser.state = .invalid;
        return null;
    }
    if (data[0] == ';') {
        parser.command = .{
            .clipboard_contents = .{
                .kind = 'c',
                .data = data[1 .. data.len - 1 :0],
            },
        };
    } else {
        if (data.len < 2) {
            parser.state = .invalid;
            return null;
        }
        if (data[1] != ';') {
            parser.state = .invalid;
            return null;
        }
        parser.command = .{
            .clipboard_contents = .{
                .kind = data[0],
                .data = data[2 .. data.len - 1 :0],
            },
        };
    }
    return &parser.command;
}
