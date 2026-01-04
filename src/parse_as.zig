/// KDL 2.0.0 Comptime Generic Parser
/// Parse KDL directly into Zig structs using comptime introspection.
/// Follows the std.json pattern for familiar API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Value = types.Value;
const TypedValue = types.TypedValue;
const Property = types.Property;
const Node = types.Node;
const Document = types.Document;
const parser = @import("parser.zig");

/// Parse error types
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    DuplicateProperty,
    OutOfMemory,
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
};

/// Options for parsing behavior
pub const ParseOptions = struct {
    /// How to handle duplicate fields
    duplicate_field_behavior: enum { use_first, @"error", use_last } = .use_last,
    /// Whether to ignore unknown fields in structs
    ignore_unknown_fields: bool = true,
    /// Whether to allocate strings (if false, strings point into source)
    allocate_strings: bool = true,
};

/// Wrapper for parsed result with memory management
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *std.heap.ArenaAllocator,
        value: T,

        const Self = @This();

        pub fn deinit(self: Self) void {
            const allocator = self.arena.child_allocator;
            self.arena.deinit();
            allocator.destroy(self.arena);
        }
    };
}

/// Parse KDL source directly into a typed struct
pub fn parseAs(
    comptime T: type,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) ParseError!Parsed(T) {
    // Create arena for all allocations
    const arena = allocator.create(std.heap.ArenaAllocator) catch return ParseError.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    // Parse to Document first
    const doc = parser.parse(allocator, source) catch |err| switch (err) {
        parser.Error.UnexpectedToken => return ParseError.UnexpectedToken,
        parser.Error.UnexpectedEof => return ParseError.UnexpectedEof,
        parser.Error.InvalidNumber => return ParseError.InvalidNumber,
        parser.Error.InvalidString => return ParseError.InvalidString,
        parser.Error.InvalidEscape => return ParseError.InvalidEscape,
        parser.Error.DuplicateProperty => return ParseError.DuplicateProperty,
        parser.Error.OutOfMemory => return ParseError.OutOfMemory,
    };
    defer @constCast(&doc).deinit();

    // Convert Document to T
    const value = try parseDocument(T, arena.allocator(), doc, options);

    return Parsed(T){
        .arena = arena,
        .value = value,
    };
}

/// Parse a document into a type
fn parseDocument(comptime T: type, allocator: Allocator, doc: Document, options: ParseOptions) ParseError!T {
    const info = @typeInfo(T);

    return switch (info) {
        .@"struct" => parseDocumentAsStruct(T, allocator, doc, options),
        .pointer => |ptr| blk: {
            if (ptr.size == .slice) {
                // []Node or similar - return all nodes as array of parsed items
                break :blk try parseNodesAsSlice(ptr.child, allocator, doc.nodes, options);
            }
            break :blk ParseError.TypeMismatch;
        },
        else => ParseError.TypeMismatch,
    };
}

/// Parse document as a struct (each top-level node becomes a field)
fn parseDocumentAsStruct(comptime T: type, allocator: Allocator, doc: Document, options: ParseOptions) ParseError!T {
    const fields = std.meta.fields(T);

    // Start with default values
    var result: T = .{};

    // Track which fields were set
    var fields_set: [fields.len]bool = .{false} ** fields.len;

    // Process each node
    for (doc.nodes) |node| {
        var found = false;
        inline for (fields, 0..) |field, i| {
            if (std.mem.eql(u8, node.name, field.name)) {
                @field(result, field.name) = try parseNode(field.type, allocator, node, options);
                fields_set[i] = true;
                found = true;
                break;
            }
        }
        if (!found and !options.ignore_unknown_fields) {
            return ParseError.UnknownField;
        }
    }

    // All fields have defaults from .{} initialization, so no need to check
    return result;
}

/// Parse a single node into a type
fn parseNode(comptime T: type, allocator: Allocator, node: Node, options: ParseOptions) ParseError!T {
    const info = @typeInfo(T);

    return switch (info) {
        .@"struct" => parseNodeAsStruct(T, allocator, node, options),
        .optional => |opt| blk: {
            const inner = try parseNode(opt.child, allocator, node, options);
            break :blk inner;
        },
        .int, .float => blk: {
            // For simple types, use the first argument
            if (node.arguments.len > 0) {
                break :blk try parseValue(T, node.arguments[0].value, options);
            }
            break :blk ParseError.MissingField;
        },
        .bool => blk: {
            if (node.arguments.len > 0) {
                break :blk try parseValue(T, node.arguments[0].value, options);
            }
            break :blk ParseError.MissingField;
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                // String type
                if (node.arguments.len > 0) {
                    break :blk try parseValue(T, node.arguments[0].value, options);
                }
                break :blk ParseError.MissingField;
            } else if (ptr.size == .slice) {
                // Array type - parse children as array elements
                break :blk try parseNodesAsSlice(ptr.child, allocator, node.children, options);
            }
            break :blk ParseError.TypeMismatch;
        },
        .@"enum" => blk: {
            if (node.arguments.len > 0) {
                break :blk try parseValue(T, node.arguments[0].value, options);
            }
            break :blk ParseError.MissingField;
        },
        else => ParseError.TypeMismatch,
    };
}

