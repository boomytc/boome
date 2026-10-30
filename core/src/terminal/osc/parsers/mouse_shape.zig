const assert = @import("../../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

// Parse OSC 22
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"22");
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    parser.command = .{
        .mouse_shape = .{
            .value = data[0 .. data.len - 1 :0],
        },
    };
    return &parser.command;
}
