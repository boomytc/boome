//! https://gitlab.freedesktop.org/Per_Bothner/specifications/blob/master/proposals/semantic-prompts.md
const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const OSCCommand = @import("../../osc.zig").Command;
const string_encoding = @import("../../../os/string_encoding.zig");

const log = std.log.scoped(.osc_semantic_prompt);

/// A single semantic prompt command.
///
/// Technically according to the spec, not all commands have options
/// but it is easier to be "liberal in what we accept" here since
/// all except one do and the spec does also say to ignore unknown
/// options. So, I think this is a fair interpretation.
pub const Command = struct {
    action: Action,
    options_unvalidated: []const u8,

    pub const Action = enum {
        fresh_line, // 'L'
        fresh_line_new_prompt, // 'A'
        new_command, // 'N'
        prompt_start, // 'P'
        end_prompt_start_input, // 'B'
        end_prompt_start_input_terminate_eol, // 'I'
        end_input_start_output, // 'C'
        end_command, // 'D'
    };

    pub fn init(action: Action) Command {
        return .{
            .action = action,
            .options_unvalidated = "",
        };
    }

    /// Read an option for this command. Returns null if unset or invalid.
    pub fn readOption(
        self: Command,
        comptime option: Option,
    ) ?option.Type() {
        return option.read(self.options_unvalidated);
    }

    /// Write the decoded command line (if any) to the writer. If an error
    /// occurs garbage may have been written to the writer.
    pub fn writeCommandLine(self: Command, writer: *std.Io.Writer) (std.Io.Writer.Error || error{DecodeError})!void {
        if (self.readOption(.cmdline)) |command_line| {
            try string_encoding.printfQDecode(writer, command_line);
            return;
        }
        if (self.readOption(.cmdline_url)) |command_line| {
            try string_encoding.urlPercentDecode(writer, command_line);
            return;
        }
        return;
    }
};

pub const Option = enum {
    aid,
    cl,
    prompt_kind,
    err,
    cmdline,
    cmdline_url,

    // https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
    // Kitty supports a "redraw" option for prompt_start. This is extended
    // by Ghostty with the "last" option. See Redraw the type for more details.
    redraw,

    // Use a special key instead of arrow keys to move the cursor on
    // mouse click. Useful if arrow keys have side-effets like triggering
    // auto-complete. The shell integration script should bind the special
    // key as needed.
    // See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
    special_key,

    // If true, the shell is capable of handling mouse click events.
    // Ghostty will then send a click event to the shell when the user
    // clicks somewhere in the prompt. The shell can then move the cursor
    // to that position or perform some other appropriate action. If false,
    // Ghostty may generate a number of fake key events to move the cursor
    // which is not very robust.
    // See: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
    click_events,

    // Not technically an option that can be set with k=v and only
    // present currently with command 'D' but its easier to just
    // parse it into our options.
    exit_code,

    pub fn Type(comptime self: Option) type {
        return switch (self) {
            .aid => []const u8,
            .cl => Click,
            .prompt_kind => PromptKind,
            .err => []const u8,
            .redraw => Redraw,
            .special_key => bool,
            .click_events => bool,
            .cmdline => []const u8,
            .cmdline_url => []const u8,
            .exit_code => i32,
        };
    }

    fn key(comptime self: Option) []const u8 {
        return switch (self) {
            .aid => "aid",
            .cl => "cl",
            .prompt_kind => "k",
            .err => "err",
            .redraw => "redraw",
            .special_key => "special_key",
            .click_events => "click_events",
            .cmdline => "cmdline",
            .cmdline_url => "cmdline_url",

            // special case, handled before ever calling key
            .exit_code => unreachable,
        };
    }

    /// Read the option value from the raw options string.
    ///
    /// The raw options string is the raw unparsed data after the
    /// OSC 133 command. e.g. for `133;A;aid=14;cl=line`, the
    /// raw options string would be `aid=14;cl=line`.
    ///
    /// Any errors in the raw string will return null since the OSC133
    /// specification says to ignore unknown or malformed options.
    pub fn read(
        comptime self: Option,
        raw: []const u8,
    ) ?self.Type() {
        var remaining = raw;
        while (remaining.len > 0) {
            // Length of the next value is up to the `;` or the
            // end of the string.
            const len = std.mem.indexOfScalar(
                u8,
                remaining,
                ';',
            ) orelse remaining.len;

            // Grab our full value and move our cursor past the `;`
            const full = remaining[0..len];

            // If we're looking for exit_code we special case it.
            // as the first value.
            if (comptime self == .exit_code) {
                return std.fmt.parseInt(
                    i32,
                    full,
                    10,
                ) catch null;
            }

            // Parse our key=value and verify our key matches our
            // expectation.
            const value = value: {
                if (std.mem.indexOfScalar(
                    u8,
                    full,
                    '=',
                )) |eql_idx| {
                    if (std.mem.eql(
                        u8,
                        full[0..eql_idx],
                        self.key(),
                    )) {
                        break :value full[eql_idx + 1 ..];
                    }
                }

                // No match!
                if (len < remaining.len) {
                    remaining = remaining[len + 1 ..];
                    continue;
                }

                break;
            };

            return switch (self) {
                .aid => value,
                .cl => .init(value),
                .prompt_kind => if (value.len == 1) PromptKind.init(value[0]) else null,
                .err => value,
                .redraw => if (std.mem.eql(u8, value, "0"))
                    .false
                else if (std.mem.eql(u8, value, "1"))
                    .true
                else if (std.mem.eql(u8, value, "last"))
                    .last
                else
                    null,
                .special_key, .click_events => if (value.len == 1) switch (value[0]) {
                    '0' => false,
                    '1' => true,
                    else => null,
                } else null,
                .cmdline => value,
                .cmdline_url => value,
                // Handled above
                .exit_code => unreachable,
            };
        }

        // Not found
        return null;
    }
};

