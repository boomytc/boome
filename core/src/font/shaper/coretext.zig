const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const macos = @import("macos");
const font = @import("../main.zig");
const os = @import("../../os/main.zig");
const unicode = @import("../../unicode/main.zig");
const Feature = font.shape.Feature;
const FeatureList = font.shape.FeatureList;
const default_features = font.shape.default_features;
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Group = font.Group;
const GroupCache = font.GroupCache;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;
const CFReleaseThread = os.CFReleaseThread;

const log = std.log.scoped(.font_shaper);

/// Shaper that uses CoreText.
///
/// CoreText shaping differs in subtle ways from HarfBuzz so it may result
/// in inconsistent rendering across platforms. But it also fixes many
/// issues (some macOS specific):
///
///   - Theta hat offset is incorrect in HarfBuzz but correct by default
///     on macOS applications using CoreText. (See:
///     https://github.com/harfbuzz/harfbuzz/discussions/4525)
///
///   - Hyphens (U+2010) can be synthesized by CoreText but not by HarfBuzz.
///     See: https://github.com/mitchellh/ghostty/issues/1643
///
pub const Shaper = struct {
    /// The allocated used for the feature list, font cache, and cell buf.
    alloc: Allocator,

    /// The string used for shaping the current run.
    run_state: RunState,

    /// CoreFoundation Dictionary which represents our font feature settings.
    features: *macos.foundation.Dictionary,
    /// A version of the features dictionary with the default features excluded.
    features_no_default: *macos.foundation.Dictionary,

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,

    /// Cached attributes dict for creating CTTypesetter objects.
    /// The values in this never change so we can avoid overhead
    /// by just creating it once and saving it for reuse.
    typesetter_attr_dict: *macos.foundation.Dictionary,

    /// List where we cache fonts, so we don't have to remake them for
    /// every single shaping operation.
    ///
    /// Fonts are cached as attribute dictionaries to be applied directly to
    /// attributed strings.
    cached_fonts: std.ArrayListUnmanaged(?*macos.foundation.Dictionary),

    /// The grid that our cached fonts correspond to.
    /// If the grid changes then we need to reset our cache.
    cached_font_grid: usize,

    /// The list of CoreFoundation objects to release on the dedicated
    /// release thread. This is built up over the course of shaping and
    /// sent to the release thread when endFrame is called.
    cf_release_pool: std.ArrayListUnmanaged(*anyopaque),

    /// Dedicated thread for releasing CoreFoundation objects. Some objects,
    /// such as those produced by CoreText, have excessively slow release
    /// callback logic.
    cf_release_thread: *CFReleaseThread,
    cf_release_thr: std.Thread,

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);
    const CodepointList = std.ArrayListUnmanaged(Codepoint);
    const Codepoint = struct {
        codepoint: u32,
        cluster: u32,
    };

    const RunState = struct {
        codepoints: CodepointList,
        unichars: std.ArrayListUnmanaged(u16),

        fn init() RunState {
            return .{ .codepoints = .{}, .unichars = .{} };
        }

        fn deinit(self: *RunState, alloc: Allocator) void {
            self.codepoints.deinit(alloc);
            self.unichars.deinit(alloc);
        }

        fn reset(self: *RunState) void {
            self.codepoints.clearRetainingCapacity();
            self.unichars.clearRetainingCapacity();
        }
    };

    const Offset = struct {
        cluster: u32 = 0,
        x: f64 = 0,
    };

    /// Create a CoreFoundation Dictionary suitable for
    /// settings the font features of a CoreText font.
    fn makeFeaturesDict(feats: []const Feature) !*macos.foundation.Dictionary {
        const list = try macos.foundation.MutableArray.create();
        // The list will be retained by the dict once we add it to it.
        defer list.release();

        for (feats) |feat| {
            const value_num: c_int = @intCast(feat.value);

            // Keys can only be ASCII.
            var key = try macos.foundation.String.createWithBytes(&feat.tag, .ascii, false);
            defer key.release();
            var value = try macos.foundation.Number.create(.int, &value_num);
            defer value.release();

            const dict = try macos.foundation.Dictionary.create(
                &[_]?*const anyopaque{
                    macos.text.c.kCTFontOpenTypeFeatureTag,
                    macos.text.c.kCTFontOpenTypeFeatureValue,
                },
                &[_]?*const anyopaque{ key, value },
            );
            defer dict.release();

            list.appendValue(macos.foundation.Dictionary, dict);
        }

        var dict = try macos.foundation.Dictionary.create(
            &[_]?*const anyopaque{macos.text.c.kCTFontFeatureSettingsAttribute},
            &[_]?*const anyopaque{list},
        );
        errdefer dict.release();

        return dict;
    }

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        var feature_list: FeatureList = .{};
        defer feature_list.deinit(alloc);
        for (opts.features) |feature_str| {
            try feature_list.appendFromString(alloc, feature_str);
        }

        // We need to construct two attrs dictionaries for font features;
        // one without the default features included, and one with them.
        const feats = feature_list.features.items;
        const feats_df = try alloc.alloc(Feature, feats.len + default_features.len);
        defer alloc.free(feats_df);

        @memcpy(feats_df[0..default_features.len], &default_features);
        @memcpy(feats_df[default_features.len..], feats);

        const features = try makeFeaturesDict(feats_df);
        errdefer features.release();
        const features_no_default = try makeFeaturesDict(feats);
        errdefer features_no_default.release();

        var run_state = RunState.init();
        errdefer run_state.deinit(alloc);

        // For now we only support LTR text. If we shape RTL text then
        // rendering will be very wrong so we need to explicitly force
        // LTR no matter what.
        //
        // See: https://github.com/mitchellh/ghostty/issues/1737
        // See: https://github.com/mitchellh/ghostty/issues/1442
        //
        // We used to do this by setting the writing direction attribute
        // on the attributed string we used, but it seems like that will
        // still allow some weird results, for example a single space at
        // the end of a line composed of RTL characters will be cause it
        // to output a run containing just that space, BEFORE it outputs
        // the rest of the line as a separate run, very weirdly with the
        // "right to left" flag set in the single space run's run status...
        //
        // So instead what we do is use a CTTypesetter to create our line,
        // using the kCTTypesetterOptionForcedEmbeddingLevel attribute to
        // force CoreText not to try doing any sort of BiDi, instead just
        // treat all text as embedding level 0 (left to right).
        const typesetter_attr_dict = dict: {
            const num = try macos.foundation.Number.create(.int, &0);
            defer num.release();
            break :dict try macos.foundation.Dictionary.create(
                &.{macos.c.kCTTypesetterOptionForcedEmbeddingLevel},
                &.{num},
            );
        };
        errdefer typesetter_attr_dict.release();

        // Create the CF release thread.
        var cf_release_thread = try alloc.create(CFReleaseThread);
        errdefer alloc.destroy(cf_release_thread);
        cf_release_thread.* = try .init(alloc);
        errdefer cf_release_thread.deinit();

        // Start the CF release thread.
        var cf_release_thr = try std.Thread.spawn(
            .{},
            CFReleaseThread.threadMain,
            .{cf_release_thread},
        );
        cf_release_thr.setName("cf_release") catch {};

        return .{
            .alloc = alloc,
            .cell_buf = .{},
            .run_state = run_state,
            .features = features,
            .features_no_default = features_no_default,
            .typesetter_attr_dict = typesetter_attr_dict,
            .cached_fonts = .{},
            .cached_font_grid = 0,
            .cf_release_pool = .{},
            .cf_release_thread = cf_release_thread,
            .cf_release_thr = cf_release_thr,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.cell_buf.deinit(self.alloc);
        self.run_state.deinit(self.alloc);
        self.features.release();
        self.features_no_default.release();
        self.typesetter_attr_dict.release();

        {
            for (self.cached_fonts.items) |ft| {
                if (ft) |f| f.release();
            }
            self.cached_fonts.deinit(self.alloc);
        }

        if (self.cf_release_pool.items.len > 0) {
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);

            log.warn(
                "BUG: CFRelease pool was not empty, releasing remaining objects",
                .{},
            );
        }
        self.cf_release_pool.deinit(self.alloc);

        // Stop the CF release thread
        {
            self.cf_release_thread.stop.notify() catch |err|
                log.err("error notifying cf release thread to stop, may stall err={}", .{err});
            self.cf_release_thr.join();
        }
        self.cf_release_thread.deinit();
        self.alloc.destroy(self.cf_release_thread);
    }

    pub fn endFrame(self: *Shaper) void {
        if (self.cf_release_pool.items.len == 0) return;

        // Get all the items in the pool as an owned slice so we can
        // send it to the dedicated release thread.
        const items = self.cf_release_pool.toOwnedSlice(self.alloc) catch |err| {
            log.warn("error converting release pool to owned slice, slow release err={}", .{err});
            for (self.cf_release_pool.items) |ref| macos.foundation.CFRelease(ref);
            self.cf_release_pool.clearRetainingCapacity();
            return;
        };

        // Send the items. If the send succeeds then we wake up the
        // thread to process the items. If the send fails then do a manual
        // cleanup.
        if (self.cf_release_thread.mailbox.push(.{ .release = .{
            .refs = items,
            .alloc = self.alloc,
        } }, .{ .forever = {} }) != 0) {
            self.cf_release_thread.wakeup.notify() catch |err| {
                log.warn(
                    "error notifying cf release thread to wake up, may stall err={}",
                    .{err},
                );
            };
            return;
        }

        for (items) |ref| macos.foundation.CFRelease(ref);
        self.alloc.free(items);
    }

    pub fn runIterator(
        self: *Shaper,
        opts: font.shape.RunOptions,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .opts = opts,
        };
    }

    /// Note that this will accumulate garbage in the release pool. The
    /// caller must ensure you're properly calling endFrame to release
    /// all the objects.
    pub fn shape(
        self: *Shaper,
        run: font.shape.TextRun,
    ) ![]const font.shape.Cell {
        const state = &self.run_state;

        // {
        //     log.debug("shape -----------------------------------", .{});
        //     for (state.codepoints.items) |entry| {
        //         log.debug("cp={X} cluster={}", .{ entry.codepoint, entry.cluster });
        //     }
        //     log.debug("shape end -------------------------------", .{});
        // }

        // Special fonts aren't shaped and their codepoint == glyph so we
        // can just return the codepoints as-is.
        if (run.font_index.special() != null) {
            self.cell_buf.clearRetainingCapacity();
            try self.cell_buf.ensureTotalCapacity(self.alloc, state.codepoints.items.len);
            for (state.codepoints.items) |entry| {
                // We use null codepoints to pad out our list so indices match
                // the UTF-16 string we constructed for CoreText. We don't want
                // to emit these if this is a special font, since they're not
                // part of the original run.
                if (entry.codepoint == 0) continue;

                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(entry.cluster),
                    .glyph_index = @intCast(entry.codepoint),
                });
            }

            return self.cell_buf.items;
        }

        // Create an arena for any Zig-based allocations we do
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        const attr_dict: *macos.foundation.Dictionary = try self.getFont(
            run.grid,
            run.font_index,
        );

        // Make room for the attributed string, CTTypesetter, and CTLine.
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 4);

        const str = macos.foundation.String.createWithCharactersNoCopy(state.unichars.items);
        self.cf_release_pool.appendAssumeCapacity(str);

        // Create an attributed string from our string
        const attr_str = try macos.foundation.AttributedString.create(
            str,
            attr_dict,
        );
        self.cf_release_pool.appendAssumeCapacity(attr_str);

        // Create a typesetter from the attributed string and the cached
        // attr dict. (See comment in init for more info on the attr dict.)
        const typesetter =
            try macos.text.Typesetter.createWithAttributedStringAndOptions(
                attr_str,
                self.typesetter_attr_dict,
            );
        self.cf_release_pool.appendAssumeCapacity(typesetter);

        // Create a line from the typesetter
        const line = typesetter.createLine(.{ .location = 0, .length = 0 });
        self.cf_release_pool.appendAssumeCapacity(line);

        // This keeps track of the current x offset (sum of advance.width) and
        // the furthest cluster we've seen so far (max).
        var run_offset: Offset = .{};

        // This keeps track of the cell starting x and cluster.
        var cell_offset: Offset = .{};

        // For debugging positions, turn this on:
        //var run_offset_y: f64 = 0.0;
        //var cell_offset_y: f64 = 0.0;

        // Clear our cell buf and make sure we have enough room for the whole
        // line of glyphs, so that we can just assume capacity when appending
        // instead of maybe allocating.
        self.cell_buf.clearRetainingCapacity();
        try self.cell_buf.ensureTotalCapacity(self.alloc, line.getGlyphCount());

        // CoreText, despite our insistence with an enforced embedding level,
        // may sometimes output runs that are non-monotonic. In order to fix
        // this, we check the run status for each run and if any aren't ltr
        // we set this to true, which indicates that we must sort our buffer.
        var non_ltr: bool = false;

        // CoreText may generate multiple runs even though our input to
        // CoreText is already split into runs by our own run iterator.
        // The runs as far as I can tell are always sequential to each
        // other so we can iterate over them and just append to our
        // cell buffer.
        const runs = line.getGlyphRuns();
        for (0..runs.getCount()) |run_i| {
            const ctrun = runs.getValueAtIndex(macos.text.Run, run_i);

            const status = ctrun.getStatus();
            if (status.non_monotonic or status.right_to_left) non_ltr = true;

            // Get our glyphs and positions
            const glyphs = ctrun.getGlyphsPtr() orelse try ctrun.getGlyphs(alloc);
            const advances = ctrun.getAdvancesPtr() orelse try ctrun.getAdvances(alloc);
            const positions = ctrun.getPositionsPtr() orelse try ctrun.getPositions(alloc);
            const indices = ctrun.getStringIndicesPtr() orelse try ctrun.getStringIndices(alloc);
            assert(glyphs.len == advances.len);
            assert(glyphs.len == positions.len);
            assert(glyphs.len == indices.len);

            for (
                glyphs,
                advances,
                positions,
                indices,
            ) |glyph, advance, position, index| {
                // Our cluster is also our cell X position. If the cluster changes
                // then we need to reset our current cell offsets.
                const cluster = state.codepoints.items[index].cluster;
                if (cell_offset.cluster != cluster) {
                    // We previously asserted that the new cluster is greater
                    // than cell_offset.cluster, but this isn't always true.
                    // See e.g. the "shape Chakma vowel sign with ligature
                    // (vowel sign renders first)" test.

                    const is_after_glyph_from_current_or_next_clusters =
                        cluster <= run_offset.cluster;

                    const is_first_codepoint_in_cluster = blk: {
                        var i = index;
                        while (i > 0) {
                            i -= 1;
                            const codepoint = state.codepoints.items[i];

                            // Skip surrogate pair padding
                            if (codepoint.codepoint == 0) continue;
                            break :blk codepoint.cluster != cluster;
                        } else break :blk true;
                    };

                    // We need to reset the `cell_offset` at the start of a new
                    // cluster, but we do that conditionally if the codepoint
                    // `is_first_codepoint_in_cluster` and the cluster is not
                    // `is_after_glyph_from_current_or_next_clusters`, which is
                    // a heuristic to detect ligatures and avoid positioning
                    // glyphs that mark ligatures incorrectly. The idea is that
                    // if the first codepoint in a cluster doesn't appear in
                    // the stream, it's very likely that it combined with
                    // codepoints from a previous cluster into a ligature.
                    // Then, the subsequent codepoints are very likely marking
                    // glyphs that are placed relative to that ligature, so if
                    // we were to reset the `cell_offset` to align it with the
                    // grid, the positions would be off. The
                    // `!is_after_glyph_from_current_or_next_clusters` check is
                    // needed in case these marking glyphs come from a later
                    // cluster but are rendered first (see the Chakma and
                    // Bengali tests). In that case when we get to the
                    // codepoint that `is_first_codepoint_in_cluster`, but in a
                    // cluster that
                    // `is_after_glyph_from_current_or_next_clusters`, we don't
                    // want to reset to the grid and cause the positions to be
                    // off. (Note that we could go back and align the cells to
                    // the grid starting from the one from the cluster that
                    // rendered out of order, but that is more complicated so
                    // we don't do that for now. Also, it's TBD if there are
                    // exceptions to this heuristic for detecting ligatures,
                    // but using the logging below seems to show it works
                    // well.)
                    if (is_first_codepoint_in_cluster and
                        !is_after_glyph_from_current_or_next_clusters)
                    {
                        cell_offset = .{
                            .cluster = cluster,
                            .x = run_offset.x,
                        };

                        // For debugging positions, turn this on:
                        //cell_offset_y = run_offset_y;
                    }
                }

                // For debugging positions, turn this on:
                //try self.debugPositions(alloc, run_offset, run_offset_y, cell_offset, cell_offset_y, position, index);

                const x_offset = position.x - cell_offset.x;

                self.cell_buf.appendAssumeCapacity(.{
                    .x = @intCast(cell_offset.cluster),
                    .x_offset = @intFromFloat(@round(x_offset)),
                    .y_offset = @intFromFloat(@round(position.y)),
                    .glyph_index = glyph,
                });

                // Add our advances to keep track of our run offsets.
                // Advances apply to the NEXT cell.
                run_offset.x += advance.width;
                run_offset.cluster = @max(run_offset.cluster, cluster);

                // For debugging positions, turn this on:
                //run_offset_y += advance.height;
            }
        }

        // If our buffer contains some non-ltr sections we need to sort it :/
        if (non_ltr) {
            // This is EXCEPTIONALLY rare. Only happens for languages with
            // complex shaping which we don't even really support properly
            // right now, so are very unlikely to be used heavily by users
            // of Ghostty.
            @branchHint(.cold);
            std.mem.sort(
                font.shape.Cell,
                self.cell_buf.items,
                {},
                struct {
                    fn lt(_: void, a: font.shape.Cell, b: font.shape.Cell) bool {
                        return a.x < b.x;
                    }
                }.lt,
            );
        }

        return self.cell_buf.items;
    }

    /// Get an attr dict for a font from a specific index.
    /// These items are cached, do not retain or release them.
    fn getFont(
        self: *Shaper,
        grid: *font.SharedGrid,
        index: font.Collection.Index,
    ) !*macos.foundation.Dictionary {
        // If this grid doesn't match the one we've cached fonts for,
        // then we reset the cache list since it's no longer valid.
        // We use an intFromPtr rather than direct pointer comparison
        // because we don't want anyone to inadvertently use the pointer.
        const grid_id: usize = @intFromPtr(grid);
        if (grid_id != self.cached_font_grid) {
            if (self.cached_font_grid > 0) {
                // Put all the currently cached fonts in to
                // the release pool before clearing the list.
                try self.cf_release_pool.ensureUnusedCapacity(
                    self.alloc,
                    self.cached_fonts.items.len,
                );
                for (self.cached_fonts.items) |ft| {
                    if (ft) |f| {
                        self.cf_release_pool.appendAssumeCapacity(f);
                    }
                }
                self.cached_fonts.clearRetainingCapacity();
            }

            self.cached_font_grid = grid_id;
        }

        const index_int = index.int();

        // The cached fonts are indexed directly by the font index, since
        // this number is usually low. Therefore, we set any index we haven't
        // seen to null.
        if (self.cached_fonts.items.len <= index_int) {
            try self.cached_fonts.ensureTotalCapacity(self.alloc, index_int + 1);
            while (self.cached_fonts.items.len <= index_int) {
                self.cached_fonts.appendAssumeCapacity(null);
            }
        }

        // If we have it, return the cached attr dict.
        if (self.cached_fonts.items[index_int]) |cached| return cached;

        // Font descriptor, font
        try self.cf_release_pool.ensureUnusedCapacity(self.alloc, 2);

        const run_font = font: {
            // The CoreText shaper relies on CoreText and CoreText claims
            // that CTFonts are threadsafe. See:
            // https://developer.apple.com/documentation/coretext/
            //
            // Quote:
            // All individual functions in Core Text are thread-safe. Font
            // objects (CTFont, CTFontDescriptor, and associated objects) can
            // be used simultaneously by multiple operations, work queues, or
            // threads. However, the layout objects (CTTypesetter,
            // CTFramesetter, CTRun, CTLine, CTFrame, and associated objects)
            // should be used in a single operation, work queue, or thread.
            //
            // Because of this, we only acquire the read lock to grab the
            // face and set it up, then release it.
            grid.lock.lockShared();
            defer grid.lock.unlockShared();

            const face = try grid.resolver.collection.getFace(index);
            const original = face.font;

            const attrs = if (face.quirks_disable_default_font_features)
                self.features_no_default
            else
                self.features;

            const desc = try macos.text.FontDescriptor.createWithAttributes(attrs);
            self.cf_release_pool.appendAssumeCapacity(desc);

            const copied = try original.copyWithAttributes(0, null, desc);
            errdefer copied.release();

            break :font copied;
        };
        self.cf_release_pool.appendAssumeCapacity(run_font);

        // Get our font and use that get the attributes to set for the
        // attributed string so the whole string uses the same font.
        const attr_dict = dict: {
            break :dict try macos.foundation.Dictionary.create(
                &.{macos.text.StringAttribute.font.key()},
                &.{run_font},
            );
        };

        self.cached_fonts.items[index_int] = attr_dict;
        return attr_dict;
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: *RunIteratorHook) void {
            self.shaper.run_state.reset();
            // log.warn("----------- run reset -------------", .{});
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            const state = &self.shaper.run_state;

            // Build our UTF-16 string for CoreText
            try state.unichars.ensureUnusedCapacity(self.shaper.alloc, 2);

            state.unichars.appendNTimesAssumeCapacity(0, 2);

            const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(
                cp,
                state.unichars.items[state.unichars.items.len - 2 ..][0..2],
            );
            if (!pair) {
                state.unichars.items.len -= 1;
            }

            // Build our reverse lookup table for codepoints to clusters
            try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = cp,
                .cluster = cluster,
            });
            // log.warn("run cp={X}", .{cp});

            // If the UTF-16 codepoint is a pair then we need to insert
            // a dummy entry so that the CTRunGetStringIndices() function
            // maps correctly.
            if (pair) try state.codepoints.append(self.shaper.alloc, .{
                .codepoint = 0,
                .cluster = cluster,
            });
        }

        pub fn finalize(self: RunIteratorHook) void {
            _ = self;
        }
    };

    fn debugPositions(
        self: *Shaper,
        alloc: Allocator,
        run_offset: Offset,
        run_offset_y: f64,
        cell_offset: Offset,
        cell_offset_y: f64,
        position: macos.graphics.Point,
        index: usize,
    ) !void {
        const state = &self.run_state;
        const x_offset = position.x - cell_offset.x;
        const advance_x_offset = run_offset.x - cell_offset.x;
        const advance_y_offset = run_offset_y - cell_offset_y;
        const x_offset_diff = x_offset - advance_x_offset;
        const y_offset_diff = position.y - advance_y_offset;
        const positions_differ = @abs(x_offset_diff) > 0.0001 or @abs(y_offset_diff) > 0.0001;
        const old_offset_y = position.y - cell_offset_y;
        const position_y_differs = @abs(cell_offset_y) > 0.0001;
        const cluster = state.codepoints.items[index].cluster;
        const cluster_differs = cluster != cell_offset.cluster;

        // To debug every loop, flip this to true:
        const extra_debugging = false;

        const is_previous_codepoint_prepend = if (cluster_differs or
            extra_debugging)
        blk: {
            var i = index;
            while (i > 0) {
                i -= 1;
                const codepoint = state.codepoints.items[i];

                // Skip surrogate pair padding
                if (codepoint.codepoint == 0) continue;

                break :blk unicode.table.get(@intCast(codepoint.codepoint)).grapheme_boundary_class == .prepend;
            }
            break :blk false;
        } else false;

        const formatted_cps = if (positions_differ or
            position_y_differs or
            cluster_differs or
            extra_debugging)
        blk: {
            var allocating = std.Io.Writer.Allocating.init(alloc);
            const writer = &allocating.writer;
            const codepoints = state.codepoints.items;
            var last_cluster: ?u32 = null;
            for (codepoints, 0..) |cp, i| {
                if ((@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1) and
                    cp.codepoint != 0 // Skip surrogate pair padding
                ) {
                    if (last_cluster) |last| {
                        if (cp.cluster != last) {
                            try writer.writeAll(" ");
                        }
                    }
                    if (i == index) {
                        try writer.writeAll("▸");
                    }
                    // Using Python syntax for easier debugging
                    if (cp.codepoint > 0xFFFF) {
                        try writer.print("\\U{x:0>8}", .{cp.codepoint});
                    } else {
                        try writer.print("\\u{x:0>4}", .{cp.codepoint});
                    }
                    last_cluster = cp.cluster;
                }
            }
            try writer.writeAll(" → ");
            for (codepoints) |cp| {
                if ((@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1) and
                    cp.codepoint != 0 // Skip surrogate pair padding
                ) {
                    try writer.print("{u}", .{@as(u21, @intCast(cp.codepoint))});
                }
            }
            break :blk try allocating.toOwnedSlice();
        } else "";

        if (extra_debugging) {
            log.warn("extra debugging of positions index={d} cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) is_prev_prepend={} cps = {s}", .{
                index,
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                is_previous_codepoint_prepend,
                formatted_cps,
            });
        }

        if (positions_differ) {
            log.warn("position differs from advance: cluster={d} pos=({d:.2},{d:.2}) adv=({d:.2},{d:.2}) diff=({d:.2},{d:.2}) cps = {s}", .{
                cluster,
                x_offset,
                position.y,
                advance_x_offset,
                advance_y_offset,
                x_offset_diff,
                y_offset_diff,
                formatted_cps,
            });
        }

        if (position_y_differs) {
            log.warn("position.y differs from old offset.y: cluster={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) old offset.y={d:.2} cps = {s}", .{
                cluster,
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                old_offset_y,
                formatted_cps,
            });
        }

        if (cluster_differs) {
            log.warn("cell_offset.cluster differs from cluster (potential ligature detected) cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d:.2},{d:.2}) run_offset=({d:.2},{d:.2}) cell_offset=({d:.2},{d:.2}) is_prev_prepend={} cps = {s}", .{
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                position.y,
                run_offset.x,
                run_offset_y,
                cell_offset.x,
                cell_offset_y,
                is_previous_codepoint_prepend,
                formatted_cps,
            });
        }
    }
};
