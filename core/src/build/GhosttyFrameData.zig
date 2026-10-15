//! Compressed animation data referenced by the shared CLI initialization.
const GhosttyFrameData = @This();
const std = @import("std");

output: std.Build.LazyPath,

pub fn init(b: *std.Build) !GhosttyFrameData {
    const exe = b.addExecutable(.{
        .name = "framegen",
        .root_module = b.createModule(.{
            .target = b.graph.host,
        }),
    });
    exe.addCSourceFile(.{
        .file = b.path("src/build/framegen/main.c"),
        .flags = &.{},
    });
    exe.linkLibC();

    if (b.systemIntegrationOption("zlib", .{})) {
        exe.linkSystemLibrary2("zlib", .{
            .preferred_link_mode = .dynamic,
            .search_strategy = .mode_first,
        });
    } else {
        if (b.lazyDependency("zlib", .{
            .target = b.graph.host,
            .optimize = .ReleaseFast,
        })) |zlib_dep| {
            exe.linkLibrary(zlib_dep.artifact("z"));
        }
    }

    const run = b.addRunArtifact(exe);
    run.addDirectoryArg(b.path("src/build/framegen/frames"));
    const compressed_file = run.addOutputFileArg("framedata.compressed");

    const wf = b.addWriteFiles();
    _ = wf.addCopyFile(compressed_file, "framedata.compressed");
    const output = wf.add("framedata.zig",
        \\//! Generated from the checked-in frame sources.
        \\pub const compressed = @embedFile("framedata.compressed");
        \\
    );
    return .{ .output = output };
}

pub fn addImport(self: *const GhosttyFrameData, step: *std.Build.Step.Compile) void {
    self.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("framedata", .{ .root_source_file = self.output });
}
