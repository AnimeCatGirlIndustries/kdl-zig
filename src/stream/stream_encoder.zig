/// KDL 2.0.0 Stream Encoder
///
/// Encodes Zig structs directly into KDL text using comptime reflection.
/// Writes directly to an output stream without intermediate representation.
///
/// ## Struct Field Mapping
///
/// - Regular fields become KDL nodes with the field value as the first argument
/// - `__args` field: slice/tuple of values output as node arguments
/// - Nested structs become child nodes
/// - Optionals are skipped if null
///
/// ## Thread Safety
///
/// Encoding is stateless - multiple concurrent encodes are safe as long as
/// they use separate writers.
///
/// ## Usage
///
/// ```zig
/// const config = MyConfig{ .name = "test", .count = 42 };
/// try kdl.streamEncode(config, stdout.writer(), .{});
/// ```
const std = @import("std");
const util = @import("util");
const formatting = util.formatting;

/// Encoding options (indentation, etc.)
pub const EncodeOptions = formatting.Options;

pub const Error = error{
    OutOfMemory,
    DiskQuota,
    FileTooBig,
    InputOutput,
    SystemResources,
    AccessDenied,
    Unexpected,
    InvalidCharacter,
} || std.fs.File.WriteError || std.mem.Allocator.Error;

/// Encode a Zig struct to KDL format.
pub fn encode(value: anytype, writer: anytype, options: EncodeOptions) Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => {
            try encodeStructContent(value, writer, 0, options);
        },
        .pointer => |ptr| {
            if (ptr.size == .one) {
                try encode(value.*, writer, options);
            } else {
                return error.Unexpected;
            }
        },
        else => return error.Unexpected,
    }
}

fn encodeStructContent(value: anytype, writer: anytype, depth: usize, options: EncodeOptions) Error!void {
    const T = @TypeOf(value);
    const fields = std.meta.fields(T);

    inline for (fields) |field| {
        // Skip special fields at top level
        if (comptime std.mem.eql(u8, field.name, "__args")) continue;

        const field_val = @field(value, field.name);
        try encodeNodeOrNodes(field.name, field_val, writer, depth, options);
    }
}

fn encodeNodeOrNodes(name: []const u8, value: anytype, writer: anytype, depth: usize, options: EncodeOptions) Error!void {
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .optional => {
            if (value) |v| {
                try encodeNodeOrNodes(name, v, writer, depth, options);
            }
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child != u8) {
                // Repeated nodes
                for (value) |item| {
                    try encodeNode(name, item, writer, depth, options);
                }
            } else {
                // String or single pointer
                try encodeNode(name, value, writer, depth, options);
            }
        },
        else => {
            try encodeNode(name, value, writer, depth, options);
        },
    }
}

fn encodeNode(name: []const u8, value: anytype, writer: anytype, depth: usize, options: EncodeOptions) Error!void {
    // Indentation
    for (0..depth) |_| {
        try writer.writeAll(options.indent);
    }

    // Name
    try formatting.writeString(name, writer);

    // Body
    const T = @TypeOf(value);
    const info = @typeInfo(T);

    switch (info) {
        .@"struct" => {
            try encodeStructNodeBody(value, writer, depth, options);
        },
        .int, .float, .bool, .@"enum" => {
            try writer.writeByte(' ');
            try encodeValue(value, writer);
            try writer.writeByte('\n');
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try writer.writeByte(' ');
                try encodeValue(value, writer);
                try writer.writeByte('\n');
            } else if (ptr.size == .one) {
                // Dereference and recurse (but not for string slices)
                try encodeNode(name, value.*, writer, depth, options);
            } else {
                return error.Unexpected;
            }
        },
        else => return error.Unexpected,
    }
}

fn encodeStructNodeBody(value: anytype, writer: anytype, depth: usize, options: EncodeOptions) Error!void {
    const T = @TypeOf(value);
    const fields = std.meta.fields(T);

    // 1. Arguments
    if (@hasField(T, "__args")) {
        const args = @field(value, "__args");
        const args_info = @typeInfo(@TypeOf(args));
        if (args_info == .pointer and args_info.pointer.size == .slice) {
            for (args) |arg| {
                try writer.writeByte(' ');
                try encodeValue(arg, writer);
            }
        } else if (args_info == .@"struct" and args_info.@"struct".is_tuple) {
            inline for (args) |arg| {
                try writer.writeByte(' ');
                try encodeValue(arg, writer);
            }
        }
    }

    // 2. Properties (simple types as key=value)
    inline for (fields) |field| {
        if (comptime isKdlPropertyType(field.type) and !isSpecialField(field.name)) {
            const val = @field(value, field.name);
            if (@typeInfo(field.type) == .optional) {
                if (val) |v| {
                    try writeProp(field.name, v, writer);
                }
            } else {
                try writeProp(field.name, val, writer);
            }
        }
    }

    // 3. Children (nested structs)
    var has_children = false;
    inline for (fields) |field| {
        if (comptime isKdlChildType(field.type) and !isSpecialField(field.name)) {
            const val = @field(value, field.name);
            const field_info = @typeInfo(field.type);
            if (field_info == .optional) {
                if (val != null) has_children = true;
            } else if (field_info == .pointer and field_info.pointer.size == .slice) {
                if (val.len > 0) has_children = true;
            } else {
                has_children = true;
            }
        }
    }

    if (has_children) {
        try writer.writeAll(" {\n");

        inline for (fields) |field| {
            if (comptime isKdlChildType(field.type) and !isSpecialField(field.name)) {
                const val = @field(value, field.name);
                try encodeNodeOrNodes(field.name, val, writer, depth + 1, options);
            }
        }

        for (0..depth) |_| try writer.writeAll(options.indent);
        try writer.writeByte('}');
    }

    try writer.writeByte('\n');
}

