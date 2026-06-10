const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk = b.dependency("zig_mcp_sdk", .{ .target = target, .optimize = optimize });
    const sqlite = b.dependency("sqlite", .{});

    const exe = addExe(b, "sqlite-mcp", "src/main.zig", sdk, sqlite, target, optimize);
    b.installArtifact(exe);

    const fixture = addExe(b, "make-fixture", "src/fixture.zig", null, sqlite, target, optimize);
    b.installArtifact(fixture);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run sqlite-mcp").dependOn(&run_cmd.step);
}

fn addExe(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    sdk: ?*std.Build.Dependency,
    sqlite: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    if (sdk) |dep| module.addImport("zig_mcp_sdk", dep.module("zig_mcp_sdk"));
    module.addCSourceFile(.{
        .file = sqlite.path("sqlite3.c"),
        .flags = &.{
            // Stdio MCP servers are single-threaded; skip mutexes.
            "-DSQLITE_THREADSAFE=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_DQS=0",
        },
    });
    module.addIncludePath(sqlite.path("."));
    return b.addExecutable(.{ .name = name, .root_module = module });
}
