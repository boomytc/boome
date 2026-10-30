const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("../main.zig");
const point = terminal.point;
const FlattenedHighlight = @import("../highlight.zig").Flattened;
const Page = terminal.Page;
const PageList = terminal.PageList;
const Pin = PageList.Pin;
const Selection = terminal.Selection;
const Screen = terminal.Screen;
const SlidingWindow = @import("sliding_window.zig").SlidingWindow;

/// Searches for a term in a PageList structure.
///
/// This searches in reverse order starting from the given node.
///
/// This assumes that nodes do not change contents. For nodes that change
/// contents, look at ActiveSearch, which is designed to re-search the active
/// area since it assumed to change. When integrating ActiveSearch with
/// PageListSearch, the caller should start the PageListSearch from the
/// returned node from ActiveSearch.update().
///
/// Concurrent access to a PageList or nodes in a PageList are not allowed,
/// so the caller should ensure that necessary locks are held. Each function
/// documents whether it accesses the PageList or not. For example, you can
/// safely call `next()` without holding a lock, but you must hold a lock
/// while calling `feed()`.
pub const PageListSearch = struct {
    /// The list we're searching.
    list: *PageList,

    /// The sliding window of page contents and nodes to search.
    window: SlidingWindow,

    /// The tracked pin for our current position in the pagelist. This
    /// will always point to the CURRENT node we're searching from so that
    /// we can track if we move.
    pin: *Pin,

    /// Initialize the page list search. The needle is copied so it can
    /// be freed immediately.
    ///
    /// Accesses the PageList/Node so the caller must ensure it is safe
    /// to do so if there is any concurrent access.
    pub fn init(
        alloc: Allocator,
        needle: []const u8,
        list: *PageList,
        start: *PageList.List.Node,
    ) Allocator.Error!PageListSearch {
        // We put a tracked pin into the node that we're starting from.
        // By using a tracked pin, we can keep our pagelist references safe
        // because if the pagelist prunes pages, the tracked pin will
        // be moved somewhere safe.
        const pin = try list.trackPin(.{
            .node = start,
            .y = start.data.size.rows - 1,
            .x = start.data.size.cols - 1,
        });
        errdefer list.untrackPin(pin);

        // Create our sliding window we'll use for searching.
        var window: SlidingWindow = try .init(alloc, .reverse, needle);
        errdefer window.deinit();

        // We always feed our initial page data into the window, because
        // we have the lock anyways and this lets our `pin` point to our
        // current node and feed to work properly.
        _ = try window.append(start);

        return .{
            .list = list,
            .window = window,
            .pin = pin,
        };
    }

    /// Modifies the PageList (to untrack a pin) so the caller must ensure
    /// that it is safe to do so.
    pub fn deinit(self: *PageListSearch) void {
        self.window.deinit();
        self.list.untrackPin(self.pin);
    }

    /// Return the next match in the loaded page nodes. If this returns
    /// null then the PageList search needs to be fed the next node(s).
    /// Call, `feed` to do this.
    ///
    /// Beware that the selection returned may point to a node that
    /// is freed if the caller does not hold necessary locks on the
    /// PageList while searching. The pins should be validated prior to
    /// final use.
    ///
    /// This does NOT access the PageList, so it can be called without
    /// a lock held.
    pub fn next(self: *PageListSearch) ?FlattenedHighlight {
        return self.window.next();
    }

    /// Feed more data to the sliding window from the pagelist. This will
    /// feed enough data to cover at least one match (needle length) if it
    /// exists; this doesn't perform the search, it only feeds data.
    ///
    /// This accesses nodes in the PageList, so the caller must ensure
    /// it is safe to do so (i.e. hold necessary locks).
    ///
    /// This returns false if there is no more data to feed. This essentially
    /// means we've searched the entire pagelist.
    pub fn feed(self: *PageListSearch) Allocator.Error!bool {
        // If our pin becomes garbage it means wherever we were next
        // was reused and we can't make sense of our progress anymore.
        // It is effectively equivalent to reaching the end of the PageList.
        if (self.pin.garbage) return false;

        // Add at least enough data to find a single match.
        var rem = self.window.needle.len;

        // Start at our previous node and then continue adding until we
        // get our desired amount of data.
        var node_: ?*PageList.List.Node = self.pin.node.prev;
        while (node_) |node| : (node_ = node.prev) {
            rem -|= try self.window.append(node);

            // Move our tracked pin to the new node.
            self.pin.node = node;

            if (rem == 0) break;
        }

        // True if we fed any data.
        return rem < self.window.needle.len;
    }
};
