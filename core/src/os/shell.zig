const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

/// Builder for constructing space-separated shell command strings.
/// Uses a caller-provided allocator (typically with stackFallback).
pub const ShellCommandBuilder = struct {
    buffer: std.Io.Writer.Allocating,

    pub fn init(allocator: Allocator) ShellCommandBuilder {
        return .{ .buffer = .init(allocator) };
    }

    pub fn deinit(self: *ShellCommandBuilder) void {
        self.buffer.deinit();
    }

    /// Append an argument to the command with automatic space separation.
    pub fn appendArg(self: *ShellCommandBuilder, arg: []const u8) (Allocator.Error || Writer.Error)!void {
        if (arg.len == 0) return;
        if (self.buffer.written().len > 0) {
            try self.buffer.writer.writeByte(' ');
        }
        try self.buffer.writer.writeAll(arg);
    }

    /// Get the final null-terminated command string, transferring ownership to caller.
    /// Calling deinit() after this is safe but unnecessary.
    pub fn toOwnedSlice(self: *ShellCommandBuilder) Allocator.Error![:0]const u8 {
        return try self.buffer.toOwnedSliceSentinel(0);
    }
};

/// Writer that escapes characters that shells treat specially to reduce the
/// risk of injection attacks or other such weirdness. Specifically excludes
/// linefeeds so that they can be used to delineate lists of file paths.
pub const ShellEscapeWriter = struct {
    writer: Writer,
    child: *Writer,

    pub fn init(child: *Writer) ShellEscapeWriter {
        return .{
            .writer = .{
                // TODO: Actually use a buffer here
                .buffer = &.{},
                .vtable = &.{ .drain = ShellEscapeWriter.drain },
            },
            .child = child,
        };
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *ShellEscapeWriter = @fieldParentPtr("writer", w);

        // TODO: This is a very naive implementation and does not really make
        // full use of the post-Writergate API. However, since we know that
        // this is going into an Allocating writer anyways, we can be a bit
        // less strict here.

        var count: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| try self.writeEscaped(chunk, &count);

        for (0..splat) |_| try self.writeEscaped(data[data.len - 1], &count);
        return count;
    }

    fn writeEscaped(
        self: *ShellEscapeWriter,
        s: []const u8,
        count: *usize,
    ) Writer.Error!void {
        for (s) |byte| {
            const buf = switch (byte) {
                '\\',
                '"',
                '\'',
                '$',
                '`',
                '*',
                '?',
                ' ',
                '|',
                '(',
                ')',
                => &[_]u8{ '\\', byte },
                else => &[_]u8{byte},
            };
            try self.child.writeAll(buf);
            count.* += 1;
        }
    }
};