fn writeProp(name: []const u8, val: anytype, writer: anytype) Error!void {
    try writer.writeByte(' ');
    try formatting.writeString(name, writer);
    try writer.writeByte('=');
    try encodeValue(val, writer);
}

fn isSpecialField(name: []const u8) bool {
    return std.mem.eql(u8, name, "__args");
}

fn isKdlPropertyType(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .optional => return isKdlPropertyType(info.optional.child),
        .int, .float, .bool, .@"enum" => return true,
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) return true;
            return false;
        },
        else => return false,
    }
}

fn isKdlChildType(comptime T: type) bool {
    const info = @typeInfo(T);
    switch (info) {
        .optional => return isKdlChildType(info.optional.child),
        .@"struct" => return true,
        .pointer => |ptr| {
            // Slice of bytes is string (Property), not Child
            if (ptr.size == .slice and ptr.child != u8) return true;
            return false;
        },
        else => return false,
    }
}

fn encodeValue(value: anytype, writer: anytype) Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => try writer.print("{d}", .{value}),
        .float => try formatting.writeFloatValue(.{ .value = @floatCast(value) }, writer),
        .bool => try writer.writeAll(if (value) "#true" else "#false"),
        .@"enum" => try formatting.writeString(@tagName(value), writer),
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                try formatting.writeString(value, writer);
            } else {
                return error.Unexpected;
            }
        },
        .null => try writer.writeAll("#null"),
        .optional => {
            if (value) |v| try encodeValue(v, writer) else try writer.writeAll("#null");
        },
        else => return error.Unexpected,
    }
}

// ============================================================================
// Tests
// ============================================================================

test "encode simple struct" {
    const Config = struct {
        host: []const u8,
        port: u16,
    };
    const config = Config{ .host = "localhost", .port = 8080 };

    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(config, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "host localhost\nport 8080\n",
        output.items,
    );
}

test "encode nested struct (property)" {
    const Server = struct {
        port: u16,
    };
    const Config = struct {
        server: Server,
    };

    const config = Config{ .server = .{ .port = 80 } };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(config, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "server port=80\n",
        output.items,
    );
}

test "encode nested struct (child node)" {
    const Child = struct {
        val: u16,
    };
    const Parent = struct {
        child: Child,
    };
    const Doc = struct {
        parent: Parent,
    };

    const doc = Doc{ .parent = .{ .child = .{ .val = 1 } } };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(doc, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "parent {\n    child val=1\n}\n",
        output.items,
    );
}

test "encode arguments" {
    const Node = struct {
        __args: std.meta.Tuple(&.{ []const u8, i32 }),
        key: []const u8,
    };

    const Doc = struct {
        node: Node,
    };

    const doc = Doc{ .node = .{ .__args = .{ "foo", 123 }, .key = "val" } };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(doc, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "node foo 123 key=val\n",
        output.items,
    );
}

test "encode slice of nodes" {
    const Item = struct {
        id: i32,
    };
    const Inventory = struct {
        item: []const Item,
    };

    const inv = Inventory{ .item = &.{ .{ .id = 1 }, .{ .id = 2 } } };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(inv, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "item id=1\nitem id=2\n",
        output.items,
    );
}

test "encode optional fields" {
    const Config = struct {
        required: i32,
        optional: ?i32 = null,
    };

    const config = Config{ .required = 42 };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(config, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "required 42\n",
        output.items,
    );
}

test "encode boolean values" {
    const Config = struct {
        enabled: bool,
        disabled: bool,
    };

    const config = Config{ .enabled = true, .disabled = false };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(config, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "enabled #true\ndisabled #false\n",
        output.items,
    );
}

test "encode enum values" {
    const Status = enum { active, inactive, pending };

    const Config = struct {
        status: Status,
    };

    const config = Config{ .status = .active };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(config, output.writer(std.testing.allocator), .{});

    try std.testing.expectEqualStrings(
        "status active\n",
        output.items,
    );
}

test "encode float values" {
    const Config = struct {
        value: f64,
    };

    const config = Config{ .value = 3.14 };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(config, output.writer(std.testing.allocator), .{});

    // Float formatting may vary slightly
    try std.testing.expect(std.mem.startsWith(u8, output.items, "value 3.14"));
}

test "encode strings with escapes" {
    const Config = struct {
        message: []const u8,
    };

    const config = Config{ .message = "hello\nworld" };
    var output: std.ArrayListUnmanaged(u8) = .{};
    defer output.deinit(std.testing.allocator);

    try encode(config, output.writer(std.testing.allocator), .{});

    // String should be quoted and escaped
    try std.testing.expectEqualStrings(
        "message \"hello\\nworld\"\n",
        output.items,
    );
}
