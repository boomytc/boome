const std = @import("std");
const Allocator = std.mem.Allocator;

pub const DetectError = error{
    /// Multiple actions were detected. You can specify at most one
    /// action on the CLI otherwise the behavior desired is ambiguous.
    MultipleActions,

    /// An unknown action was specified.
    InvalidAction,
};

/// Detect the action from CLI args.
pub fn detectArgs(comptime E: type, alloc: Allocator) !?E {
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();
    return try detectIter(E, &iter);
}

/// Detect the action from any iterator. Each iterator value should yield
/// a CLI argument such as "--foo".
///
/// The comptime type E must be an enum with the available actions.
/// If the type E has a decl `detectSpecialCase`, then it will be called
/// for each argument to allow handling of special cases. The function
/// signature for `detectSpecialCase` should be:
///
///   fn detectSpecialCase(arg: []const u8) ?SpecialCase(E)
///
pub fn detectIter(
    comptime E: type,
    iter: anytype,
) DetectError!?E {
    var fallback: ?E = null;
    var pending: ?E = null;
    while (iter.next()) |arg| {
        // Allow handling of special cases.
        if (@hasDecl(E, "detectSpecialCase")) special: {
            const special = E.detectSpecialCase(arg) orelse break :special;
            switch (special) {
                .action => |a| return a,
                .fallback => |a| fallback = a,
                .abort_if_no_action => if (pending == null) return null,
            }
        }

        // Commands must start with "+"
        if (arg.len == 0 or arg[0] != '+') continue;
        if (pending != null) return DetectError.MultipleActions;
        pending = std.meta.stringToEnum(E, arg[1..]) orelse
            return DetectError.InvalidAction;
    }

    // If we have an action, we always return that action, even if we've
    // seen "--help" or "-h" because the action may have its own help text.
    if (pending != null) return pending;

    // If we have no action but we have a fallback, then we return that.
    if (fallback) |a| return a;

    return null;
}

/// The action enum E can implement the decl `detectSpecialCase` to
/// return this enum in order to perform various special case actions.
pub fn SpecialCase(comptime E: type) type {
    return union(enum) {
        /// Immediately return this action.
        action: E,

        /// Return this action if no other action is found.
        fallback: E,

        /// If there is no pending action (we haven't seen an action yet)
        /// then we should return no action. This is kind of weird but is
        /// a special case to allow "-e" in Ghostty.
        abort_if_no_action,
    };
}
