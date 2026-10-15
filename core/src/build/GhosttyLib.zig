//! Boome's embedded terminal library, with an exact list of bundled archives.
const GhosttyLib = @This();
const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");
const StaticArchive = @import("StaticArchive.zig");

step: *std.Build.Step,
output: std.Build.LazyPath,

pub fn initStatic(b: *std.Build, deps: *const SharedDeps) !GhosttyLib {
    const lib = b.addLibrary(.{
        .name = "ghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.strip,
            .unwind_tables = if (deps.config.strip) .none else .sync,
        }),
        .use_llvm = true,
    });
    lib.linkLibC();
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;
    var archives = try deps.add(lib);
    try archives.append(b.allocator, lib.getEmittedBin());
    const combined = StaticArchive.create(b, archives.items);
    return .{ .step = combined.step, .output = combined.output };
}

pub fn install(self: *const GhosttyLib, name: []const u8) void {
    const b = self.step.owner;
    b.getInstallStep().dependOn(&b.addInstallLibFile(self.output, name).step);
}

pub fn installHeader(self: *const GhosttyLib) void {
    const b = self.step.owner;
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(b.path("include/ghostty.h"), "ghostty.h").step);
}
