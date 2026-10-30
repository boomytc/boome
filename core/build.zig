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
}
