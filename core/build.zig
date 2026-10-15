const std = @import("std");
const Config = @import("src/build/Config.zig");
const SharedDeps = @import("src/build/SharedDeps.zig");
const GhosttyLib = @import("src/build/GhosttyLib.zig");
const GhosttyResources = @import("src/build/GhosttyResources.zig");

comptime {
    const expected = @import("build.zig.zon").minimum_zig_version;
    if (!std.mem.eql(u8, @import("builtin").zig_version_string, expected)) {
        @compileError("Boome's terminal core requires Zig " ++ expected);
    }
}

pub fn build(b: *std.Build) !void {
    const config = try Config.init(b, @import("build.zig.zon").version);
    const deps = try SharedDeps.init(b, &config);
    const lib = try GhosttyLib.initStatic(b, &deps);
    lib.install("libghostty.a");
    lib.installHeader();
    b.installFile("include/module.modulemap", "include/module.modulemap");
    const resources = try GhosttyResources.init(b, &config, &deps);
    resources.install();

    const tests = b.addTest(.{
        .name = "boome-core-test",
        .filters = b.option([][]const u8, "test-filter", "Filter core Zig tests") orelse &.{},
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = config.baselineTarget(),
            .optimize = .Debug,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
        .use_llvm = true,
    });
    _ = try deps.add(tests);
    const header = b.addTranslateC(.{
        .root_source_file = b.path("include/ghostty.h"),
        .target = config.baselineTarget(),
        .optimize = .Debug,
    });
    tests.root_module.addImport("ghostty.h", header.createModule());
    if (config.emit_test_exe) b.installArtifact(tests);
    const run = b.addRunArtifact(tests);
    b.step("test", "Run terminal-core tests").dependOn(&run.step);
}
