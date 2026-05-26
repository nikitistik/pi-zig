const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const pi_mod = b.createModule(.{
        .root_source_file = b.path("src/pi/index.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "pi-zig", .module = pi_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "pi-zig",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run pi-zig CLI/backend");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = pi_mod });
    const test_step = b.step("test", "Run Zig runtime tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

