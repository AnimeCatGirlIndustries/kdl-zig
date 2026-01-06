const std = @import("std");

pub const BenchmarkSpec = struct {
    name: []const u8,
    exe_name: []const u8,
    path: []const u8,
    description: []const u8,
};

pub const ModuleRefs = struct {
    kdl: *std.Build.Module,
};

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: ModuleRefs,
    args: ?[]const []const u8 = null,
};

pub const Collection = struct {
    all: []const *std.Build.Step,
    executables: []const *std.Build.Step.Compile,
};

pub const specs = [_]BenchmarkSpec{
    .{
        .name = "main",
        .exe_name = "kdl-bench",
        .path = "benches/bench.zig",
        .description = "Run KDL benchmarks",
    },
    .{
        .name = "parser",
        .exe_name = "kdl-bench-parser",
        .path = "benches/parser_bench.zig",
        .description = "Run parser benchmarks",
    },
    .{
        .name = "simd",
        .exe_name = "kdl-bench-simd",
        .path = "benches/simd_bench.zig",
        .description = "Run SIMD micro-benchmarks",
    },
};

pub fn register(b: *std.Build, config: Config) !Collection {
    const allocator = b.allocator;

    var all_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer all_steps.deinit(allocator);

    var executables = std.ArrayListUnmanaged(*std.Build.Step.Compile){};
    defer executables.deinit(allocator);

    inline for (specs) |spec| {
        const bench_module = b.createModule(.{
            .root_source_file = b.path(spec.path),
            .target = config.target,
            .optimize = config.optimize,
            .imports = &.{.{ .name = "kdl", .module = config.modules.kdl }},
        });

        const exe = b.addExecutable(.{
            .name = spec.exe_name,
            .root_module = bench_module,
        });

        const run = b.addRunArtifact(exe);
        if (config.args) |args| {
            run.addArgs(args);
        }

        try all_steps.append(allocator, &run.step);
        try executables.append(allocator, exe);
    }

    return .{
        .all = try all_steps.toOwnedSlice(allocator),
        .executables = try executables.toOwnedSlice(allocator),
    };
}
