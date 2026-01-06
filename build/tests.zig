const std = @import("std");

pub const Area = enum {
    tokenizer,
    parser,
    serializer,
    integration,
};

pub const Membership = struct {
    unit: bool = false,
    integration: bool = false,
};

pub const TestSpec = struct {
    name: []const u8,
    area: Area,
    path: []const u8,
    module: bool = true, // Whether to import kdl module
    membership: Membership = .{},
};

pub const ModuleRefs = struct {
    kdl: *std.Build.Module,
};

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
};

pub fn register(b: *std.Build, config: Config) !Collection {
    const allocator = b.allocator;
    var all_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer all_steps.deinit(allocator);

    var unit_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer unit_steps.deinit(allocator);

    var integration_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer integration_steps.deinit(allocator);

    inline for (specs) |spec| {
        const run_step = try instantiateSpec(b, config, &spec);
        try all_steps.append(allocator, &run_step.step);
        if (spec.membership.unit) try unit_steps.append(allocator, &run_step.step);
        if (spec.membership.integration) try integration_steps.append(allocator, &run_step.step);
    }

    return .{
        .all = try all_steps.toOwnedSlice(allocator),
        .unit = try unit_steps.toOwnedSlice(allocator),
        .integration = try integration_steps.toOwnedSlice(allocator),
    };
}

fn instantiateSpec(
    b: *std.Build,
    config: Config,
    spec: *const TestSpec,
) !*std.Build.Step.Run {
    const imports: []const std.Build.Module.Import = if (spec.module)
        &.{.{ .name = "kdl", .module = config.modules.kdl }}
    else
        &.{};

    const root_module = b.createModule(.{
        .root_source_file = b.path(spec.path),
        .target = config.target,
        .optimize = config.optimize,
        .imports = imports,
    });

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
        .module = false,
        .membership = .{ .unit = true },
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
    // Stream iterator tests (replaced pull-parser)
    .{
        .name = "stream-iterator",
        .area = .parser,
        .path = "src/stream_iterator.zig",
        .membership = .{ .unit = true },
    },
    // Buffer boundary regression tests
    .{
        .name = "buffer-boundary",
        .area = .parser,
        .path = "tests/parser/buffer_boundary_test.zig",
        .membership = .{ .unit = true },
    },
};
