/// KDL 2.0.0 Streaming Serializer
///
/// Serializes a `StreamDocument` to valid KDL text. Thread-safe when each
/// serializer instance operates on its own writer.
///
/// ## Usage
///
/// ```zig
/// var doc = try kdl.streamParse(allocator, source);
/// defer doc.deinit();
/// try kdl.streamSerialize(doc, stdout.writer(), .{});
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const stream_types = @import("stream_types.zig");
const StreamDocument = stream_types.StreamDocument;
const StreamValue = stream_types.StreamValue;
const StringRef = stream_types.StringRef;
const NodeHandle = stream_types.NodeHandle;
const Range = stream_types.Range;
const formatting = @import("formatting.zig");

pub const Options = formatting.Options;

/// Serialize a StreamDocument to a writer.
pub fn serialize(doc: *const StreamDocument, writer: anytype, options: Options) !void {
    var roots = doc.rootIterator();
    while (roots.next()) |handle| {
        try serializeNode(doc, handle, writer, 0, options);
    }
}

/// Serialize a StreamDocument to an owned string.
pub fn serializeToString(allocator: Allocator, doc: *const StreamDocument, options: Options) ![]u8 {
    var list = std.ArrayListUnmanaged(u8){};
    errdefer list.deinit(allocator);
    try serialize(doc, list.writer(allocator), options);
    return list.toOwnedSlice(allocator);
}

fn serializeNode(doc: *const StreamDocument, handle: NodeHandle, writer: anytype, depth: usize, options: Options) !void {
    // Indentation
    for (0..depth) |_| {
        try writer.writeAll(options.indent);
    }

    // Type annotation - check for presence (not just non-empty)
    const type_ann = doc.nodes.getTypeAnnotation(handle);
    if (!std.meta.eql(type_ann, StringRef.empty)) {
        try writer.writeByte('(');
        try formatting.writeString(doc.getString(type_ann), writer);
        try writer.writeByte(')');
    }

    // Node name
    try formatting.writeString(doc.getString(doc.nodes.getName(handle)), writer);

    // Arguments
    const args = doc.values.getArguments(doc.nodes.getArgRange(handle));
    for (args) |arg| {
        try writer.writeByte(' ');
        // Check for presence of type annotation (not just non-empty)
        // StringRef.empty = {0, 0} means no annotation; any other value means annotation exists
        if (!std.meta.eql(arg.type_annotation, StringRef.empty)) {
            try writer.writeByte('(');
            try formatting.writeString(doc.getString(arg.type_annotation), writer);
            try writer.writeByte(')');
        }
        try writeStreamValue(doc, arg.value, writer);
    }

    // Properties - only output the LAST value for each property name (KDL semantics)
    const props = doc.values.getProperties(doc.nodes.getPropRange(handle));
    for (props, 0..) |prop, i| {
        // Check if this is the last occurrence of this property name
        const prop_name = doc.getString(prop.name);
        var is_last = true;
        for (props[i + 1 ..]) |later_prop| {
            if (std.mem.eql(u8, doc.getString(later_prop.name), prop_name)) {
                is_last = false;
                break;
            }
        }
        if (!is_last) continue;

        try writer.writeByte(' ');
        try formatting.writeString(prop_name, writer);
        try writer.writeByte('=');
        // Check for presence of type annotation (not just non-empty)
        if (!std.meta.eql(prop.type_annotation, StringRef.empty)) {
            try writer.writeByte('(');
            try formatting.writeString(doc.getString(prop.type_annotation), writer);
            try writer.writeByte(')');
        }
        try writeStreamValue(doc, prop.value, writer);
    }

    // Children
    const first_child = doc.nodes.getFirstChild(handle);
    if (first_child != null) {
        try writer.writeAll(" {\n");
        var children = doc.childIterator(handle);
        while (children.next()) |child| {
            try serializeNode(doc, child, writer, depth + 1, options);
        }
        for (0..depth) |_| {
            try writer.writeAll(options.indent);
        }
        try writer.writeByte('}');
    }

    try writer.writeByte('\n');
}

fn writeStreamValue(doc: *const StreamDocument, value: StreamValue, writer: anytype) !void {
    switch (value) {
        .string => |ref| try formatting.writeString(doc.getString(ref), writer),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.writeAll(doc.getString(f.original)),
        .boolean => |b| try writer.writeAll(if (b) "#true" else "#false"),
        .null_value => try writer.writeAll("#null"),
        .positive_inf => try writer.writeAll("#inf"),
        .negative_inf => try writer.writeAll("#-inf"),
        .nan_value => try writer.writeAll("#nan"),
    }
}

// ============================================================================
// Tests
// ============================================================================

test "serialize simple node" {
    const stream_parser = @import("stream_parser.zig");
    var doc = try stream_parser.parse(std.testing.allocator, "node");
    defer doc.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(std.testing.allocator);

    try serialize(&doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node\n", output.items);
}

test "serialize node with arguments" {
    const stream_parser = @import("stream_parser.zig");
    var doc = try stream_parser.parse(std.testing.allocator, "node 42 \"hello\"");
    defer doc.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(std.testing.allocator);

    try serialize(&doc, output.writer(std.testing.allocator), .{});
    // "hello" becomes bare identifier in canonical form
    try std.testing.expectEqualStrings("node 42 hello\n", output.items);
}

test "serialize node with properties" {
    const stream_parser = @import("stream_parser.zig");
    var doc = try stream_parser.parse(std.testing.allocator, "node key=\"value\"");
    defer doc.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(std.testing.allocator);

    try serialize(&doc, output.writer(std.testing.allocator), .{});
    // "value" becomes bare identifier in canonical form
    try std.testing.expectEqualStrings("node key=value\n", output.items);
}

test "serialize node with children" {
    const stream_parser = @import("stream_parser.zig");
    const input = "parent {\n    child1\n    child2\n}\n";
    var doc = try stream_parser.parse(std.testing.allocator, input);
    defer doc.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(std.testing.allocator);

    try serialize(&doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("parent {\n    child1\n    child2\n}\n", output.items);
}

test "serialize keywords" {
    const stream_parser = @import("stream_parser.zig");
    var doc = try stream_parser.parse(std.testing.allocator, "node #true #false #null #inf #-inf #nan");
    defer doc.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(std.testing.allocator);

    try serialize(&doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("node #true #false #null #inf #-inf #nan\n", output.items);
}

test "serialize type annotations" {
    const stream_parser = @import("stream_parser.zig");
    var doc = try stream_parser.parse(std.testing.allocator, "(type)node (int)42");
    defer doc.deinit();

    var output = std.ArrayListUnmanaged(u8){};
    defer output.deinit(std.testing.allocator);

    try serialize(&doc, output.writer(std.testing.allocator), .{});
    try std.testing.expectEqualStrings("(type)node (int)42\n", output.items);
}

test "serializeToString" {
    const stream_parser = @import("stream_parser.zig");
    var doc = try stream_parser.parse(std.testing.allocator, "node 42");
    defer doc.deinit();

    const output = try serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);

    try std.testing.expectEqualStrings("node 42\n", output);
}
