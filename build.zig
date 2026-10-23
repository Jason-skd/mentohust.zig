const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = packageVersion(b);

    const rj_connect = b.dependency("rj_connect", .{
        .target = target,
        .optimize = optimize,
    });
    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version);

    const mod = b.addModule("mentohust", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "rj-connect", .module = rj_connect.module("rj-connect") },
            .{ .name = "clap", .module = clap.module("clap") },
        },
    });

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe = b.addExecutable(.{
        .name = "mentohust",
        .version = std.SemanticVersion.parse(version) catch @panic("invalid package version"),
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mentohust", .module = mod },
                .{ .name = "clap", .module = clap.module("clap") },
                .{ .name = "build_options", .module = build_options.createModule() },
            },
        }),
    });
    b.installArtifact(exe);

    const check_step = b.step("check", "Compile application modules");
    check_step.dependOn(&mod_tests.step);
    check_step.dependOn(&exe.step);
    b.default_step.dependOn(check_step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const run_step = b.step("run", "Run the authentication client");
    const run_exe = b.addRunArtifact(exe);
    run_step.dependOn(&run_exe.step);
}

fn packageVersion(b: *std.Build) []const u8 {
    const manifest_path = b.path("build.zig.zon");
    b.dependOnFileContents(manifest_path);
    const source = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .limited(1 << 20),
    ) catch @panic("failed to read build.zig.zon");

    var arena_state: std.heap.ArenaAllocator = .init(b.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(
        struct { version: []const u8 },
        .{
            .gpa = b.allocator,
            .arena = arena,
            .source = arena.dupeSentinel(u8, source, 0) catch @panic("failed to copy build.zig.zon"),
            .diagnostics = &diagnostics,
            .ignore_unknown_fields = true,
        },
    ) catch @panic("failed to parse build.zig.zon");
    return b.graph.dupeString(manifest.version);
}
