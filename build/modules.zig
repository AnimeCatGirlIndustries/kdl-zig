const std = @import("std");

pub const ModuleRefs = struct {
    kdl: *std.Build.Module,
    util: *std.Build.Module,
    stream: *std.Build.Module,
    simd: *std.Build.Module,
    events: *std.Build.Module,
    types: *std.Build.Module,
    values: *std.Build.Module,
};

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub fn create(b: *std.Build, config: Config) ModuleRefs {
    const util_module = b.addModule("util", .{
        .root_source_file = b.path("src/util/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    const events_module = b.addModule("events", .{
        .root_source_file = b.path("src/stream/stream_events.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    const types_module = b.addModule("types", .{
        .root_source_file = b.path("src/stream/stream_types.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });

    const values_module = b.addModule("values", .{
        .root_source_file = b.path("src/stream/value_builder.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "types", .module = types_module },
        },
    });

    const simd_module = b.addModule("simd", .{
        .root_source_file = b.path("src/simd.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "events", .module = events_module },
            .{ .name = "types", .module = types_module },
            .{ .name = "values", .module = values_module },
        },
    });

    const stream_module = b.addModule("stream", .{
        .root_source_file = b.path("src/stream/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "simd", .module = simd_module },
            .{ .name = "events", .module = events_module },
            .{ .name = "types", .module = types_module },
            .{ .name = "values", .module = values_module },
        },
    });

    const kdl_module = b.addModule("kdl", .{
        .root_source_file = b.path("src/root.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .imports = &.{
            .{ .name = "util", .module = util_module },
            .{ .name = "stream", .module = stream_module },
            .{ .name = "simd", .module = simd_module },
        },
    });

    return .{
        .kdl = kdl_module,
        .util = util_module,
        .stream = stream_module,
        .simd = simd_module,
        .events = events_module,
        .types = types_module,
        .values = values_module,
    };
}
