const std = @import("std");
const Modules = @import("modules.zig");

pub const Area = enum {
    tokenizer,
    parser,
    serializer,
    integration,
};

pub const ModuleChoice = enum {
    none,
    kdl,
    kdl_root,
    util,
    stream,
    simd,
    util_root,
    stream_root,
    simd_root,
};

pub const Membership = struct {
    default: bool = true,
    unit: bool = false,
    integration: bool = false,
    stream: bool = false,
    simd: bool = false,
    util: bool = false,
    kernel: bool = false,
};

pub const TestSpec = struct {
    name: []const u8,
    area: Area,
    path: []const u8,
    module: ModuleChoice = .kdl,
    membership: Membership = .{},
};

pub const ModuleRefs = Modules.ModuleRefs;

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: ModuleRefs,
    test_filters: []const []const u8,
};

pub const Collection = struct {
    all: []const *std.Build.Step,
    unit: []const *std.Build.Step,
    integration: []const *std.Build.Step,
    stream: []const *std.Build.Step,
    simd: []const *std.Build.Step,
    util: []const *std.Build.Step,
    kernel: []const *std.Build.Step,
};

pub fn register(b: *std.Build, config: Config) !Collection {
    const allocator = b.allocator;
    var all_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer all_steps.deinit(allocator);

    var unit_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer unit_steps.deinit(allocator);

    var integration_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer integration_steps.deinit(allocator);

    var stream_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer stream_steps.deinit(allocator);

    var simd_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer simd_steps.deinit(allocator);

    var util_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer util_steps.deinit(allocator);

    var kernel_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer kernel_steps.deinit(allocator);

    inline for (specs) |spec| {
        const run_step = try instantiateSpec(b, config, &spec);
        if (spec.membership.default) try all_steps.append(allocator, &run_step.step);
        if (spec.membership.unit) try unit_steps.append(allocator, &run_step.step);
        if (spec.membership.integration) try integration_steps.append(allocator, &run_step.step);
        if (spec.membership.stream) try stream_steps.append(allocator, &run_step.step);
        if (spec.membership.simd) try simd_steps.append(allocator, &run_step.step);
        if (spec.membership.util) try util_steps.append(allocator, &run_step.step);
        if (spec.membership.kernel) try kernel_steps.append(allocator, &run_step.step);
    }

    return .{
        .all = try all_steps.toOwnedSlice(allocator),
        .unit = try unit_steps.toOwnedSlice(allocator),
        .integration = try integration_steps.toOwnedSlice(allocator),
        .stream = try stream_steps.toOwnedSlice(allocator),
        .simd = try simd_steps.toOwnedSlice(allocator),
        .util = try util_steps.toOwnedSlice(allocator),
        .kernel = try kernel_steps.toOwnedSlice(allocator),
    };
}

fn instantiateSpec(
    b: *std.Build,
    config: Config,
    spec: *const TestSpec,
) !*std.Build.Step.Run {
    const root_module = switch (spec.module) {
        .kdl_root => config.modules.kdl,
        .util_root => config.modules.util,
        .stream_root => config.modules.stream,
        .simd_root => config.modules.simd,
        else => blk: {
            const imports: []const std.Build.Module.Import = switch (spec.module) {
                .none,
                .kdl_root,
                .util_root,
                .stream_root,
                .simd_root,
                => &.{},
                .kdl => &.{.{ .name = "kdl", .module = config.modules.kdl }},
                .util => &.{.{ .name = "util", .module = config.modules.util }},
                .stream => &.{.{ .name = "stream", .module = config.modules.stream }},
                .simd => &.{.{ .name = "simd", .module = config.modules.simd }},
            };
            break :blk b.createModule(.{
                .root_source_file = b.path(spec.path),
                .target = config.target,
                .optimize = config.optimize,
                .imports = imports,
            });
        },
    };

    const test_compile = b.addTest(.{
        .root_module = root_module,
        .filters = config.test_filters,
    });

    return b.addRunArtifact(test_compile);
}

pub const specs = [_]TestSpec{
    // Module unit tests (inline tests in source files)
    .{
        .name = "kdl-module",
        .area = .tokenizer,
        .path = "src/root.zig",
        .module = .kdl_root,
        .membership = .{ .unit = true },
    },
    .{
        .name = "util-module",
        .area = .tokenizer,
        .path = "src/util/root.zig",
        .module = .util_root,
        .membership = .{ .util = true, .default = false },
    },
    .{
        .name = "stream-module",
        .area = .parser,
        .path = "src/stream/root.zig",
        .module = .stream_root,
        .membership = .{ .stream = true, .default = false },
    },
    .{
        .name = "simd-module",
        .area = .parser,
        .path = "src/simd.zig",
        .module = .simd_root,
        .membership = .{ .simd = true, .default = false },
    },
    // Tokenizer tests
    .{
        .name = "tokenizer-strings",
        .area = .tokenizer,
        .path = "tests/tokenizer/strings_test.zig",
        .membership = .{ .unit = true },
    },
    .{
        .name = "tokenizer-numbers",
        .area = .tokenizer,
        .path = "tests/tokenizer/numbers_test.zig",
        .membership = .{ .unit = true },
    },
    .{
        .name = "tokenizer-keywords",
        .area = .tokenizer,
        .path = "tests/tokenizer/keywords_test.zig",
        .membership = .{ .unit = true },
    },
    .{
        .name = "tokenizer-comments",
        .area = .tokenizer,
        .path = "tests/tokenizer/comments_test.zig",
        .membership = .{ .unit = true },
    },
    .{
        .name = "tokenizer-integration",
        .area = .integration,
        .path = "tests/tokenizer/integration_test.zig",
        .membership = .{ .integration = true },
    },
    // Parser/serializer integration tests
    .{
        .name = "kdl-test-suite",
        .area = .integration,
        .path = "tests/parser/kdl_test_suite.zig",
        .membership = .{ .integration = true },
    },
    // Multiline string tests
    .{
        .name = "multiline-strings",
        .area = .parser,
        .path = "tests/parser/multiline_strings_test.zig",
        .membership = .{ .unit = true },
    },
    // Validation tests
    .{
        .name = "validation",
        .area = .parser,
        .path = "tests/parser/validation_test.zig",
        .membership = .{ .unit = true },
    },
    // String processing tests
    .{
        .name = "string-processing",
        .area = .parser,
        .path = "tests/parser/string_processing_test.zig",
        .membership = .{ .unit = true },
    },
    // Slashdash tests
    .{
        .name = "slashdash",
        .area = .parser,
        .path = "tests/parser/slashdash_test.zig",
        .membership = .{ .unit = true },
    },
    // Number processing tests
    .{
        .name = "number-processing",
        .area = .parser,
        .path = "tests/parser/number_processing_test.zig",
        .membership = .{ .unit = true },
    },
    // Multiline string validation tests
    .{
        .name = "multiline-validation",
        .area = .parser,
        .path = "tests/parser/multiline_validation_test.zig",
        .membership = .{ .unit = true },
    },
    // Buffer boundary regression tests
    .{
        .name = "buffer-boundary",
        .area = .parser,
        .path = "tests/parser/buffer_boundary_test.zig",
        .membership = .{ .unit = true },
    },
    .{
        .name = "simd-index-parser",
        .area = .parser,
        .path = "tests/simd/index_parser_test.zig",
        .membership = .{ .unit = true, .simd = true },
    },
    .{
        .name = "stream-kernel",
        .area = .parser,
        .path = "tests/stream_kernel_test.zig",
        .membership = .{ .unit = true, .kernel = true, .stream = true },
    },
};
