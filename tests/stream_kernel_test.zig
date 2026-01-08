const std = @import("std");
const kdl = @import("kdl");

const KernelCapture = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged([]u8) = .{},

    fn init(allocator: std.mem.Allocator) KernelCapture {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *KernelCapture) void {
        for (self.events.items) |event| {
            self.allocator.free(event);
        }
        self.events.deinit(self.allocator);
    }

    pub fn onEvent(self: *KernelCapture, event: kdl.StreamKernelEvent) !void {
        const line = try formatEvent(self.allocator, event);
        try self.events.append(self.allocator, line);
    }

    fn formatEvent(allocator: std.mem.Allocator, event: kdl.StreamKernelEvent) ![]u8 {
        return switch (event) {
            .start_node => |n| if (n.type_annotation) |type_annot|
                std.fmt.allocPrint(
                    allocator,
                    "start name {s}:{s} type {s}:{s}",
                    .{ kindName(n.name.kind), n.name.text, kindName(type_annot.kind), type_annot.text },
                )
            else
                std.fmt.allocPrint(
                    allocator,
                    "start name {s}:{s} type <none>",
                    .{ kindName(n.name.kind), n.name.text },
                ),
            .end_node => std.fmt.allocPrint(allocator, "end", .{}),
            .argument => |a| {
                const value = try formatValue(allocator, a.value);
                defer allocator.free(value);
                if (a.type_annotation) |type_annot| {
                    return std.fmt.allocPrint(
                        allocator,
                        "arg {s} type {s}:{s}",
                        .{ value, kindName(type_annot.kind), type_annot.text },
                    );
                }
                return std.fmt.allocPrint(allocator, "arg {s}", .{value});
            },
            .property => |p| {
                const value = try formatValue(allocator, p.value);
                defer allocator.free(value);
                if (p.type_annotation) |type_annot| {
                    return std.fmt.allocPrint(
                        allocator,
                        "prop name {s}:{s} {s} type {s}:{s}",
                        .{ kindName(p.name.kind), p.name.text, value, kindName(type_annot.kind), type_annot.text },
                    );
                }
                return std.fmt.allocPrint(
                    allocator,
                    "prop name {s}:{s} {s}",
                    .{ kindName(p.name.kind), p.name.text, value },
                );
            },
        };
    }

    fn formatValue(allocator: std.mem.Allocator, value: kdl.StreamKernelValue) ![]u8 {
        return switch (value) {
            .string => |s| std.fmt.allocPrint(
                allocator,
                "string {s}:{s}",
                .{ kindName(s.kind), s.text },
            ),
            .integer => |i| std.fmt.allocPrint(allocator, "integer {d}", .{i}),
            .float => |f| std.fmt.allocPrint(
                allocator,
                "float {d} orig {s}",
                .{ f.value, f.original },
            ),
            .boolean => |b| std.fmt.allocPrint(allocator, "boolean {s}", .{if (b) "true" else "false"}),
            .null_value => std.fmt.allocPrint(allocator, "null", .{}),
            .positive_inf => std.fmt.allocPrint(allocator, "inf", .{}),
            .negative_inf => std.fmt.allocPrint(allocator, "-inf", .{}),
            .nan_value => std.fmt.allocPrint(allocator, "nan", .{}),
        };
    }

    fn kindName(kind: kdl.StreamKernelStringKind) []const u8 {
        return switch (kind) {
            .identifier => "identifier",
            .quoted_string => "quoted",
            .raw_string => "raw",
            .multiline_string => "multiline",
        };
    }
};

fn expectEvents(expected: []const []const u8, actual: []const []u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |exp, got| {
        try std.testing.expectEqualStrings(exp, got);
    }
}

test "stream kernel emits expected events (in-memory)" {
    const source =
        "(tag) node (atype) \"value\" prop=(ptype)\"pval\" count=42 #true raw=#\"raw\"# 1.5 {\n" ++
        "  child \"child\"\n" ++
        "}\n";

    var sink = KernelCapture.init(std.testing.allocator);
    defer sink.deinit();

    try kdl.parseWithKernel(std.testing.allocator, source, &sink, .{});

    const expected = [_][]const u8{
        "start name identifier:node type identifier:tag",
        "arg string quoted:\"value\" type identifier:atype",
        "prop name identifier:prop string quoted:\"pval\" type identifier:ptype",
        "prop name identifier:count integer 42",
        "arg boolean true",
        "prop name identifier:raw string raw:#\"raw\"#",
        "arg float 1.5 orig 1.5",
        "start name identifier:child type <none>",
        "arg string quoted:\"child\"",
        "end",
        "end",
    };

    try expectEvents(&expected, sink.events.items);
}

test "stream kernel handles chunked reader" {
    const source =
        "(tag) node (atype) \"value\" prop=(ptype)\"pval\" count=42 #true raw=#\"raw\"# 1.5 {\n" ++
        "  child \"child\"\n" ++
        "}\n";

    var reader = std.Io.Reader.fixed(source);
    var sink = KernelCapture.init(std.testing.allocator);
    defer sink.deinit();

    try kdl.parseReaderWithKernel(std.testing.allocator, &reader, &sink, .{ .chunk_size = 4 });

    const expected = [_][]const u8{
        "start name identifier:node type identifier:tag",
        "arg string quoted:\"value\" type identifier:atype",
        "prop name identifier:prop string quoted:\"pval\" type identifier:ptype",
        "prop name identifier:count integer 42",
        "arg boolean true",
        "prop name identifier:raw string raw:#\"raw\"#",
        "arg float 1.5 orig 1.5",
        "start name identifier:child type <none>",
        "arg string quoted:\"child\"",
        "end",
        "end",
    };

    try expectEvents(&expected, sink.events.items);
}
