//! LLVM ar preserves Zig's unaligned Mach-O objects that Xcode 27 libtool drops.
const std = @import("std");
const StaticArchive = @This();

step: *std.Build.Step,
output: std.Build.LazyPath,

pub fn create(b: *std.Build, sources: []const std.Build.LazyPath) StaticArchive {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg(b.path("src/build/combine_archives.py"));
    run.addArg(b.graph.zig_exe);
    const output = run.addOutputFileArg("libghostty.a");
    for (sources) |source| run.addFileArg(source);
    return .{ .step = &run.step, .output = output };
}
