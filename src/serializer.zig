/// KDL 2.0.0 Serializer
///
/// Converts a `Document` AST back to valid KDL text. Outputs follow the
/// canonical format expected by the KDL test suite:
/// - One node per line (no multi-line nodes)
/// - Properties in alphabetical order
/// - Proper string escaping and quoting
/// - 4-space indentation for children
///
/// ## Usage
///
/// ```zig
/// // Serialize to a writer
/// try kdl.serialize(document, stdout.writer(), .{});
///
/// // Or serialize to a string
/// const text = try kdl.serializeToString(allocator, document, .{});
/// defer allocator.free(text);
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Node = types.Node;
const Document = types.Document;
const formatting = @import("formatting.zig");

/// Serialization options
pub const Options = formatting.Options;

/// Serialize a document to a writer
pub fn serialize(document: Document, writer: anytype, options: Options) !void {
    for (document.nodes) |node| {
        try serializeNode(node, writer, 0, options);
    }
}

/// Serialize a document to an owned string
pub fn serializeToString(allocator: Allocator, document: Document, options: Options) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .{};
    try serialize(document, list.writer(allocator), options);
    return list.toOwnedSlice(allocator);
}

fn serializeNode(node: Node, writer: anytype, depth: usize, options: Options) !void {
    // Indentation
    for (0..depth) |_| {
        try writer.writeAll(options.indent);
    }

    // Type annotation
    if (node.type_annotation) |type_ann| {
        try writer.writeByte('(');
        try formatting.writeString(type_ann, writer);
        try writer.writeByte(')');
    }

    // Node name
    try formatting.writeString(node.name, writer);

    // Arguments
    for (node.arguments) |arg| {
        try writer.writeByte(' ');
        if (arg.type_annotation) |type_ann| {
            try writer.writeByte('(');
            try formatting.writeString(type_ann, writer);
            try writer.writeByte(')');
        }
        try formatting.writeValue(arg.value, writer);
    }

    // Properties (preserve original order)
    for (node.properties) |prop| {
        try writer.writeByte(' ');
        try formatting.writeString(prop.name, writer);
        try writer.writeByte('=');
        if (prop.type_annotation) |type_ann| {
            try writer.writeByte('(');
            try formatting.writeString(type_ann, writer);
            try writer.writeByte(')');
        }
        try formatting.writeValue(prop.value, writer);
    }

    // Children
    if (node.children.len > 0) {
        try writer.writeAll(" {\n");
        for (node.children) |child| {
            try serializeNode(child, writer, depth + 1, options);
        }
        for (0..depth) |_| {
            try writer.writeAll(options.indent);
        }
        try writer.writeByte('}');
    }

    try writer.writeByte('\n');
}

// Tests

test "serialize empty document" {
    const doc = Document{
        .nodes = &.{},
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("", output.items);
}

test "serialize simple node" {
    var nodes = [_]Node{
        .{
            .name = "node",
            .arguments = &.{},
            .properties = &.{},
            .children = &.{},
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node\n", output.items);
}

test "serialize node with argument" {
    var args = [_]types.TypedValue{
        .{ .value = .{ .integer = 42 } },
    };
    var nodes = [_]Node{
        .{
            .name = "node",
            .arguments = &args,
            .properties = &.{},
            .children = &.{},
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node 42\n", output.items);
}

test "serialize node with string argument" {
    var args = [_]types.TypedValue{
        .{ .value = .{ .string = .{ .raw = "hello" } } },
    };
    var nodes = [_]Node{
        .{
            .name = "node",
            .arguments = &args,
            .properties = &.{},
            .children = &.{},
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    // "hello" is a valid bare identifier, so no quotes
    try std.testing.expectEqualStrings("node hello\n", output.items);
}

test "serialize node with property" {
    var props = [_]types.Property{
        .{ .name = "key", .value = .{ .integer = 42 } },
    };
    var nodes = [_]Node{
        .{
            .name = "node",
            .arguments = &.{},
            .properties = &props,
            .children = &.{},
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node key=42\n", output.items);
}

test "serialize properties preserve order" {
    var props = [_]types.Property{
        .{ .name = "zebra", .value = .{ .integer = 1 } },
        .{ .name = "apple", .value = .{ .integer = 2 } },
        .{ .name = "mango", .value = .{ .integer = 3 } },
    };
    var nodes = [_]Node{
        .{
            .name = "node",
            .arguments = &.{},
            .properties = &props,
            .children = &.{},
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node zebra=1 apple=2 mango=3\n", output.items);
}

test "serialize node with children" {
    var child_nodes = [_]Node{
        .{
            .name = "child",
            .arguments = &.{},
            .properties = &.{},
            .children = &.{},
        },
    };
    var nodes = [_]Node{
        .{
            .name = "parent",
            .arguments = &.{},
            .properties = &.{},
            .children = &child_nodes,
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("parent {\n    child\n}\n", output.items);
}

test "serialize keywords" {
    var args = [_]types.TypedValue{
        .{ .value = .{ .boolean = true } },
        .{ .value = .{ .boolean = false } },
        .{ .value = .{ .null_value = {} } },
    };
    var nodes = [_]Node{
        .{
            .name = "node",
            .arguments = &args,
            .properties = &.{},
            .children = &.{},
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node #true #false #null\n", output.items);
}

test "serialize escape sequences" {
    var args = [_]types.TypedValue{
        .{ .value = .{ .string = .{ .raw = "hello\nworld" } } },
    };
    var nodes = [_]Node{
        .{
            .name = "node",
            .arguments = &args,
            .properties = &.{},
            .children = &.{},
        },
    };
    const doc = Document{
        .nodes = &nodes,
        .allocator = std.testing.allocator,
    };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);
    try serialize(doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node \"hello\\nworld\"\n", output.items);
}