/// A string along with the mapping of each individual byte in the string
/// to the point in the screen.
const StringMap = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const oni = @import("oniguruma");
const Selection = @import("Selection.zig");
const Pin = @import("PageList.zig").Pin;
const Allocator = std.mem.Allocator;

// Retry budget for StringMap regex searches.
//
// Units are Oniguruma retry steps (internal backtracking/retry counter),
// not bytes/characters/time.
const oni_search_retry_limit = 100_000;

string: [:0]const u8,
map: []Pin,

pub fn deinit(self: StringMap, alloc: Allocator) void {
    alloc.free(self.string);
    alloc.free(self.map);
}

/// Returns an iterator that yields the next match of the given regex.
/// Requires Ghostty to be compiled with regex support.
pub const searchIterator = if (build_options.oniguruma)
    searchIteratorOni
else
    void;

fn searchIteratorOni(
    self: StringMap,
    regex: oni.Regex,
) SearchIterator {
    return .{ .map = self, .regex = regex };
}

/// Iterates over the regular expression matches of the string.
pub const SearchIterator = struct {
    map: StringMap,
    regex: oni.Regex,
    offset: usize = 0,

    /// Returns the next regular expression match or null if there are
    /// no more matches.
    pub fn next(self: *SearchIterator) !?Match {
        if (self.offset >= self.map.string.len) return null;

        // Use per-search match params so we can bound regex retry steps
        // (Oniguruma's internal backtracking work counter).
        var match_param = try oni.MatchParam.init();
        defer match_param.deinit();
        try match_param.setRetryLimitInSearch(oni_search_retry_limit);

        var region = self.regex.searchWithParam(
            self.map.string[self.offset..],
            .{},
            &match_param,
        ) catch |err| switch (err) {
            // Retry/stack-limit errors mean we hit our work budget and
            // aborted matching.
            // For iterator callers this is equivalent to "no further matches".
            error.Mismatch,
            error.RetryLimitInMatchOver,
            error.RetryLimitInSearchOver,
            error.MatchStackLimitOver,
            error.SubexpCallLimitInSearchOver,
            => {
                self.offset = self.map.string.len;
                return null;
            },

            else => return err,
        };
        errdefer region.deinit();

        // Increment our offset by the number of bytes in the match.
        // We defer this so that we can return the match before
        // modifying the offset.
        const end_idx: usize = @intCast(region.ends()[0]);
        defer self.offset += end_idx;

        return .{
            .map = self.map,
            .offset = self.offset,
            .region = region,
        };
    }
};

/// A single regular expression match.
pub const Match = struct {
    map: StringMap,
    offset: usize,
    region: oni.Region,

    pub fn deinit(self: *Match) void {
        self.region.deinit();
    }

    /// Returns the selection containing the full match.
    pub fn selection(self: Match) Selection {
        const start_idx: usize = @intCast(self.region.starts()[0]);
        const end_idx: usize = @intCast(self.region.ends()[0] - 1);
        const start_pt = self.map.map[self.offset + start_idx];
        const end_pt = self.map.map[self.offset + end_idx];
        return .init(start_pt, end_pt, false);
    }
};