/// The `cl` option specifies what kind of cursor key sequences are handled
/// by the application for click-to-move-cursor functionality.
pub const Click = enum {
    /// Value: "line". Allows motion within a single input line using standard
    /// left/right arrow escape sequences. Only a single left/right sequence
    /// should be emitted for double-width characters.
    line,

    /// Value: "m". Allows movement between different lines in the same group,
    /// but only using left/right arrow escape sequences.
    multiple,

    /// Value: "v". Like `multiple` but cursor up/down should be used. The
    /// terminal should be conservative when moving between lines: move the
    /// cursor left to the start of line, emit the needed up/down sequences,
    /// then move the cursor right to the clicked destination.
    conservative_vertical,

    /// Value: "w". Like `conservative_vertical` but specifies that there are
    /// no spurious spaces at the end of the line, and the application editor
    /// handles "smart vertical movement" (moving 2 lines up from position 20,
    /// where the intermediate line is 15 chars wide and the destination is
    /// 18 chars wide, ends at position 18).
    smart_vertical,

    pub fn init(value: []const u8) ?Click {
        return if (value.len == 1) switch (value[0]) {
            'm' => .multiple,
            'v' => .conservative_vertical,
            'w' => .smart_vertical,
            else => null,
        } else if (std.mem.eql(
            u8,
            value,
            "line",
        )) .line else null;
    }
};

pub const PromptKind = enum {
    initial,
    right,
    continuation,
    secondary,

    pub fn init(c: u8) ?PromptKind {
        return switch (c) {
            'i' => .initial,
            'r' => .right,
            'c' => .continuation,
            's' => .secondary,
            else => null,
        };
    }
};

/// The values for the `redraw` extension to OSC133. This was
/// started by Kitty[1] and extended by Ghostty (the "last" option).
///
/// [1]: https://sw.kovidgoyal.net/kitty/shell-integration/#notes-for-shell-developers
pub const Redraw = enum(u2) {
    /// The shell supports redrawing the full prompt and all continuations.
    /// This is the default value, it does not need to be explicitly set
    /// unless it is to reset a prior other value.
    true,

    /// The shell does NOT support redrawing. In this case, Ghostty will NOT
    /// clear any prompt lines on resize.
    false,

    /// The shell supports redrawing only the LAST line of the prompt.
    /// Ghostty will only clear the last line of the prompt on resize.
    ///
    /// This is specifically introduced because Bash only redraws the last
    /// line. It is literally the only shell that does this and it does this
    /// because its bad and they should feel bad. Don't be like Bash.
    last,
};

/// Parse OSC 133, semantic prompts
pub fn parse(parser: *Parser, _: ?u8) ?*OSCCommand {
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    if (data.len == 0) {
        parser.state = .invalid;
        return null;
    }

    // All valid cases terminate within this block. Any fallthroughs
    // are invalid. This makes some of our parse logic a little less
    // repetitive.
    valid: {
        switch (data[0]) {
            'A' => fresh_line: {
                parser.command = .{ .semantic_prompt = .init(.fresh_line_new_prompt) };
                if (data.len == 1) break :fresh_line;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'B' => end_prompt: {
                parser.command = .{ .semantic_prompt = .init(.end_prompt_start_input) };
                if (data.len == 1) break :end_prompt;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'I' => end_prompt_line: {
                parser.command = .{ .semantic_prompt = .init(.end_prompt_start_input_terminate_eol) };
                if (data.len == 1) break :end_prompt_line;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'C' => end_input: {
                parser.command = .{ .semantic_prompt = .init(.end_input_start_output) };
                if (data.len == 1) break :end_input;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'D' => end_command: {
                parser.command = .{ .semantic_prompt = .init(.end_command) };
                if (data.len == 1) break :end_command;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'L' => {
                if (data.len > 1) break :valid;
                parser.command = .{ .semantic_prompt = .init(.fresh_line) };
            },

            'N' => new_command: {
                parser.command = .{ .semantic_prompt = .init(.new_command) };
                if (data.len == 1) break :new_command;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            'P' => prompt_start: {
                parser.command = .{ .semantic_prompt = .init(.prompt_start) };
                if (data.len == 1) break :prompt_start;
                if (data[1] != ';') break :valid;
                parser.command.semantic_prompt.options_unvalidated = data[2..];
            },

            else => break :valid,
        }

        return &parser.command;
    }

    // Any fallthroughs are invalid
    parser.state = .invalid;
    return null;
}
