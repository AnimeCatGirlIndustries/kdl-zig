const std = @import("std");
const Tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // KDL module - the core library
    const kdl_module = b.addModule("kdl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Executable for CLI usage (optional)
    const exe = b.addExecutable(.{
        .name = "kdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kdl", .module = kdl_module },
            },
        }),
    });

    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Tests
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests that do not match any filter",
    ) orelse &[0][]const u8{};

    const tests = Tests.register(b, .{
        .target = target,
        .optimize = optimize,
        .modules = .{ .kdl = kdl_module },
        .test_filters = test_filters,
    }) catch |err| {
        std.debug.print("Failed to register tests: {}\n", .{err});
        return;
    };

    const test_step = b.step("test", "Run all tests");
    for (tests.all) |step| test_step.dependOn(step);

    const unit_test_step = b.step("test-unit", "Run unit tests only");
    for (tests.unit) |step| unit_test_step.dependOn(step);

    const integration_test_step = b.step("test-integration", "Run integration tests only");
    for (tests.integration) |step| integration_test_step.dependOn(step);
}
