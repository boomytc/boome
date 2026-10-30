const std = @import("std");

pub const ParseError = error{
    MissingEntry,
    ExtraEntry,
    FormatError,
};

/// Parse the output from a command with the given format struct
/// (returned usually by FormatStruct). The format struct is expected
/// to be in the order of the variables used in the format string and
/// the variables are expected to be plain variables (no conditionals,
/// extra formatting, etc.). Each variable is expected to be separated
/// by a single `delimiter` character.
pub fn parseFormatStruct(
    comptime T: type,
    str: []const u8,
    delimiter: u8,
) ParseError!T {
    // Parse all our fields
    const fields = @typeInfo(T).@"struct".fields;
    var it = std.mem.splitScalar(u8, str, delimiter);
    var result: T = undefined;
    inline for (fields) |field| {
        const part = it.next() orelse return error.MissingEntry;
        @field(result, field.name) = Variable.parse(
            @field(Variable, field.name),
            part,
        ) catch return error.FormatError;
    }

    // We should have consumed all parts now.
    if (it.next() != null) return error.ExtraEntry;

    return result;
}

pub fn comptimeFormat(
    comptime vars: []const Variable,
    comptime delimiter: u8,
) []const u8 {
    comptime {
        @setEvalBranchQuota(50000);
        var counter: std.Io.Writer.Discarding = .init(&.{});
        try format(&counter.writer, vars, delimiter);

        var buf: [counter.count]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try format(&writer, vars, delimiter);
        const final = buf;
        return final[0..writer.end];
    }
}

/// Format a set of variables into the proper format string for tmux
/// that we can handle with `parseFormatStruct`.
pub fn format(
    writer: *std.Io.Writer,
    vars: []const Variable,
    delimiter: u8,
) std.Io.Writer.Error!void {
    for (vars, 0..) |variable, i| {
        if (i != 0) try writer.writeByte(delimiter);
        try writer.print("#{{{t}}}", .{variable});
    }
}

