/// Core Data Types for KDL 2.0.0 Documents
///
/// Defines the Abstract Syntax Tree (AST) structures used to represent
/// parsed KDL documents:
///
/// - `Value`: A single value (string, integer, float, boolean, null, inf, nan)
/// - `TypedValue`: A value with an optional type annotation
/// - `Property`: A key=value pair on a node
/// - `Node`: A KDL node with name, arguments, properties, and children
/// - `Document`: A complete KDL document with top-level nodes
///
/// All types support memory cleanup via `deinit()` methods. When using an
/// arena allocator, the arena's bulk deallocation handles cleanup automatically.
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents a KDL value - the data held by arguments and properties.
pub const Value = union(enum) {
    /// A string value (may need escape processing if from quoted string)
    string: StringValue,

    /// An integer value (can represent i128 range)
    integer: i128,

    /// A floating-point value
    float: FloatValue,

    /// Boolean true
    boolean: bool,

    /// Null value
    null_value: void,

    /// Positive infinity (#inf)
    positive_inf: void,

    /// Negative infinity (#-inf)
    negative_inf: void,

    /// Not a number (#nan)
    nan_value: void,

    pub const StringValue = struct {
        /// The raw text (may contain escapes if from quoted string)
        raw: []const u8,
    };

    pub const FloatValue = struct {
        /// The parsed float value
        value: f64,
        /// Original text (for preserving overflow/underflow values)
        original: ?[]const u8 = null,
    };

    /// Check if this value equals another
    pub fn eql(self: Value, other: Value) bool {
        const tag_self = std.meta.activeTag(self);
        const tag_other = std.meta.activeTag(other);
        if (tag_self != tag_other) return false;

        return switch (self) {
            .string => |s| std.mem.eql(u8, s.raw, other.string.raw),
            .integer => |i| i == other.integer,
            .float => |f| f.value == other.float.value,
            .boolean => |b| b == other.boolean,
            .null_value, .positive_inf, .negative_inf, .nan_value => true,
        };
    }
};

/// A typed value - a value with an optional type annotation
pub const TypedValue = struct {
    value: Value,
    type_annotation: ?[]const u8 = null,
};

/// Represents a KDL property (key=value pair)
pub const Property = struct {
    /// The property name
    name: []const u8,

    /// The property value
    value: Value,

    /// Optional type annotation on the value
    type_annotation: ?[]const u8 = null,
};

/// Represents a KDL node
pub const Node = struct {
    /// The node name
    name: []const u8,

    /// Optional type annotation on the node
    type_annotation: ?[]const u8 = null,

    /// Ordered list of arguments
    arguments: []TypedValue,

    /// Properties (key=value pairs) - order preserved, duplicates resolved
    properties: []Property,

    /// Child nodes
    children: []Node,

    /// Free all memory associated with this node
    pub fn deinit(self: *Node, allocator: Allocator) void {
        for (self.children) |*child| {
            child.deinit(allocator);
        }
        allocator.free(self.children);
        allocator.free(self.properties);
        allocator.free(self.arguments);
    }
};

/// Represents a complete KDL document
pub const Document = struct {
    /// Top-level nodes
    nodes: []Node,

    /// Allocator used for this document
    allocator: Allocator,

    /// Arena allocator that owns all document memory (optional, owned by parser)
    arena: ?*std.heap.ArenaAllocator = null,

    /// Free all memory associated with this document
    pub fn deinit(self: *Document) void {
        // If we own an arena, just free it (frees everything at once)
        if (self.arena) |arena| {
            const backing = arena.child_allocator;
            arena.deinit();
            backing.destroy(arena);
            return;
        }
        // Otherwise, free individual allocations
        for (self.nodes) |*node| {
            node.deinit(self.allocator);
        }
        self.allocator.free(self.nodes);
    }

    /// Get a node by name (first match)
    pub fn getNode(self: Document, name: []const u8) ?*const Node {
        for (self.nodes) |*node| {
            if (std.mem.eql(u8, node.name, name)) {
                return node;
            }
        }
        return null;
    }

    /// Get all nodes with a given name
    pub fn getNodes(self: Document, allocator: Allocator, name: []const u8) ![]const *const Node {
        var list = std.ArrayList(*const Node).init(allocator);
        defer list.deinit();

        for (self.nodes) |*node| {
            if (std.mem.eql(u8, node.name, name)) {
                try list.append(node);
            }
        }

        return try list.toOwnedSlice();
    }
};

// Tests

test "Value equality" {
    const v1 = Value{ .integer = 42 };
    const v2 = Value{ .integer = 42 };
    const v3 = Value{ .integer = 43 };

    try std.testing.expect(v1.eql(v2));
    try std.testing.expect(!v1.eql(v3));
}

test "Value string" {
    const v = Value{ .string = .{ .raw = "hello" } };
    try std.testing.expectEqualStrings("hello", v.string.raw);
}

test "Value types" {
    const bool_val = Value{ .boolean = true };
    const null_val = Value{ .null_value = {} };
    const inf_val = Value{ .positive_inf = {} };

    try std.testing.expect(bool_val.boolean);
    try std.testing.expectEqual(Value.null_value, null_val);
    try std.testing.expectEqual(Value.positive_inf, inf_val);
}
