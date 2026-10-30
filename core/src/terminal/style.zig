const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const configpkg = @import("../config.zig");
const color = @import("color.zig");
const sgr = @import("sgr.zig");
const page = @import("page.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const RefCountedSet = @import("ref_counted_set.zig").RefCountedSet;

/// The unique identifier for a style. This is at most the number of cells
/// that can fit into a terminal page.
pub const Id = size.StyleCountInt;

/// The Id to use for default styling.
pub const default_id: Id = 0;

/// The style attributes for a cell.
pub const Style = struct {
    /// Various colors, all self-explanatory.
    fg_color: Color = .none,
    bg_color: Color = .none,
    underline_color: Color = .none,

    /// On/off attributes that don't require much bit width so we use
    /// a packed struct to make this take up significantly less space.
    flags: Flags = .{},

    const Flags = packed struct(u16) {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        overline: bool = false,
        underline: sgr.Attribute.Underline = .none,
        _padding: u5 = 0,
    };

    /// The color for an SGR attribute. A color can come from multiple
    /// sources so we use this to track the source plus color value so that
    /// we can properly react to things like palette changes.
    pub const Color = union(Tag) {
        none: void,
        palette: u8,
        rgb: color.RGB,

        const Tag = enum(u8) {
            none,
            palette,
            rgb,
        };

        /// True if the color is equal to another color.
        pub fn eql(self: Color, other: Color) bool {
            return @as(Tag, self) == @as(Tag, other) and switch (self) {
                .none => true,
                .palette => self.palette == other.palette,
                .rgb => self.rgb == other.rgb,
            };
        }

        /// Formatting to make debug logs easier to read
        /// by only including non-default attributes.
        pub fn format(
            self: Color,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: *std.Io.Writer,
        ) !void {
            _ = fmt;
            _ = options;
            switch (self) {
                .none => {
                    _ = try writer.write("Color.none");
                },
                .palette => |p| {
                    _ = try writer.print("Color.palette{{ {} }}", .{p});
                },
                .rgb => |rgb| {
                    _ = try writer.print("Color.rgb{{ {}, {}, {} }}", .{ rgb.r, rgb.g, rgb.b });
                },
            }
        }
    };

    /// True if the style is the default style.
    pub inline fn default(self: Style) bool {
        return self.eql(.{});
    }

    /// True if the style is equal to another style.
    pub fn eql(self: Style, other: Style) bool {
        return self.flags == other.flags and
            self.fg_color.eql(other.fg_color) and
            self.bg_color.eql(other.bg_color) and
            self.underline_color.eql(other.underline_color);
    }

    /// Returns the bg color for a cell with this style given the cell
    /// that has this style and the palette to use.
    ///
    /// Note that generally if a cell is a color-only cell, it SHOULD
    /// only have the default style, but this is meant to work with the
    /// default style as well.
    pub fn bg(
        self: Style,
        cell: *const page.Cell,
        palette: *const color.Palette,
    ) ?color.RGB {
        return switch (cell.content_tag) {
            .bg_color_palette => palette[cell.content.color_palette],
            .bg_color_rgb => rgb: {
                const rgb = cell.content.color_rgb;
                break :rgb .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
            },

            else => switch (self.bg_color) {
                .none => null,
                .palette => |idx| palette[idx],
                .rgb => |rgb| rgb,
            },
        };
    }

    pub const Fg = struct {
        /// The default color to use if the style doesn't specify a
        /// foreground color and no configuration options override
        /// it.
        default: color.RGB,

        /// The current color palette. Required to map palette indices to
        /// real color values.
        palette: *const color.Palette,

        /// If specified, the color to use for bold text.
        bold: ?configpkg.BoldColor = null,
    };

    /// Returns the fg color for a cell with this style given the palette
    /// and various configuration options.
    pub fn fg(
        self: Style,
        opts: Fg,
    ) color.RGB {
        // Note we don't pull the bold check to the top-level here because
        // we don't want to duplicate the conditional multiple times since
        // certain colors require more checks (e.g. `bold_is_bright`).

        return switch (self.fg_color) {
            .none => default: {
                if (self.flags.bold) {
                    if (opts.bold) |bold| switch (bold) {
                        .bright => {},
                        .color => |v| break :default v.toTerminalRGB(),
                    };
                }

                break :default opts.default;
            },

            .palette => |idx| palette: {
                if (self.flags.bold) {
                    if (opts.bold) |_| {
                        const bright_offset = @intFromEnum(color.Name.bright_black);
                        if (idx < bright_offset) {
                            break :palette opts.palette[idx + bright_offset];
                        }
                    }
                }

                break :palette opts.palette[idx];
            },

            .rgb => |rgb| rgb: {
                if (self.flags.bold and rgb.eql(opts.default)) {
                    if (opts.bold) |bold| switch (bold) {
                        .color => |v| break :rgb v.toTerminalRGB(),
                        .bright => {},
                    };
                }

                break :rgb rgb;
            },
        };
    }

    /// Returns the underline color for this style.
    pub fn underlineColor(
        self: Style,
        palette: *const color.Palette,
    ) ?color.RGB {
        return switch (self.underline_color) {
            .none => null,
            .palette => |idx| palette[idx],
            .rgb => |rgb| rgb,
        };
    }

    /// Returns a bg-color only cell from this style, if it exists.
    pub fn bgCell(self: Style) ?page.Cell {
        return switch (self.bg_color) {
            .none => null,
            .palette => |idx| .{
                .content_tag = .bg_color_palette,
                .content = .{ .color_palette = idx },
            },
            .rgb => |rgb| .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                } },
            },
        };
    }

    /// Formatting to make debug logs easier to read
    /// by only including non-default attributes.
    pub fn format(
        self: Style,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        _ = fmt;
        _ = options;

        const dflt: Style = .{};

        _ = try writer.write("Style{ ");

        var started = false;

        inline for (std.meta.fields(Style)) |f| {
            if (std.mem.eql(u8, f.name, "flags")) {
                if (started) {
                    _ = try writer.write(", ");
                }

                _ = try writer.write("flags={ ");

                started = false;

                inline for (std.meta.fields(@TypeOf(self.flags))) |ff| {
                    const v = @as(ff.type, @field(self.flags, ff.name));
                    const d = @as(ff.type, @field(dflt.flags, ff.name));
                    if (ff.type == bool) {
                        if (v) {
                            if (started) {
                                _ = try writer.write(", ");
                            }
                            _ = try writer.print("{s}", .{ff.name});
                            started = true;
                        }
                    } else if (!std.meta.eql(v, d)) {
                        if (started) {
                            _ = try writer.write(", ");
                        }
                        _ = try writer.print(
                            "{s}={any}",
                            .{ ff.name, v },
                        );
                        started = true;
                    }
                }
                _ = try writer.write(" }");

                started = true;
                comptime continue;
            }
            const value = @as(f.type, @field(self, f.name));
            const d_val = @as(f.type, @field(dflt, f.name));
            if (!std.meta.eql(value, d_val)) {
                if (started) {
                    _ = try writer.write(", ");
                }
                _ = try writer.print(
                    "{s}={any}",
                    .{ f.name, value },
                );
                started = true;
            }
        }

        _ = try writer.write(" }");
    }

    /// Returns a formatter that renders this style as VT sequences,
    /// to be used with `{f}`. This always resets the style first `\x1b[0m`
    /// since a style is meant to be fully self-contained.
    ///
    /// For individual styles, this always emits multiple SGR sequences
    /// (i.e. an individual `\x1b[<stuff>m` for each attribute) rather than
    /// trying to combine them into a single sequence. We do this because
    /// terminals have varying levels of support for combined sequences
    /// especially with mixed separators (e.g. `:` vs `;`).
    pub fn formatterVt(self: *const Style) VTFormatter {
        return .{ .style = self };
    }

    /// Returns a formatter that renders this style as inline CSS properties,
    /// to be used with `{f}`. The output is a valid CSS style string suitable
    /// for use in a `style` attribute (e.g., "color: rgb(255, 0, 0); font-weight: bold;").
    ///
    /// Palette colors are emitted as CSS variables like `var(--vt-palette-N)`.
    pub fn formatterHtml(self: *const Style) HtmlFormatter {
        return .{ .style = self };
    }

    const VTFormatter = struct {
        style: *const Style,

        /// If set, palette colors will be emitted as RGB values instead of
        /// palette indices. This is useful when you want to capture the
        /// exact colors at formatting time rather than relying on the
        /// terminal's palette.
        palette: ?*const color.Palette = null,

        pub fn format(
            self: VTFormatter,
            writer: *std.Io.Writer,
        ) !void {
            // Always reset the style. Styles are fully self-contained.
            // Even if this style is empty, then that means we want to go
            // back to the default.
            try writer.writeAll("\x1b[0m");

            // Our flags
            if (self.style.flags.bold) try writer.writeAll("\x1b[1m");
            if (self.style.flags.faint) try writer.writeAll("\x1b[2m");
            if (self.style.flags.italic) try writer.writeAll("\x1b[3m");
            if (self.style.flags.blink) try writer.writeAll("\x1b[5m");
            if (self.style.flags.inverse) try writer.writeAll("\x1b[7m");
            if (self.style.flags.invisible) try writer.writeAll("\x1b[8m");
            if (self.style.flags.strikethrough) try writer.writeAll("\x1b[9m");
            if (self.style.flags.overline) try writer.writeAll("\x1b[53m");
            switch (self.style.flags.underline) {
                .none => {},
                .single => try writer.writeAll("\x1b[4m"),
                .double => try writer.writeAll("\x1b[4:2m"),
                .curly => try writer.writeAll("\x1b[4:3m"),
                .dotted => try writer.writeAll("\x1b[4:4m"),
                .dashed => try writer.writeAll("\x1b[4:5m"),
            }

            // Various RGB colors.
            try self.formatColor(writer, 38, self.style.fg_color);
            try self.formatColor(writer, 48, self.style.bg_color);
            try self.formatColor(writer, 58, self.style.underline_color);
        }

        fn formatColor(
            self: VTFormatter,
            writer: *std.Io.Writer,
            prefix: u8,
            value: Color,
        ) !void {
            switch (value) {
                .none => {},
                .palette => |idx| {
                    if (self.palette) |p| {
                        const rgb = p[idx];
                        try writer.print(
                            "\x1b[{d};2;{d};{d};{d}m",
                            .{ prefix, rgb.r, rgb.g, rgb.b },
                        );
                    } else {
                        try writer.print(
                            "\x1b[{d};5;{d}m",
                            .{ prefix, idx },
                        );
                    }
                },
                .rgb => |rgb| try writer.print(
                    "\x1b[{d};2;{d};{d};{d}m",
                    .{ prefix, rgb.r, rgb.g, rgb.b },
                ),
            }
        }
    };

    const HtmlFormatter = struct {
        style: *const Style,

        /// If set, palette colors will be emitted as RGB values instead of
        /// CSS variables. This is useful when you want to capture the exact
        /// colors at formatting time rather than relying on CSS variables.
        palette: ?*const color.Palette = null,

        pub fn format(
            self: HtmlFormatter,
            writer: *std.Io.Writer,
        ) !void {
            // Colors
            try self.formatColor(writer, "color", self.style.fg_color);
            try self.formatColor(writer, "background-color", self.style.bg_color);
            try self.formatColor(writer, "text-decoration-color", self.style.underline_color);

            // Text decoration line
            const has_line = self.style.flags.underline != .none or
                self.style.flags.strikethrough or
                self.style.flags.overline or
                self.style.flags.blink;
            if (has_line) {
                try writer.writeAll("text-decoration-line:");
                if (self.style.flags.underline != .none) try writer.writeAll(" underline");
                if (self.style.flags.strikethrough) try writer.writeAll(" line-through");
                if (self.style.flags.overline) try writer.writeAll(" overline");
                if (self.style.flags.blink) try writer.writeAll(" blink");
                try writer.writeAll(";");
            }

            // Text decoration style
            switch (self.style.flags.underline) {
                .none => {},
                .single => try writer.writeAll("text-decoration-style: solid;"),
                .double => try writer.writeAll("text-decoration-style: double;"),
                .curly => try writer.writeAll("text-decoration-style: wavy;"),
                .dotted => try writer.writeAll("text-decoration-style: dotted;"),
                .dashed => try writer.writeAll("text-decoration-style: dashed;"),
            }

            if (self.style.flags.bold) try writer.writeAll("font-weight: bold;");
            if (self.style.flags.italic) try writer.writeAll("font-style: italic;");
            if (self.style.flags.faint) try writer.writeAll("opacity: 0.5;");
            if (self.style.flags.invisible) try writer.writeAll("visibility: hidden;");
            if (self.style.flags.inverse) try writer.writeAll("filter: invert(100%);");
        }

        fn formatColor(
            self: HtmlFormatter,
            writer: *std.Io.Writer,
            property: []const u8,
            c: Color,
        ) !void {
            switch (c) {
                .none => {},
                .palette => |idx| {
                    if (self.palette) |p| {
                        const rgb = p[idx];
                        try writer.print("{s}: rgb({d}, {d}, {d});", .{ property, rgb.r, rgb.g, rgb.b });
                    } else {
                        try writer.print("{s}: var(--vt-palette-{d});", .{ property, idx });
                    }
                },
                .rgb => |rgb| try writer.print("{s}: rgb({d}, {d}, {d});", .{ property, rgb.r, rgb.g, rgb.b }),
            }
        }
    };

    /// `PackedStyle` represents the same data as `Style` but without padding,
    /// which is necessary for hashing via re-interpretation of the underlying
    /// bytes.
    ///
    /// `Style` is still preferred for everything else as it has type-safety
    /// when using the `Color` tagged union.
    ///
    /// Empirical testing shows that storing all of the tags first and then the
    /// data provides a better layout for serializing into and is faster on
    /// benchmarks.
    const PackedStyle = packed struct(u128) {
        tags: packed struct {
            fg: Color.Tag,
            bg: Color.Tag,
            underline: Color.Tag,
        },
        data: packed struct {
            fg: Data,
            bg: Data,
            underline: Data,
        },
        flags: Flags,
        _padding: u16 = 0,

        /// After https://github.com/ziglang/zig/issues/19754 is implemented,
        /// it will be an compiler-error to have packed union fields of
        /// differing size.
        ///
        /// For now we just need to be careful not to accidentally introduce
        /// padding.
        const Data = packed union {
            none: u24,
            palette: packed struct(u24) {
                idx: u8,
                _padding: u16 = 0,
            },
            rgb: color.RGB,

            fn fromColor(c: Color) Data {
                return switch (c) {
                    inline else => |v, t| @unionInit(
                        Data,
                        @tagName(t),
                        switch (t) {
                            .none => 0,
                            .palette => .{ .idx = v },
                            .rgb => v,
                        },
                    ),
                };
            }
        };

        inline fn fromStyle(style: Style) PackedStyle {
            return .{
                .tags = .{
                    .fg = @as(Color.Tag, style.fg_color),
                    .bg = @as(Color.Tag, style.bg_color),
                    .underline = @as(Color.Tag, style.underline_color),
                },
                .data = .{
                    .fg = .fromColor(style.fg_color),
                    .bg = .fromColor(style.bg_color),
                    .underline = .fromColor(style.underline_color),
                },
                .flags = style.flags,
            };
        }
    };

    pub fn hash(self: *const Style) u64 {
        // We pack the style in to 128 bits, fold it to 64 bits,
        // then use std.hash.int to make it sufficiently uniform.
        const packed_style: PackedStyle = .fromStyle(self.*);
        const wide: [2]u64 = @bitCast(packed_style);
        return @call(.always_inline, std.hash.int, .{wide[0] ^ wide[1]});
    }

    comptime {
        assert(@sizeOf(PackedStyle) == 16);
        assert(std.meta.hasUniqueRepresentation(PackedStyle));
        for (@typeInfo(PackedStyle.Data).@"union".fields) |field| {
            assert(@bitSizeOf(field.type) == @bitSizeOf(PackedStyle.Data));
        }
    }
};

pub const Set = RefCountedSet(
    Style,
    Id,
    size.CellCountInt,
    struct {
        pub fn hash(self: *const @This(), style: Style) u64 {
            _ = self;
            return style.hash();
        }

        pub fn eql(self: *const @This(), a: Style, b: Style) bool {
            _ = self;
            return a.eql(b);
        }
    },
);