/// Returns a struct type that contains fields for each of the given
/// format variables. This can be used with `parseFormatStruct` to
/// parse an output string into a format struct.
pub fn FormatStruct(comptime vars: []const Variable) type {
    var fields: [vars.len]std.builtin.Type.StructField = undefined;
    for (vars, &fields) |variable, *field| {
        field.* = .{
            .name = @tagName(variable),
            .type = variable.Type(),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(variable.Type()),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Possible variables in a tmux format string that we support.
///
/// Tmux supports a large number of variables, but we only implement
/// a subset of them here that are relevant to the use case of implementing
/// control mode for terminal emulators.
pub const Variable = enum {
    /// 1 if pane is in alternate screen.
    alternate_on,
    /// Saved cursor X in alternate screen.
    alternate_saved_x,
    /// Saved cursor Y in alternate screen.
    alternate_saved_y,
    /// 1 if bracketed paste mode is enabled.
    bracketed_paste,
    /// 1 if the cursor is blinking.
    cursor_blinking,
    /// Cursor colour in pane. Possible formats:
    /// - Named colors: `black`, `red`, `green`, `yellow`, `blue`, `magenta`,
    ///   `cyan`, `white`, `default`, `terminal`, or bright variants.
    /// - 256 colors: `colour<N>` where N is 0-255 (e.g., `colour100`).
    /// - RGB hex: `#RRGGBB` (e.g., `#ff0000`).
    /// - Empty string if unset.
    cursor_colour,
    /// Pane cursor flag.
    cursor_flag,
    /// Cursor shape in pane. Possible values: `block`, `underline`, `bar`,
    /// or `default`.
    cursor_shape,
    /// Cursor X position in pane.
    cursor_x,
    /// Cursor Y position in pane.
    cursor_y,
    /// 1 if focus reporting is enabled.
    focus_flag,
    /// Pane insert flag.
    insert_flag,
    /// Pane keypad cursor flag.
    keypad_cursor_flag,
    /// Pane keypad flag.
    keypad_flag,
    /// Pane mouse all flag.
    mouse_all_flag,
    /// Pane mouse any flag.
    mouse_any_flag,
    /// Pane mouse button flag.
    mouse_button_flag,
    /// Pane mouse SGR flag.
    mouse_sgr_flag,
    /// Pane mouse standard flag.
    mouse_standard_flag,
    /// Pane mouse UTF-8 flag.
    mouse_utf8_flag,
    /// Pane origin flag.
    origin_flag,
    /// Unique pane ID prefixed with `%` (e.g., `%0`, `%42`).
    pane_id,
    /// Pane tab positions as a comma-separated list of 0-indexed column
    /// numbers (e.g., `8,16,24,32`). Empty string if no tabs are set.
    pane_tabs,
    /// Bottom of scroll region in pane.
    scroll_region_lower,
    /// Top of scroll region in pane.
    scroll_region_upper,
    /// Unique session ID prefixed with `$` (e.g., `$0`, `$42`).
    session_id,
    /// Server version (e.g., `3.5a`).
    version,
    /// Unique window ID prefixed with `@` (e.g., `@0`, `@42`).
    window_id,
    /// Width of window.
    window_width,
    /// Height of window.
    window_height,
    /// Window layout description, ignoring zoomed window panes. Format is
    /// `<checksum>,<layout>` where checksum is a 4-digit hex CRC16 and layout
    /// encodes pane dimensions as `WxH,X,Y[,ID]` with `{...}` for horizontal
    /// splits and `[...]` for vertical splits.
    window_layout,
    /// Pane wrap flag.
    wrap_flag,

    /// Parse the given string value into the appropriate resulting
    /// type for this variable.
    pub fn parse(comptime self: Variable, value: []const u8) !Type(self) {
        return switch (self) {
            .alternate_on,
            .bracketed_paste,
            .cursor_blinking,
            .cursor_flag,
            .focus_flag,
            .insert_flag,
            .keypad_cursor_flag,
            .keypad_flag,
            .mouse_all_flag,
            .mouse_any_flag,
            .mouse_button_flag,
            .mouse_sgr_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .origin_flag,
            .wrap_flag,
            => std.mem.eql(u8, value, "1"),
            .alternate_saved_x,
            .alternate_saved_y,
            .cursor_x,
            .cursor_y,
            .scroll_region_lower,
            .scroll_region_upper,
            => try std.fmt.parseInt(usize, value, 10),
            .session_id => if (value.len >= 2 and value[0] == '$')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .window_id => if (value.len >= 2 and value[0] == '@')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .pane_id => if (value.len >= 2 and value[0] == '%')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .window_width => try std.fmt.parseInt(usize, value, 10),
            .window_height => try std.fmt.parseInt(usize, value, 10),
            .cursor_colour,
            .cursor_shape,
            .pane_tabs,
            .version,
            .window_layout,
            => value,
        };
    }

    /// The type of the parsed value for this variable type.
    pub fn Type(comptime self: Variable) type {
        return switch (self) {
            .alternate_on,
            .bracketed_paste,
            .cursor_blinking,
            .cursor_flag,
            .focus_flag,
            .insert_flag,
            .keypad_cursor_flag,
            .keypad_flag,
            .mouse_all_flag,
            .mouse_any_flag,
            .mouse_button_flag,
            .mouse_sgr_flag,
            .mouse_standard_flag,
            .mouse_utf8_flag,
            .origin_flag,
            .wrap_flag,
            => bool,
            .alternate_saved_x,
            .alternate_saved_y,
            .cursor_x,
            .cursor_y,
            .scroll_region_lower,
            .scroll_region_upper,
            .session_id,
            .window_id,
            .pane_id,
            .window_width,
            .window_height,
            => usize,
            .cursor_colour,
            .cursor_shape,
            .pane_tabs,
            .version,
            .window_layout,
            => []const u8,
        };
    }
};
