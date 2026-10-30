const std = @import("std");
const builtin = @import("builtin");
const apple_sdk = @import("apple_sdk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("macos", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "macos",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });

    lib.addCSourceFile(.{
        .file = b.path("os/zig_macos.c"),
        .flags = &.{"-std=c99"},
    });
    lib.addCSourceFile(.{
        .file = b.path("text/ext.c"),
    });
    lib.linkFramework("CoreFoundation");
    lib.linkFramework("CoreGraphics");
    lib.linkFramework("CoreText");
    lib.linkFramework("CoreVideo");
    lib.linkFramework("QuartzCore");
    lib.linkFramework("IOSurface");
    if (target.result.os.tag == .macos) {
        lib.linkFramework("Carbon");
        module.linkFramework("Carbon", .{});
    }

    if (target.result.os.tag.isDarwin()) {
        module.linkFramework("CoreFoundation", .{});
        module.linkFramework("CoreGraphics", .{});
        module.linkFramework("CoreText", .{});
        module.linkFramework("CoreVideo", .{});
        module.linkFramework("QuartzCore", .{});
        module.linkFramework("IOSurface", .{});

        try apple_sdk.addPaths(b, lib);
    }
    b.installArtifact(lib);
}
