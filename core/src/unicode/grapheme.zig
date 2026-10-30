const std = @import("std");
const table = @import("props_table.zig").table;
const uucode = @import("uucode");

/// Determines if there is a grapheme break between two codepoints. This
/// must be called sequentially maintaining the state between calls.
///
/// This function does NOT work with control characters. Control characters,
/// line feeds, and carriage returns are expected to be filtered out before
/// calling this function. This is because this function is tuned for
/// Ghostty.
pub fn graphemeBreak(cp1: u21, cp2: u21, state: *uucode.grapheme.BreakState) bool {
    const value = Precompute.data[
        (Precompute.Key{
            .gb1 = table.get(cp1).grapheme_break,
            .gb2 = table.get(cp2).grapheme_break,
            .state = state.*,
        }).index()
    ];
    state.* = value.state;
    return value.result;
}

/// This is all the structures and data for the precomputed lookup table
/// for all possible permutations of state and grapheme break properties.
/// Precomputation requires 2^13 keys of 4 bit values so the whole table is
/// 8KB.
const Precompute = struct {
    const Key = packed struct(u13) {
        state: uucode.grapheme.BreakState,
        gb1: uucode.x.types.GraphemeBreakNoControl,
        gb2: uucode.x.types.GraphemeBreakNoControl,

        fn index(self: Key) usize {
            return @intCast(@as(u13, @bitCast(self)));
        }
    };

    const Value = packed struct(u4) {
        result: bool,
        state: uucode.grapheme.BreakState,
    };

    const data = precompute: {
        var result: [std.math.maxInt(u13) + 1]Value = undefined;

        const max_state_int = blk: {
            var max: usize = 0;
            for (@typeInfo(uucode.grapheme.BreakState).@"enum".fields) |field| {
                if (field.value > max) max = field.value;
            }
            break :blk max;
        };

        @setEvalBranchQuota(10_000);
        const info = @typeInfo(uucode.x.types.GraphemeBreakNoControl).@"enum";
        for (0..max_state_int + 1) |state_int| {
            for (info.fields) |field1| {
                for (info.fields) |field2| {
                    var state: uucode.grapheme.BreakState = @enumFromInt(state_int);

                    const key: Key = .{
                        .gb1 = @field(uucode.x.types.GraphemeBreakNoControl, field1.name),
                        .gb2 = @field(uucode.x.types.GraphemeBreakNoControl, field2.name),
                        .state = state,
                    };
                    const v = uucode.x.grapheme.computeGraphemeBreakNoControl(
                        key.gb1,
                        key.gb2,
                        &state,
                    );
                    result[key.index()] = .{ .result = v, .state = state };
                }
            }
        }

        std.debug.assert(@sizeOf(@TypeOf(result)) == 8192);
        break :precompute result;
    };
};
