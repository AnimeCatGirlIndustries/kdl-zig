const std = @import("std");
const Bench = @import("build/bench.zig");
const Fuzz = @import("build/fuzz.zig");
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

    // Example: Tokenizer Demo
    const demo_exe = b.addExecutable(.{
        .name = "tokenizer-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tokenizer_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kdl", .module = kdl_module },
            },
        }),
    });

    const example_step = b.step("example", "Run the tokenizer demo");
    const example_run = b.addRunArtifact(demo_exe);
    example_step.dependOn(&example_run.step);

    // Benchmarks
    const benchmarks = Bench.register(b, .{
        .target = target,
        .optimize = optimize,
        .modules = .{ .kdl = kdl_module },
        .args = b.args,
    }) catch |err| {
        std.debug.print("Failed to register benchmarks: {}\n", .{err});
        return;
    };

    const bench_step = b.step("bench", "Run benchmarks");
    for (benchmarks.all) |step| bench_step.dependOn(step);

    inline for (Bench.specs, 0..) |spec, i| {
        const step = b.step("bench-" ++ spec.name, spec.description);
        step.dependOn(benchmarks.all[i]);
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

    // Fuzzing
    const fuzz = Fuzz.register(b, .{
        .target = target,
        .optimize = optimize,
        .modules = .{ .kdl = kdl_module },
        .args = b.args,
    }) catch |err| {
        std.debug.print("Failed to register fuzz tests: {}\n", .{err});
        return;
    };

    const fuzz_step = b.step("fuzz", "Run fuzz tests");
    for (fuzz.all) |step| fuzz_step.dependOn(step);

    inline for (Fuzz.specs, 0..) |spec, i| {
        const step = b.step("fuzz-" ++ spec.name, spec.description);
        step.dependOn(fuzz.all[i]);
    }
}
