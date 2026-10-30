const std = @import("std");

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const lib = b.addLibrary(.{
        .name = "simdutf",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    lib.addIncludePath(b.path("vendor"));

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    if (target.result.abi.isAndroid()) {
        const android_ndk = @import("android_ndk");
        try android_ndk.addPaths(b, lib);
    }

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
    // (See root Ghostty build.zig on why we do this)
    try flags.appendSlice(b.allocator, &.{
        "-DSIMDUTF_IMPLEMENTATION_ICELAKE=0",

        // Fixes linker issues for release builds missing ubsanitizer symbols
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    if (target.result.os.tag == .freebsd or target.result.abi == .musl) {
        try flags.append(b.allocator, "-fPIC");
    }

    lib.addCSourceFiles(.{
        .flags = flags.items,
        .files = &.{
            "vendor/simdutf.cpp",
        },
    });
    lib.installHeadersDirectory(
        b.path("vendor"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);
}
