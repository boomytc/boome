const std = @import("std");
const Allocator = std.mem.Allocator;
const lib_alloc = @import("../../lib/allocator.zig");
const CAllocator = lib_alloc.Allocator;
const key_encode = @import("../../input/key_encode.zig");
const OptionAsAlt = @import("../../input/config.zig").OptionAsAlt;
const Result = @import("result.zig").Result;
const KeyEvent = @import("key_event.zig").Event;

const log = std.log.scoped(.key_encode);

/// Wrapper around key encoding options that tracks the allocator for C API usage.
const KeyEncoderWrapper = struct {
    opts: key_encode.Options,
    alloc: Allocator,
};

/// C: GhosttyKeyEncoder
pub const Encoder = ?*KeyEncoderWrapper;

pub fn new(
    alloc_: ?*const CAllocator,
    result: *Encoder,
) callconv(.c) Result {
    const alloc = lib_alloc.default(alloc_);
    const ptr = alloc.create(KeyEncoderWrapper) catch
        return .out_of_memory;
    ptr.* = .{
        .opts = .{},
        .alloc = alloc,
    };
    result.* = ptr;
    return .success;
}

pub fn free(encoder_: Encoder) callconv(.c) void {
    const wrapper = encoder_ orelse return;
    const alloc = wrapper.alloc;
    alloc.destroy(wrapper);
}

/// C: GhosttyKeyEncoderOption
pub const Option = enum(c_int) {
    cursor_key_application = 0,
    keypad_key_application = 1,
    ignore_keypad_with_numlock = 2,
    alt_esc_prefix = 3,
    modify_other_keys_state_2 = 4,
    kitty_flags = 5,
    macos_option_as_alt = 6,

    /// Input type expected for setting the option.
    pub fn InType(comptime self: Option) type {
        return switch (self) {
            .cursor_key_application,
            .keypad_key_application,
            .ignore_keypad_with_numlock,
            .alt_esc_prefix,
            .modify_other_keys_state_2,
            => bool,
            .kitty_flags => u8,
            .macos_option_as_alt => OptionAsAlt,
        };
    }
};

pub fn setopt(
    encoder_: Encoder,
    option: Option,
    value: ?*const anyopaque,
) callconv(.c) void {
    if (comptime std.debug.runtime_safety) {
        _ = std.meta.intToEnum(Option, @intFromEnum(option)) catch {
            log.warn("setopt invalid option value={d}", .{@intFromEnum(option)});
            return;
        };
    }

    return switch (option) {
        inline else => |comptime_option| setoptTyped(
            encoder_,
            comptime_option,
            @ptrCast(@alignCast(value orelse return)),
        ),
    };
}

fn setoptTyped(
    encoder_: Encoder,
    comptime option: Option,
    value: *const option.InType(),
) void {
    const opts = &encoder_.?.opts;
    switch (option) {
        .cursor_key_application => opts.cursor_key_application = value.*,
        .keypad_key_application => opts.keypad_key_application = value.*,
        .ignore_keypad_with_numlock => opts.ignore_keypad_with_numlock = value.*,
        .alt_esc_prefix => opts.alt_esc_prefix = value.*,
        .modify_other_keys_state_2 => opts.modify_other_keys_state_2 = value.*,
        .kitty_flags => opts.kitty_flags = flags: {
            const bits: u5 = @truncate(value.*);
            break :flags @bitCast(bits);
        },
        .macos_option_as_alt => {
            if (comptime std.debug.runtime_safety) {
                _ = std.meta.intToEnum(OptionAsAlt, @intFromEnum(value.*)) catch {
                    log.warn("setopt invalid OptionAsAlt value={d}", .{@intFromEnum(value.*)});
                    return;
                };
            }
            opts.macos_option_as_alt = value.*;
        },
    }
}

pub fn encode(
    encoder_: Encoder,
    event_: KeyEvent,
    out_: ?[*]u8,
    out_len: usize,
    out_written: *usize,
) callconv(.c) Result {
    // Attempt to write to this buffer
    var writer: std.Io.Writer = .fixed(if (out_) |out| out[0..out_len] else &.{});
    key_encode.encode(
        &writer,
        event_.?.event,
        encoder_.?.opts,
    ) catch |err| switch (err) {
        error.WriteFailed => {
            // If we don't have space, use a discarding writer to count
            // how much space we would have needed.
            var discarding: std.Io.Writer.Discarding = .init(&.{});
            key_encode.encode(
                &discarding.writer,
                event_.?.event,
                encoder_.?.opts,
            ) catch unreachable;

            // Discarding always uses a u64. If we're on 32-bit systems
            // we cast down. We should make this safer in the future.
            out_written.* = @intCast(discarding.count);
            return .out_of_memory;
        },
    };

    out_written.* = writer.end;
    return .success;
}
