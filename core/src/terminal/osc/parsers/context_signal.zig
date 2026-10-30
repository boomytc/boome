//! OSC 3008: Hierarchical Context Signalling (UAPI spec)
//! Specification: https://uapi-group.org/specifications/specs/osc_context/
//!
//! OSC 3008 allows programs to signal context changes to the terminal emulator.
//! Each context has an identifier and metadata fields. Contexts are hierarchical
//! and form a stack.

const std = @import("std");
const Parser = @import("../../osc.zig").Parser;
const OSCCommand = @import("../../osc.zig").Command;

const log = std.log.scoped(.osc_context_signal);

/// Maximum length of a context identifier (per spec).
const max_context_id_len = 64;

/// A single OSC 3008 context signal command.
pub const Command = struct {
    action: Action,
    /// The context identifier. Must be 1-64 characters in the 32..126 byte range.
    id: []const u8,
    /// Raw unparsed metadata fields after the context ID.
    /// Fields are semicolon-separated key=value pairs.
    /// Parsed lazily via `readOption`.
    metadata: []const u8,

    pub const Action = enum {
        /// OSC 3008;start=<id> — initiates, updates, or returns to a context.
        start,
        /// OSC 3008;end=<id> — terminates a context.
        end,
    };

    /// Read a metadata field value from the raw fields string.
    /// Returns null if the field is not present or malformed.
    pub fn readOption(
        self: Command,
        comptime option: Field,
    ) option.Type() {
        return option.read(self.metadata);
    }
};

/// Context types defined by the specification.
pub const ContextType = enum {
    boot,
    container,
    vm,
    elevate,
    chpriv,
    subcontext,
    remote,
    shell,
    command,
    app,
    service,
    session,

    pub fn parse(value: []const u8) ?ContextType {
        return std.meta.stringToEnum(ContextType, value);
    }
};

/// Exit status for the `exit` end-sequence field.
pub const ExitStatus = enum {
    success,
    failure,
    crash,
    interrupt,

    pub fn parse(value: []const u8) ?ExitStatus {
        return std.meta.stringToEnum(ExitStatus, value);
    }
};

/// Metadata fields that can appear in OSC 3008 sequences.
/// Fields are read lazily from the raw string using the `read` method.
pub const Field = enum {
    // Start sequence fields
    type,
    user,
    hostname,
    machineid,
    bootid,
    pid,
    pidfdid,
    comm,
    cwd,
    cmdline,
    vm,
    container,
    targetuser,
    targethost,
    sessionid,

    // End sequence fields
    exit,
    status,
    signal,

    pub fn Type(comptime self: Field) type {
        return switch (self) {
            .type => ?ContextType,
            .exit => ?ExitStatus,
            .pid, .pidfdid => ?u64,
            .status => ?u64,
            // All other fields are string values
            .user,
            .hostname,
            .machineid,
            .bootid,
            .comm,
            .cwd,
            .cmdline,
            .vm,
            .container,
            .targetuser,
            .targethost,
            .sessionid,
            .signal,
            => ?[]const u8,
        };
    }

    fn key(comptime self: Field) []const u8 {
        return @tagName(self);
    }

    /// Read the field value from the raw fields string.
    ///
    /// The raw fields string contains semicolon-separated key=value pairs
    /// e.g. "type=container;user=lennart;hostname=zeta".
    ///
    /// Unknown or malformed fields are ignored per the specification.
    pub fn read(
        comptime self: Field,
        raw: []const u8,
    ) self.Type() {
        var it = std.mem.splitScalar(u8, raw, ';');
        while (it.next()) |full| {
            // Parse key=value
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

                continue;
            };

            return switch (self) {
                .type => .parse(value),
                .exit => .parse(value),
                .pid, .pidfdid, .status => value: {
                    for (value) |c| {
                        if (c < '0' or c > '9') break :value null;
                    }
                    break :value std.fmt.parseInt(
                        u64,
                        value,
                        10,
                    ) catch null;
                },
                // String fields
                .user,
                .hostname,
                .machineid,
                .bootid,
                .comm,
                .cwd,
                .cmdline,
                .vm,
                .container,
                .targetuser,
                .targethost,
                .sessionid,
                .signal,
                => if (value.len > 0) value else null,
            };
        }

        // Not found
        return null;
    }
};

/// Parse OSC 3008: hierarchical context signalling.
///
/// Expected data format (after "3008;" prefix has been consumed by the state machine):
///   start=<id>[;<field>=<value>]*
///   end=<id>[;<field>=<value>]*
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

    // Determine the action (start= or end=)
    const action: Command.Action = action: {
        if (std.mem.startsWith(u8, data, "start=")) break :action .start;
        if (std.mem.startsWith(u8, data, "end=")) break :action .end;

        log.warn("OSC 3008: expected 'start=' or 'end=' prefix, got: {s}", .{
            data[0..@min(data.len, 10)],
        });
        parser.state = .invalid;
        return null;
    };

    // Skip past the "start=" or "end=" prefix
    const prefix_len: usize = switch (action) {
        .start => "start=".len,
        .end => "end=".len,
    };
    const rest = data[prefix_len..];

    if (rest.len == 0) {
        log.warn("OSC 3008: missing context ID", .{});
        parser.state = .invalid;
        return null;
    }

    // Extract the context ID (up to the first semicolon or end of data)
    const id_end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
    const id = rest[0..id_end];

    // Validate context ID length (1-64 chars per spec)
    if (id.len == 0 or id.len > max_context_id_len) {
        log.warn("OSC 3008: context ID length {d} out of range (1-{d})", .{
            id.len,
            max_context_id_len,
        });
        parser.state = .invalid;
        return null;
    }

    // Validate context ID characters (32..126 byte range per spec)
    for (id) |c| {
        if (c < 0x20 or c > 0x7e) {
            log.warn("OSC 3008: invalid character 0x{x:0>2} in context ID", .{c});
            parser.state = .invalid;
            return null;
        }
    }

    // Extract raw metadata fields (everything after the ID)
    const metadata = if (id_end < rest.len) rest[id_end + 1 ..] else "";

    parser.command = .{
        .context_signal = .{
            .action = action,
            .id = id,
            .metadata = metadata,
        },
    };

    return &parser.command;
}
