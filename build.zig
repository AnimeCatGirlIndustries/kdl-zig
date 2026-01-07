const std = @import("std");
const Modules = @import("build/modules.zig");
const Bench = @import("build/bench.zig");
const Fuzz = @import("build/fuzz.zig");
const Tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const modules = Modules.create(b, .{
        .target = target,
        .optimize = optimize,
    });

    const util_lib = b.addLibrary(.{
        .name = "kdl_util",
        .linkage = .static,
        .root_module = modules.util,
    });
    const simd_lib = b.addLibrary(.{
        .name = "kdl_simd",
        .linkage = .static,
        .root_module = modules.simd,
    });
    const stream_lib = b.addLibrary(.{
        .name = "kdl_stream",
        .linkage = .static,
        .root_module = modules.stream,
    });
    const kdl_lib = b.addLibrary(.{
        .name = "kdl",
        .linkage = .static,
        .root_module = modules.kdl,
    });

    const lib_step = b.step("lib", "Build static libraries");
    lib_step.dependOn(&util_lib.step);
    lib_step.dependOn(&simd_lib.step);
    lib_step.dependOn(&stream_lib.step);
    lib_step.dependOn(&kdl_lib.step);

    inline for ([_]struct { name: []const u8, step: *std.Build.Step.Compile }{
        .{ .name = "lib-util", .step = util_lib },
        .{ .name = "lib-simd", .step = simd_lib },
        .{ .name = "lib-stream", .step = stream_lib },
        .{ .name = "lib-kdl", .step = kdl_lib },
    }) |spec| {
        const step = b.step(spec.name, "Build static library");
        step.dependOn(&spec.step.step);
    }

    // Example: Tokenizer Demo
    const demo_exe = b.addExecutable(.{
        .name = "tokenizer-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tokenizer_demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kdl", .module = modules.kdl },
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
        .modules = modules,
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
        .modules = modules,
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

    const stream_test_step = b.step("test-stream", "Run stream module tests");
    for (tests.stream) |step| stream_test_step.dependOn(step);

    const simd_test_step = b.step("test-simd", "Run SIMD tests");
    for (tests.simd) |step| simd_test_step.dependOn(step);

    const util_test_step = b.step("test-util", "Run util module tests");
    for (tests.util) |step| util_test_step.dependOn(step);

    const kernel_test_step = b.step("test-kernel", "Run stream kernel tests");
    for (tests.kernel) |step| kernel_test_step.dependOn(step);

    // Fuzzing
    const fuzz = Fuzz.register(b, .{
        .target = target,
        .optimize = optimize,
        .modules = modules,
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
