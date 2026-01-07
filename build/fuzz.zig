const std = @import("std");
const Modules = @import("modules.zig");

pub const FuzzSpec = struct {
    name: []const u8,
    path: []const u8,
    description: []const u8,
    module: bool = true,
};

pub const ModuleRefs = Modules.ModuleRefs;

pub const Config = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: ModuleRefs,
    args: ?[]const []const u8 = null,
};

pub const Collection = struct {
    all: []const *std.Build.Step,
};

pub const specs = [_]FuzzSpec{
    .{
        .name = "stream-iterator",
        .path = "tests/fuzz.zig",
        .description = "Run stream iterator fuzz tests",
    },
};

pub fn register(b: *std.Build, config: Config) !Collection {
    const allocator = b.allocator;

    var all_steps = std.ArrayListUnmanaged(*std.Build.Step){};
    defer all_steps.deinit(allocator);

    inline for (specs) |spec| {
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

        const fuzz_test = b.addTest(.{
            .root_module = root_module,
        });

        const run = b.addRunArtifact(fuzz_test);
        if (config.args) |args| {
            run.addArgs(args);
        }

        try all_steps.append(allocator, &run.step);
    }

    return .{
        .all = try all_steps.toOwnedSlice(allocator),
    };
}
