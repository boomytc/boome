/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");

const ApprtRuntime = @import("../apprt/runtime.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const WasmTarget = @import("../os/wasm/target.zig").Target;

/// Standard build configuration options.
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
wasm_target: WasmTarget,

/// Comptime interfaces
app_runtime: ApprtRuntime = .none,
renderer: RendererBackend = .opengl,
font_backend: FontBackend = .freetype,

/// Feature flags
x11: bool = false,
wayland: bool = false,
sentry: bool = true,
simd: bool = true,
i18n: bool = true,
wasm_shared: bool = true,

/// Ghostty exe properties
exe_entrypoint: ExeEntrypoint = .ghostty,
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },

/// Binary properties
pie: bool = false,
strip: bool = false,
patch_rpath: ?[]const u8 = null,

/// Artifacts
flatpak: bool = false,
snap: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_themes: bool = false,
emit_unicode_table_gen: bool = false,

/// Environmental properties
env: std.process.EnvMap,

/// Boome builds only the embedded macOS arm64 core, never an upstream app.
pub fn init(b: *std.Build, appVersion: []const u8) !Config {
    const optimize = b.standardOptimizeOption(.{});
    const requested = b.standardTargetOptions(.{});
    if (builtin.target.os.tag != .macos or requested.result.os.tag != .macos or
        requested.result.cpu.arch != .aarch64)
    {
        std.log.err("Boome's terminal core requires a macOS arm64 host and target", .{});
        return error.UnsupportedTarget;
    }
    const target = genericMacOSTarget(b, .aarch64);
    var config: Config = .{
        .optimize = optimize,
        .target = target,
        .wasm_target = .browser,
        .env = try std.process.getEnvMap(b.allocator),
        .app_runtime = .none,
        .font_backend = .coretext,
        .renderer = .metal,
        // Do not infer the library version from Boome's unrelated Git tags.
        .version = try std.SemanticVersion.parse(appVersion),
        .sentry = b.option(bool, "sentry", "Enable the existing crash reporter") orelse true,
        .simd = b.option(bool, "simd", "Enable SIMD acceleration") orelse true,
        .i18n = b.option(bool, "i18n", "Install existing core translations") orelse true,
        .strip = switch (optimize) {
            .Debug, .ReleaseSafe => false,
            .ReleaseFast, .ReleaseSmall => true,
        },
        .emit_themes = true,
        .emit_terminfo = optimize == .Debug,
        .emit_termcap = optimize == .Debug,
    };
    config.emit_test_exe = b.option(bool, "emit-test-exe", "Install the core test executable") orelse false;
    for ([_][]const u8{
        "freetype", "libpng", "zlib", "oniguruma", "glslang", "spirv-cross", "simdutf",
    }) |dep| {
        _ = b.systemIntegrationOption(dep, .{ .default = false });
    }
    return config;
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "flatpak", self.flatpak);
    step.addOption(bool, "snap", self.snap);
    step.addOption(bool, "x11", self.x11);
    step.addOption(bool, "wayland", self.wayland);
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(bool, "simd", self.simd);
    step.addOption(bool, "i18n", self.i18n);
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
    step.addOption(WasmTarget, "wasm_target", self.wasm_target);
    step.addOption(bool, "wasm_shared", self.wasm_shared);

    // Our version. We also add the string version so we don't need
    // to do any allocations at runtime. This has to be long enough to
    // accommodate realistic large branch names for dev versions.
    var buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(
        &buf,
        "{f}",
        .{self.version},
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}

/// Returns the build options for the terminal module. This assumes a
/// Ghostty executable being built. Callers should modify this as needed.
pub fn terminalOptions(self: *const Config) TerminalBuildOptions {
    return .{
        .artifact = .ghostty,
        .simd = self.simd,
        .oniguruma = true,
        .c_abi = false,
        .slow_runtime_safety = switch (self.optimize) {
            .Debug => true,
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => false,
        },
    };
}

/// Returns a baseline CPU target retaining all the other CPU configs.
pub fn baselineTarget(self: *const Config) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(q) catch
            @panic("unable to resolve baseline query"),
    };
}

/// Rehydrate our Config from the comptime options. Note that not all
/// options are available at comptime, so look closely at this implementation
/// to see what is and isn't available.
pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{
        // Unused at runtime.
        .optimize = undefined,
        .target = undefined,
        .env = undefined,

        .version = options.app_version,
        .flatpak = options.flatpak,
        .app_runtime = std.meta.stringToEnum(ApprtRuntime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(RendererBackend, @tagName(options.renderer)).?,
        .snap = options.snap,
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
        .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
        .wasm_shared = options.wasm_shared,
        .i18n = options.i18n,
    };
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        // We support back to the earliest officially supported version
        // of macOS by Apple. EOL versions are not supported.
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },

        // iOS 17 picked arbitrarily
        .ios => .{ .semver = .{
            .major = 17,
            .minor = 0,
            .patch = 0,
        } },

        // This should never happen currently. If we add a new target then
        // we should add a new case here.
        else => null,
    };
}

// Returns a ResolvedTarget for a mac with a `target.result.cpu.model.name` of `generic`.
// `b.standardTargetOptions()` returns a more specific cpu like `apple_a15`.
//
// This is used to workaround compilation issues on macOS.
// (see for example https://github.com/mitchellh/ghostty/issues/1640).
pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
}

/// The possible entrypoints for the exe artifact. This has no effect on
/// other artifact types (i.e. lib, wasm_module).
///
/// The whole existence of this enum is to workaround the fact that Zig
/// doesn't allow the main function to be in a file in a subdirctory
/// from the "root" of the module, and I don't want to pollute our root
/// directory with a bunch of individual zig files for each entrypoint.
///
/// Therefore, main.zig uses this to switch between the different entrypoints.
pub const ExeEntrypoint = enum {
    ghostty,
    helpgen,
    mdgen_ghostty_1,
    mdgen_ghostty_5,
    webgen_config,
    webgen_actions,
    webgen_commands,
};

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};