/// Parse node as struct (properties become fields, children become nested structs)
fn parseNodeAsStruct(comptime T: type, allocator: Allocator, node: Node, options: ParseOptions) ParseError!T {
    const fields = std.meta.fields(T);

    // Start with default values
    var result: T = .{};

    // Check for special __args field
    if (@hasField(T, "__args")) {
        @field(result, "__args") = try parseArgumentsAsSlice(
            std.meta.Elem(@TypeOf(@field(result, "__args"))),
            allocator,
            node.arguments,
            options,
        );
    }

    // Check for special __children field
    if (@hasField(T, "__children")) {
        @field(result, "__children") = try parseNodesAsSlice(
            std.meta.Elem(@TypeOf(@field(result, "__children"))),
            allocator,
            node.children,
            options,
        );
    }

    // Map properties to fields
    for (node.properties) |prop| {
        var found = false;
        inline for (fields) |field| {
            if (std.mem.eql(u8, prop.name, field.name)) {
                @field(result, field.name) = try parseValue(field.type, prop.value, options);
                found = true;
                break;
            }
        }
        if (!found and !options.ignore_unknown_fields) {
            return ParseError.UnknownField;
        }
    }

    // Map children nodes to fields by name
    for (node.children) |child| {
        inline for (fields) |field| {
            if (std.mem.eql(u8, child.name, field.name)) {
                @field(result, field.name) = try parseNode(field.type, allocator, child, options);
                break;
            }
        }
    }

    return result;
}

/// Parse arguments as a slice of values
fn parseArgumentsAsSlice(comptime T: type, allocator: Allocator, args: []const TypedValue, options: ParseOptions) ParseError![]T {
    const result = allocator.alloc(T, args.len) catch return ParseError.OutOfMemory;
    for (args, 0..) |arg, i| {
        result[i] = try parseValue(T, arg.value, options);
    }
    return result;
}

/// Parse nodes as a slice of items
fn parseNodesAsSlice(comptime T: type, allocator: Allocator, nodes: []const Node, options: ParseOptions) ParseError![]T {
    const result = allocator.alloc(T, nodes.len) catch return ParseError.OutOfMemory;
    for (nodes, 0..) |node, i| {
        result[i] = try parseNode(T, allocator, node, options);
    }
    return result;
}

/// Parse a KDL Value into a Zig type
fn parseValue(comptime T: type, value: Value, options: ParseOptions) ParseError!T {
    const info = @typeInfo(T);

    return switch (info) {
        .int => switch (value) {
            .integer => |i| std.math.cast(T, i) orelse return ParseError.TypeMismatch,
            else => ParseError.TypeMismatch,
        },
        .float => switch (value) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            .positive_inf => std.math.inf(T),
            .negative_inf => -std.math.inf(T),
            .nan_value => std.math.nan(T),
            else => ParseError.TypeMismatch,
        },
        .bool => switch (value) {
            .boolean => |b| b,
            else => ParseError.TypeMismatch,
        },
        .optional => |opt| switch (value) {
            .null_value => null,
            else => try parseValue(opt.child, value, options),
        },
        .pointer => |ptr| blk: {
            if (ptr.size == .slice and ptr.child == u8) {
                // String
                switch (value) {
                    .string => |s| break :blk s.raw,
                    else => break :blk ParseError.TypeMismatch,
                }
            }
            break :blk ParseError.TypeMismatch;
        },
        .@"enum" => |e| blk: {
            switch (value) {
                .string => |s| {
                    inline for (e.fields) |field| {
                        if (std.mem.eql(u8, s.raw, field.name)) {
                            break :blk @enumFromInt(field.value);
                        }
                    }
                    break :blk ParseError.InvalidEnumValue;
                },
                else => break :blk ParseError.TypeMismatch,
            }
        },
        else => ParseError.TypeMismatch,
    };
}

// Tests

test "parseAs simple struct" {
    const Config = struct {
        name: []const u8 = "",
        count: i32 = 0,
    };

    const result = try parseAs(Config, std.testing.allocator,
        \\name "test"
        \\count 42
    , .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("test", result.value.name);
    try std.testing.expectEqual(@as(i32, 42), result.value.count);
}

test "parseAs nested struct" {
    const Inner = struct {
        value: i32 = 0,
    };

    const Outer = struct {
        inner: ?Inner = null,
    };

    const result = try parseAs(Outer, std.testing.allocator,
        \\inner {
        \\    value 123
        \\}
    , .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 123), result.value.inner.?.value);
}

test "parseAs with properties" {
    const Person = struct {
        name: []const u8 = "",
        age: i32 = 0,
    };

    const result = try parseAs(Person, std.testing.allocator,
        \\name "Alice"
        \\age 30
    , .{});
    defer result.deinit();

    try std.testing.expectEqualStrings("Alice", result.value.name);
    try std.testing.expectEqual(@as(i32, 30), result.value.age);
}

test "parseAs optional fields" {
    const Config = struct {
        required: i32 = 0,
        optional: ?i32 = null,
    };

    const result = try parseAs(Config, std.testing.allocator,
        \\required 42
    , .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(i32, 42), result.value.required);
    try std.testing.expectEqual(@as(?i32, null), result.value.optional);
}

test "parseAs array of nodes" {
    const Item = struct {
        __args: []i32 = &.{},
    };

    // Parse at document level where nodes are parsed as array elements
    const result = try parseAs([]Item, std.testing.allocator,
        \\item 1
        \\item 2
        \\item 3
    , .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 3), result.value.len);
}

test "parseAs boolean values" {
    const Config = struct {
        enabled: bool = false,
        disabled: bool = true,
    };

    const result = try parseAs(Config, std.testing.allocator,
        \\enabled #true
        \\disabled #false
    , .{});
    defer result.deinit();

    try std.testing.expect(result.value.enabled);
    try std.testing.expect(!result.value.disabled);
}
