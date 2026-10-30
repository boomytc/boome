const std = @import("std");

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 9, which could be an iTerm2 notification or a ConEmu extension.
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const writer = parser.writer orelse {
        parser.state = .invalid;
        return null;
    };

    // Check first to see if this is a ConEmu OSC
    // https://conemu.github.io/en/AnsiEscapeCodes.html#ConEmu_specific_OSC
    conemu: {
        var data = writer.buffered();
        if (data.len == 0) break :conemu;
        switch (data[0]) {
            // Check for OSC 9;1 9;10 9;11 9;12
            '1' => {
                if (data.len < 2) break :conemu;
                switch (data[1]) {
                    // OSC 9;1 sleep
                    ';' => {
                        parser.command = .{
                            .conemu_sleep = .{
                                .duration_ms = if (std.fmt.parseUnsigned(u16, data[2..], 10)) |num| @min(num, 10_000) else |_| 100,
                            },
                        };
                        return &parser.command;
                    },
                    // OSC 9;10 xterm keyboard and output emulation
                    '0' => {
                        if (data.len == 2) {
                            parser.command = .{
                                .conemu_xterm_emulation = .{
                                    .keyboard = true,
                                    .output = true,
                                },
                            };
                            return &parser.command;
                        }
                        if (data.len < 4) break :conemu;
                        if (data[2] != ';') break :conemu;
                        switch (data[3]) {
                            '0' => {
                                parser.command = .{
                                    .conemu_xterm_emulation = .{
                                        .keyboard = false,
                                        .output = false,
                                    },
                                };
                                return &parser.command;
                            },
                            '1' => {
                                parser.command = .{
                                    .conemu_xterm_emulation = .{
                                        .keyboard = true,
                                        .output = true,
                                    },
                                };
                                return &parser.command;
                            },
                            '2' => {
                                parser.command = .{
                                    .conemu_xterm_emulation = .{
                                        .keyboard = null,
                                        .output = false,
                                    },
                                };
                                return &parser.command;
                            },
                            '3' => {
                                parser.command = .{
                                    .conemu_xterm_emulation = .{
                                        .keyboard = null,
                                        .output = true,
                                    },
                                };
                                return &parser.command;
                            },
                            else => break :conemu,
                        }
                    },
                    // OSC 9;11 comment
                    '1' => {
                        if (data.len < 3) break :conemu;
                        if (data[2] != ';') break :conemu;
                        writer.writeByte(0) catch {
                            parser.state = .invalid;
                            return null;
                        };
                        data = writer.buffered();
                        parser.command = .{
                            .conemu_comment = data[3 .. data.len - 1 :0],
                        };
                        return &parser.command;
                    },
                    // OSC 9;12 mark prompt start
                    '2' => {
                        parser.command = .{ .semantic_prompt = .init(.fresh_line_new_prompt) };
                        return &parser.command;
                    },
                    else => break :conemu,
                }
            },
            // OSC 9;2 show message box
            '2' => {
                if (data.len < 2) break :conemu;
                if (data[1] != ';') break :conemu;
                writer.writeByte(0) catch {
                    parser.state = .invalid;
                    return null;
                };
                data = writer.buffered();
                parser.command = .{
                    .conemu_show_message_box = data[2 .. data.len - 1 :0],
                };
                return &parser.command;
            },
            // OSC 9;3 change tab title
            '3' => {
                if (data.len < 2) break :conemu;
                if (data[1] != ';') break :conemu;
                if (data.len == 2) {
                    parser.command = .{
                        .conemu_change_tab_title = .reset,
                    };
                    return &parser.command;
                }
                writer.writeByte(0) catch {
                    parser.state = .invalid;
                    return null;
                };
                data = writer.buffered();
                parser.command = .{
                    .conemu_change_tab_title = .{
                        .value = data[2 .. data.len - 1 :0],
                    },
                };
                return &parser.command;
            },
            // OSC 9;4 progress report
            '4' => {
                if (data.len < 2) break :conemu;
                if (data[1] != ';') break :conemu;
                if (data.len < 3) break :conemu;
                switch (data[2]) {
                    '0' => {
                        parser.command = .{
                            .conemu_progress_report = .{
                                .state = .remove,
                            },
                        };
                    },
                    '1' => {
                        parser.command = .{
                            .conemu_progress_report = .{
                                .state = .set,
                                .progress = 0,
                            },
                        };
                    },
                    '2' => {
                        parser.command = .{
                            .conemu_progress_report = .{
                                .state = .@"error",
                            },
                        };
                    },
                    '3' => {
                        parser.command = .{
                            .conemu_progress_report = .{
                                .state = .indeterminate,
                            },
                        };
                    },
                    '4' => {
                        parser.command = .{
                            .conemu_progress_report = .{
                                .state = .pause,
                            },
                        };
                    },
                    else => break :conemu,
                }
                switch (parser.command.conemu_progress_report.state) {
                    .remove, .indeterminate => {},
                    .set, .@"error", .pause => progress: {
                        if (data.len < 4) break :progress;
                        if (data[3] != ';') break :progress;
                        // parse the progress value
                        parser.command.conemu_progress_report.progress = value: {
                            break :value @intCast(std.math.clamp(
                                std.fmt.parseUnsigned(usize, data[4..], 10) catch break :value null,
                                0,
                                100,
                            ));
                        };
                    },
                }
                return &parser.command;
            },
            // OSC 9;5 wait for input
            '5' => {
                parser.command = .conemu_wait_input;
                return &parser.command;
            },
            // OSC 9;6 guimacro
            '6' => {
                if (data.len < 2) break :conemu;
                if (data[1] != ';') break :conemu;
                writer.writeByte(0) catch {
                    parser.state = .invalid;
                    return null;
                };
                data = writer.buffered();
                parser.command = .{
                    .conemu_guimacro = data[2 .. data.len - 1 :0],
                };
                return &parser.command;
            },
            // OSC 9;7 run process
            '7' => {
                if (data.len < 2) break :conemu;
                if (data[1] != ';') break :conemu;
                writer.writeByte(0) catch {
                    parser.state = .invalid;
                    return null;
                };
                data = writer.buffered();
                parser.command = .{
                    .conemu_run_process = data[2 .. data.len - 1 :0],
                };
                return &parser.command;
            },
            // OSC 9;8 output environment variable
            '8' => {
                if (data.len < 2) break :conemu;
                if (data[1] != ';') break :conemu;
                writer.writeByte(0) catch {
                    parser.state = .invalid;
                    return null;
                };
                data = writer.buffered();
                parser.command = .{
                    .conemu_output_environment_variable = data[2 .. data.len - 1 :0],
                };
                return &parser.command;
            },
            // OSC 9;9 current working directory
            '9' => {
                if (data.len < 2) break :conemu;
                if (data[1] != ';') break :conemu;
                writer.writeByte(0) catch {
                    parser.state = .invalid;
                    return null;
                };
                data = writer.buffered();
                parser.command = .{
                    .report_pwd = .{
                        .value = data[2 .. data.len - 1 :0],
                    },
                };
                return &parser.command;
            },
            else => break :conemu,
        }
    }

    // If it's not a ConEmu OSC, it's an iTerm2 notification

    writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = writer.buffered();
    parser.command = .{
        .show_desktop_notification = .{
            .title = "",
            .body = data[0 .. data.len - 1 :0],
        },
    };
    return &parser.command;
}
