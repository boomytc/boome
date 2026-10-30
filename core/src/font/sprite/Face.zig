//! This implements the built-in "sprite face". This font renders
//! the built-in glyphs for the terminal, such as box drawing fonts, as well
//! as specific sprites that are part of our rendering model such as
//! text decorations (underlines).
//!
//! This isn't really a "font face" so much as it is quacks like a font
//! face with regards to how it works with font.Group. We don't use any
//! dynamic dispatch so it isn't truly an interface but the functions
//! and behaviors are close enough to a system face that it makes it easy
//! to integrate with font.Group. This is desirable so that higher level
//! processes such as GroupCache, Shaper, etc. don't need to be aware of
//! special sprite handling and just treat it like a normal font face.
const Face = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const font = @import("../main.zig");
const Sprite = font.sprite.Sprite;

const special = @import("draw/special.zig");

const log = std.log.scoped(.font_sprite);

/// Grid metrics for rendering sprites.
metrics: font.Metrics,

pub const DrawFnError =
    Allocator.Error ||
    z2d.Path.Error ||
    z2d.painter.FillError ||
    z2d.painter.StrokeError ||
    error{
        /// Something went wrong while doing math.
        MathError,
    };

/// A function that draws a glyph on the provided canvas.
pub const DrawFn = fn (
    cp: u32,
    canvas: *font.sprite.Canvas,
    width: u32,
    height: u32,
    metrics: font.Metrics,
) DrawFnError!void;

const Range = struct {
    min: u32,
    max: u32,
    draw: DrawFn,
};

/// Automatically collect ranges for functions with names
/// in the format `draw<CP>` or `draw<MIN>_<MAX>`.
const ranges: []const Range = ranges: {
    @setEvalBranchQuota(1_000_000);

    // Structs containing drawing functions for codepoint ranges.
    const structs = [_]type{
        @import("draw/block.zig"),
        @import("draw/box.zig"),
        @import("draw/braille.zig"),
        @import("draw/branch.zig"),
        @import("draw/geometric_shapes.zig"),
        @import("draw/powerline.zig"),
        @import("draw/symbols_for_legacy_computing.zig"),
        @import("draw/symbols_for_legacy_computing_supplement.zig"),
    };

    // Count how many draw fns we have
    var range_count = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (!@hasDecl(s, decl.name)) continue;
            if (!std.mem.startsWith(u8, decl.name, "draw")) continue;
            range_count += 1;
        }
    }

    // Make an array and collect ranges for each function.
    var r: [range_count]Range = undefined;
    var names: [range_count][:0]const u8 = undefined;
    var i = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (!@hasDecl(s, decl.name)) continue;
            if (!std.mem.startsWith(u8, decl.name, "draw")) continue;

            const sep = std.mem.indexOfScalar(u8, decl.name, '_') orelse decl.name.len;

            const min = std.fmt.parseInt(u21, decl.name[4..sep], 16) catch unreachable;

            const max = if (sep == decl.name.len)
                min
            else
                std.fmt.parseInt(u21, decl.name[sep + 1 ..], 16) catch unreachable;

            r[i] = .{
                .min = min,
                .max = max,
                .draw = @field(s, decl.name),
            };
            names[i] = decl.name;
            i += 1;
        }
    }

    // Sort ranges in ascending order
    std.mem.sortUnstableContext(0, r.len, struct {
        r: []Range,
        names: [][:0]const u8,
        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            return self.r[a].min < self.r[b].min;
        }
        pub fn swap(self: @This(), a: usize, b: usize) void {
            std.mem.swap(Range, &self.r[a], &self.r[b]);
            std.mem.swap([:0]const u8, &self.names[a], &self.names[b]);
        }
    }{
        .r = &r,
        .names = &names,
    });

    // Ensure there's no overlapping ranges
    i = 0;
    for (r, 0..) |n, k| {
        if (n.min <= i) {
            @compileError(
                std.fmt.comptimePrint(
                    "Codepoint range for {s}(...) overlaps range for {s}(...), {X} <= {X} <= {X}",
                    .{ names[k], names[k - 1], r[k - 1].min, n.min, r[k - 1].max },
                ),
            );
        }
        i = n.max;
    }

    // We need to copy in to a const rather than a var in order to take
    // the reference at comptime so that we can break with a slice here.
    const fixed = r;

    break :ranges &fixed;
};

fn getDrawFn(cp: u32) ?*const DrawFn {
    // For special sprites (cursors, underlines, etc.) all sprites are drawn
    // by functions from `Special` that share the name of the enum field.
    if (cp >= Sprite.start) switch (@as(Sprite, @enumFromInt(cp))) {
        inline else => |sprite| {
            return @field(special, @tagName(sprite));
        },
    };

    // Pray that the compiler is smart enough to
    // turn this in to a jump table or something...
    inline for (ranges) |range| {
        if (cp >= range.min and cp <= range.max) return range.draw;
    }
    return null;
}

/// Returns true if the codepoint exists in our sprite font.
pub fn hasCodepoint(self: Face, cp: u32, p: ?font.Presentation) bool {
    // We ignore presentation. No matter what presentation is
    // requested we always provide glyphs for our codepoints.
    _ = p;
    _ = self;
    return getDrawFn(cp) != null;
}

/// Render the glyph.
pub fn renderGlyph(
    self: Face,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
    opts: font.face.RenderOptions,
) !font.Glyph {
    if (std.debug.runtime_safety) {
        if (!self.hasCodepoint(cp, null)) {
            log.err("invalid codepoint cp={x}", .{cp});
            unreachable; // crash
        }
    }

    // It should be impossible for this to be null and we assert that
    // in runtime safety modes but in case it is its not worth memory
    // corruption so we return a valid, blank glyph.
    const draw = getDrawFn(cp) orelse return .{
        .width = 0,
        .height = 0,
        .offset_x = 0,
        .offset_y = 0,
        .atlas_x = 0,
        .atlas_y = 0,
    };

    const metrics = self.metrics;

    // We adjust our sprite width based on the cell width.
    const width = switch (opts.cell_width orelse 1) {
        0, 1 => metrics.cell_width,
        else => |width| metrics.cell_width * width,
    };

    const height = metrics.cell_height;

    const padding_x = width / 4;
    const padding_y = height / 4;

    // Make a canvas of the desired size
    var canvas = try font.sprite.Canvas.init(alloc, width, height, padding_x, padding_y);
    defer canvas.deinit();

    try draw(cp, &canvas, width, height, metrics);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    return .{
        .width = region.width,
        .height = region.height,
        .offset_x = @as(i32, @intCast(canvas.clip_left)) - @as(i32, @intCast(padding_x)),
        .offset_y = @as(i32, @intCast(region.height +| canvas.clip_bottom)) - @as(i32, @intCast(padding_y)),
        .atlas_x = region.x,
        .atlas_y = region.y,
    };
}
