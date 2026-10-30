const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const harfbuzz = @import("harfbuzz");
const font = @import("../main.zig");
const unicode = @import("../../unicode/main.zig");
const Feature = font.shape.Feature;
const FeatureList = font.shape.FeatureList;
const default_features = font.shape.default_features;
const Face = font.Face;
const Collection = font.Collection;
const DeferredFace = font.DeferredFace;
const Library = font.Library;
const SharedGrid = font.SharedGrid;
const Style = font.Style;
const Presentation = font.Presentation;

const log = std.log.scoped(.font_shaper);

/// Shaper that uses Harfbuzz.
pub const Shaper = struct {
    /// The allocated used for the feature list, cell buf, and codepoints.
    alloc: Allocator,

    /// The buffer used for text shaping. We reuse it across multiple shaping
    /// calls to prevent allocations.
    hb_buf: harfbuzz.Buffer,

    /// The shared memory used for shaping results.
    cell_buf: CellBuf,

    /// The features to use for shaping.
    hb_feats: []harfbuzz.Feature,

    /// The codepoints added to the buffer before shaping. We need to keep
    /// these separately because after shaping, HarfBuzz replaces codepoints
    /// with glyph indices in the buffer.
    codepoints: std.ArrayListUnmanaged(Codepoint) = .{},

    const Codepoint = struct {
        cluster: u32,
        codepoint: u32,
    };

    const CellBuf = std.ArrayListUnmanaged(font.shape.Cell);

    const RunOffset = struct {
        cluster: u32 = 0,
        x: i32 = 0,
        y: i32 = 0,
    };

    const CellOffset = struct {
        cluster: u32 = 0,
        x: i32 = 0,
    };

    /// The cell_buf argument is the buffer to use for storing shaped results.
    /// This should be at least the number of columns in the terminal.
    pub fn init(alloc: Allocator, opts: font.shape.Options) !Shaper {
        // Parse all the features we want to use.
        const hb_feats = hb_feats: {
            var feature_list: FeatureList = .{};
            defer feature_list.deinit(alloc);
            try feature_list.features.appendSlice(alloc, &default_features);
            for (opts.features) |feature_str| {
                try feature_list.appendFromString(alloc, feature_str);
            }

            var list = try alloc.alloc(harfbuzz.Feature, feature_list.features.items.len);
            errdefer alloc.free(list);

            for (feature_list.features.items, 0..) |feature, i| {
                list[i] = .{
                    .tag = std.mem.nativeToBig(u32, @bitCast(feature.tag)),
                    .value = feature.value,
                    .start = harfbuzz.c.HB_FEATURE_GLOBAL_START,
                    .end = harfbuzz.c.HB_FEATURE_GLOBAL_END,
                };
            }

            break :hb_feats list;
        };
        errdefer alloc.free(hb_feats);

        return Shaper{
            .alloc = alloc,
            .hb_buf = try harfbuzz.Buffer.create(),
            .cell_buf = .{},
            .hb_feats = hb_feats,
        };
    }

    pub fn deinit(self: *Shaper) void {
        self.hb_buf.destroy();
        self.cell_buf.deinit(self.alloc);
        self.alloc.free(self.hb_feats);
        self.codepoints.deinit(self.alloc);
    }

    pub fn endFrame(self: *const Shaper) void {
        _ = self;
    }

    /// Returns an iterator that returns one text run at a time for the
    /// given terminal row. Note that text runs are are only valid one at a time
    /// for a Shaper struct since they share state.
    ///
    /// The selection must be a row-only selection (height = 1). See
    /// Selection.containedRow. The run iterator will ONLY look at X values
    /// and assume the y value matches.
    pub fn runIterator(
        self: *Shaper,
        opts: font.shape.RunOptions,
    ) font.shape.RunIterator {
        return .{
            .hooks = .{ .shaper = self },
            .opts = opts,
        };
    }

    /// Shape the given text run. The text run must be the immediately previous
    /// text run that was iterated since the text run does share state with the
    /// Shaper struct.
    ///
    /// The return value is only valid until the next shape call is called.
    ///
    /// If there is not enough space in the cell buffer, an error is returned.
    pub fn shape(self: *Shaper, run: font.shape.TextRun) ![]const font.shape.Cell {
        // We only do shaping if the font is not a special-case. For special-case
        // fonts, the codepoint == glyph_index so we don't need to run any shaping.
        if (run.font_index.special() == null) {
            // We have to lock the grid to get the face and unfortunately
            // freetype faces (typically used with harfbuzz) are not thread
            // safe so this has to be an exclusive lock.
            run.grid.lock.lock();
            defer run.grid.lock.unlock();

            const face = try run.grid.resolver.collection.getFace(run.font_index);
            const i = if (!face.quirks_disable_default_font_features) 0 else i: {
                // If we are disabling default font features we just offset
                // our features by the hardcoded items because always
                // add those at the beginning.
                break :i default_features.len;
            };

            harfbuzz.shape(face.hb_font, self.hb_buf, self.hb_feats[i..]);
        }

        // If our buffer is empty, we short-circuit the rest of the work
        // return nothing.
        if (self.hb_buf.getLength() == 0) return self.cell_buf.items[0..0];
        const info = self.hb_buf.getGlyphInfos();
        const pos = self.hb_buf.getGlyphPositions() orelse return error.HarfbuzzFailed;

        // This is perhaps not true somewhere, but we currently assume it is true.
        // If it isn't true, I'd like to catch it and learn more.
        assert(info.len == pos.len);

        // This keeps track of the current x and y offsets (sum of advances)
        // and the furthest cluster we've seen so far (max).
        var run_offset: RunOffset = .{};

        // This keeps track of the cell starting x and cluster.
        var cell_offset: CellOffset = .{};

        // Convert all our info/pos to cells and set it.
        self.cell_buf.clearRetainingCapacity();
        for (info, pos) |info_v, pos_v| {
            // info_v.cluster is the index into our codepoints array. We use it
            // to get the original cluster.
            const index = info_v.cluster;
            // Our cluster is also our cell X position. If the cluster changes
            // then we need to reset our current cell offsets.
            const cluster = self.codepoints.items[index].cluster;
            if (cell_offset.cluster != cluster) {
                const is_after_glyph_from_current_or_next_clusters =
                    cluster <= run_offset.cluster;

                const is_first_codepoint_in_cluster = blk: {
                    var i = index;
                    while (i > 0) {
                        i -= 1;
                        const codepoint = self.codepoints.items[i];
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
                }
            }

            // Under both FreeType and CoreText the harfbuzz scale is
            // in 26.6 fixed point units, so we round to the nearest
            // whole value here.
            const x_offset = run_offset.x - cell_offset.x + ((pos_v.x_offset + 0b100_000) >> 6);
            const y_offset = run_offset.y + ((pos_v.y_offset + 0b100_000) >> 6);

            // For debugging positions, turn this on:
            //try self.debugPositions(run_offset, cell_offset, pos_v, index);

            try self.cell_buf.append(self.alloc, .{
                .x = @intCast(cell_offset.cluster),
                .x_offset = @intCast(x_offset),
                .y_offset = @intCast(y_offset),
                .glyph_index = info_v.codepoint,
            });

            // Add our advances to keep track of our run offsets.
            // Advances apply to the NEXT cell.
            // Under both FreeType and CoreText the harfbuzz scale is
            // in 26.6 fixed point units, so we round to the nearest
            // whole value here.
            run_offset.x += (pos_v.x_advance + 0b100_000) >> 6;
            run_offset.y += (pos_v.y_advance + 0b100_000) >> 6;
            run_offset.cluster = @max(run_offset.cluster, cluster);

            // const i = self.cell_buf.items.len - 1;
            // log.warn("i={} info={} pos={} cell={}", .{ i, info_v, pos_v, self.cell_buf.items[i] });
        }
        //log.warn("----------------", .{});

        return self.cell_buf.items;
    }

    /// The hooks for RunIterator.
    pub const RunIteratorHook = struct {
        shaper: *Shaper,

        pub fn prepare(self: RunIteratorHook) void {
            // Reset the buffer for our current run
            self.shaper.hb_buf.reset();
            self.shaper.hb_buf.setContentType(.unicode);

            // We set the cluster level to `characters` to give us the most
            // granularity, matching the CoreText shaper, and allowing us
            // to use our same ligature detection heuristics.
            self.shaper.hb_buf.setClusterLevel(.characters);

            self.shaper.codepoints.clearRetainingCapacity();

            // We don't support RTL text because RTL in terminals is messy.
            // Its something we want to improve. For now, we force LTR because
            // our renderers assume a strictly increasing X value.
            self.shaper.hb_buf.setDirection(.ltr);
        }

        pub fn addCodepoint(self: RunIteratorHook, cp: u32, cluster: u32) !void {
            // log.warn("cluster={} cp={x}", .{ cluster, cp });
            // We pass the index into codepoints as the cluster value to HarfBuzz.
            // After shaping, we use info.cluster to get back the index, which
            // lets us look up the original cluster value from codepoints.
            const index: u32 = @intCast(self.shaper.codepoints.items.len);
            self.shaper.hb_buf.add(cp, index);
            try self.shaper.codepoints.append(self.shaper.alloc, .{
                .cluster = cluster,
                .codepoint = cp,
            });
        }

        pub fn finalize(self: RunIteratorHook) void {
            self.shaper.hb_buf.guessSegmentProperties();
        }
    };

    fn debugPositions(
        self: *Shaper,
        run_offset: RunOffset,
        cell_offset: CellOffset,
        pos_v: harfbuzz.GlyphPosition,
        index: u32,
    ) !void {
        const x_offset = run_offset.x - cell_offset.x + ((pos_v.x_offset + 0b100_000) >> 6);
        const y_offset = run_offset.y + ((pos_v.y_offset + 0b100_000) >> 6);
        const advance_x_offset = run_offset.x - cell_offset.x;
        const advance_y_offset = run_offset.y;
        const x_offset_diff = x_offset - advance_x_offset;
        const y_offset_diff = y_offset - advance_y_offset;
        const positions_differ = @abs(x_offset_diff) > 0 or @abs(y_offset_diff) > 0;
        const y_offset_differs = run_offset.y != 0;
        const cluster = self.codepoints.items[index].cluster;
        const cluster_differs = cluster != cell_offset.cluster;

        // To debug every loop, flip this to true:
        const extra_debugging = false;

        const is_previous_codepoint_prepend = if (cluster_differs or
            extra_debugging)
        blk: {
            var i = index;
            while (i > 0) {
                i -= 1;
                const codepoint = self.codepoints.items[i];
                break :blk unicode.table.get(@intCast(codepoint.codepoint)).grapheme_boundary_class == .prepend;
            }
            break :blk false;
        } else false;

        const formatted_cps: ?[]u8 = if (positions_differ or
            y_offset_differs or
            cluster_differs or
            extra_debugging)
        blk: {
            var allocating = std.Io.Writer.Allocating.init(self.alloc);
            defer allocating.deinit();
            const writer = &allocating.writer;
            const codepoints = self.codepoints.items;
            var last_cluster: ?u32 = null;
            for (codepoints, 0..) |cp, i| {
                if (@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1)
                {
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
                if (@as(i32, @intCast(cp.cluster)) >= @as(i32, @intCast(cell_offset.cluster)) - 1 and
                    cp.cluster <= cluster + 1)
                {
                    try writer.print("{u}", .{@as(u21, @intCast(cp.codepoint))});
                }
            }
            break :blk try allocating.toOwnedSlice();
        } else null;
        defer if (formatted_cps) |cps| self.alloc.free(cps);

        if (extra_debugging) {
            log.warn("extra debugging of positions index={d} cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} is_prev_prepend={} cps = {s}", .{
                index,
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                is_previous_codepoint_prepend,
                formatted_cps.?,
            });
        }

        if (positions_differ) {
            log.warn("position differs from advance: cluster={d} pos=({d},{d}) adv=({d},{d}) diff=({d},{d}) cps = {s}", .{
                cluster,
                x_offset,
                y_offset,
                advance_x_offset,
                advance_y_offset,
                x_offset_diff,
                y_offset_diff,
                formatted_cps.?,
            });
        }

        if (y_offset_differs) {
            log.warn("run_offset.y differs from zero: cluster={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} cps = {s}", .{
                cluster,
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                formatted_cps.?,
            });
        }

        if (cluster_differs) {
            log.warn("cell_offset.cluster differs from cluster (potential ligature detected) cell_offset.cluster={d} cluster={d} run_offset.cluster={d} diff={d} pos=({d},{d}) run_offset=({d},{d}) cell_offset.x={d} is_prev_prepend={} cps = {s}", .{
                cell_offset.cluster,
                cluster,
                run_offset.cluster,
                @as(isize, @intCast(cluster)) - @as(isize, @intCast(cell_offset.cluster)),
                x_offset,
                y_offset,
                run_offset.x,
                run_offset.y,
                cell_offset.x,
                is_previous_codepoint_prepend,
                formatted_cps.?,
            });
        }
    }
};
