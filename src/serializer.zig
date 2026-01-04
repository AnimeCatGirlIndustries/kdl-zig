/// KDL 2.0.0 Serializer
/// Converts AST back to valid KDL text.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Value = types.Value;
const TypedValue = types.TypedValue;
const Property = types.Property;
const Node = types.Node;
const Document = types.Document;
const unicode = @import("unicode.zig");

/// Serialization options
pub const Options = struct {
    /// Indentation string (default: 4 spaces)
    indent: []const u8 = "    ",
};

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
        try writeString(type_ann, writer);
        try writer.writeByte(')');
    }

    // Node name
    try writeString(node.name, writer);

    // Arguments
    for (node.arguments) |arg| {
        try writer.writeByte(' ');
        if (arg.type_annotation) |type_ann| {
            try writer.writeByte('(');
            try writeString(type_ann, writer);
            try writer.writeByte(')');
        }
        try writeValue(arg.value, writer);
    }

    // Properties (sorted alphabetically)
    const sorted_props = try sortProperties(node.properties, std.heap.page_allocator);
    defer std.heap.page_allocator.free(sorted_props);

    for (sorted_props) |prop| {
        try writer.writeByte(' ');
        try writeString(prop.name, writer);
        try writer.writeByte('=');
        if (prop.type_annotation) |type_ann| {
            try writer.writeByte('(');
            try writeString(type_ann, writer);
            try writer.writeByte(')');
        }
        try writeValue(prop.value, writer);
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

fn sortProperties(props: []const Property, allocator: Allocator) ![]const Property {
    if (props.len == 0) return &.{};

    const sorted = try allocator.alloc(Property, props.len);
    @memcpy(sorted, props);

    std.mem.sort(Property, sorted, {}, struct {
        fn lessThan(_: void, a: Property, b: Property) bool {
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lessThan);

    return sorted;
}

fn writeValue(value: Value, writer: anytype) !void {
    switch (value) {
        .string => |s| try writeString(s.raw, writer),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writeFloatValue(f, writer),
        .boolean => |b| try writer.writeAll(if (b) "#true" else "#false"),
        .null_value => try writer.writeAll("#null"),
        .positive_inf => try writer.writeAll("#inf"),
        .negative_inf => try writer.writeAll("#-inf"),
        .nan_value => try writer.writeAll("#nan"),
    }
}

fn writeFloatValue(fv: Value.FloatValue, writer: anytype) !void {
    // If we have the original text, normalize and output it for round-trip fidelity
    if (fv.original) |original| {
        try writeNormalizedFloat(original, writer);
        return;
    }
    // Otherwise format the float value normally
    try writeFloat(fv.value, writer);
}

fn writeNormalizedFloat(original: []const u8, writer: anytype) !void {
    // Normalize: strip underscores, uppercase E, ensure + after E for positive exponents
    var in_exponent = false;
    var wrote_exp_sign = false;

    for (original, 0..) |c, i| {
        if (c == '_') continue; // Skip underscores

        if (c == 'e' or c == 'E') {
            try writer.writeByte('E');
            in_exponent = true;
            wrote_exp_sign = false;
            // Check if next char is a sign
            if (i + 1 < original.len) {
                const next = original[i + 1];
                if (next == '+' or next == '-') {
                    // Sign will be written on next iteration
                } else if (next >= '0' and next <= '9') {
                    // No sign, add +
                    try writer.writeByte('+');
                    wrote_exp_sign = true;
                }
            }
        } else if (in_exponent and !wrote_exp_sign and (c == '+' or c == '-')) {
            try writer.writeByte(c);
            wrote_exp_sign = true;
        } else {
            try writer.writeByte(c);
        }
    }
}

fn writeFloat(f: f64, writer: anytype) !void {
    if (std.math.isNan(f)) {
        try writer.writeAll("#nan");
        return;
    }
    if (std.math.isInf(f)) {
        try writer.writeAll(if (f < 0) "#-inf" else "#inf");
        return;
    }

    // Use scientific notation for very large or very small numbers
    const abs = @abs(f);
    if (abs != 0 and (abs >= 1.0e10 or abs < 1.0e-4)) {
        // Scientific notation - use custom formatting for KDL spec compliance
        try writeScientific(f, writer);
    } else {
        // Regular decimal notation - ensure it has a decimal point
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch {
            try writer.print("{d}", .{f});
            return;
        };
        try writer.writeAll(formatted);
        // If no decimal point, add ".0"
        if (std.mem.indexOf(u8, formatted, ".") == null) {
            try writer.writeAll(".0");
        }
    }
}

fn writeScientific(f: f64, writer: anytype) !void {
    // KDL format: 1.0E+10, 1.23E-10, etc.
    // Always include decimal point for scientific notation (more tests pass this way)
    const abs = @abs(f);

    // Calculate exponent
    var exp: i32 = 0;
    var mantissa = abs;
    if (mantissa >= 10.0) {
        while (mantissa >= 10.0) {
            mantissa /= 10.0;
            exp += 1;
        }
    } else if (mantissa > 0 and mantissa < 1.0) {
        while (mantissa < 1.0) {
            mantissa *= 10.0;
            exp -= 1;
        }
    }

    // Handle sign
    if (f < 0) try writer.writeByte('-');

    // Write mantissa with decimal point
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{mantissa}) catch {
        try writer.print("{d}E{d}", .{ mantissa, exp });
        return;
    };

    try writer.writeAll(formatted);
    // Don't add .0 for integer mantissa in scientific notation - KDL allows 1E+10

    // Write exponent with sign
    try writer.writeByte('E');
    if (exp >= 0) {
        try writer.writeByte('+');
    }
    try writer.print("{d}", .{exp});
}

fn writeString(s: []const u8, writer: anytype) !void {
    // Check if it's a valid bare identifier
    if (isValidIdentifier(s)) {
        try writer.writeAll(s);
    } else {
        try writeQuotedString(s, writer);
    }
}

fn writeQuotedString(s: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    // Control character - use unicode escape
                    try writer.print("\\u{{{x}}}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;

    // Check first character - decode UTF-8
    const first_decoded = unicode.decodeUtf8(s) orelse return false;
    if (!unicode.isIdentifierStart(first_decoded.codepoint)) return false;

    // Check if it's a keyword that needs quoting
    if (isKeyword(s)) return false;

    // Check rest of characters - decode UTF-8 for each codepoint
    var i: usize = first_decoded.len;
    while (i < s.len) {
        const remaining = s[i..];
        const decoded = unicode.decodeUtf8(remaining) orelse return false;
        if (!unicode.isIdentifierChar(decoded.codepoint)) return false;
        i += decoded.len;
    }

    return true;
}

fn isKeyword(s: []const u8) bool {
    // KDL 2.0 keywords start with # so bare words are generally fine
    // But we need to be careful about words that look like numbers
    if (s.len == 0) return false;

    const first = s[0];
    // If it starts with a digit or sign followed by digit, it's not a valid identifier anyway
    if (first >= '0' and first <= '9') return true;
    if ((first == '+' or first == '-') and s.len > 1) {
        const second = s[1];
        if (second >= '0' and second <= '9') return true;
    }

    return false;
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
    var args = [_]TypedValue{
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
    var args = [_]TypedValue{
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
    var props = [_]Property{
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

test "serialize properties alphabetically" {
    var props = [_]Property{
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
    try std.testing.expectEqualStrings("node apple=2 mango=3 zebra=1\n", output.items);
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
    var args = [_]TypedValue{
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
    var args = [_]TypedValue{
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
