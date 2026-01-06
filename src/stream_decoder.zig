/// KDL 2.0.0 Stream Decoder
///
/// Decode KDL directly into Zig structs using comptime introspection,
/// powered by `StreamIterator` for true streaming without DOM buffering.
///
/// This decoder processes KDL events as they arrive, avoiding the memory
/// overhead of building an intermediate document tree.
///
/// ## Thread Safety
///
/// Decoding is **NOT** thread-safe for a single output struct. Each decode
/// call maintains mutable iterator state. For concurrent parsing, use separate
/// output structs and source buffers.
///
/// ## Memory Ownership
///
/// When `copy_strings` is true (default), all strings are copied using the
/// provided allocator. When false, strings reference the iterator's internal
/// string pool—ensure the decoder outlives the struct or copy needed strings.
///
/// ## Struct Field Mapping
///
/// - Top-level nodes map to struct fields by name
/// - Node arguments map to `__args: []T` field (if present)
/// - Node properties map to struct fields by property key
/// - Child nodes map to nested struct fields or `__children: []T`
///
/// ## Usage
///
/// ```zig
/// const MyConfig = struct {
///     name: []const u8,
///     count: i32 = 0,
/// };
///
/// var config: MyConfig = .{};
/// try kdl.streamDecode(&config, allocator, source, .{});
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const stream_iterator_mod = @import("stream_iterator.zig");
const StreamIterator = stream_iterator_mod.StreamIterator;
const Event = stream_iterator_mod.Event;
const stream_types = @import("stream_types.zig");
const StringRef = stream_types.StringRef;
const StreamValue = stream_types.StreamValue;
const constants = @import("constants.zig");

/// Parse error types
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    DuplicateProperty,
    NestingTooDeep,
    OutOfMemory,
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
    EndOfStream,
    InputOutput,
};

/// Options for parsing behavior
pub const ParseOptions = struct {
    /// How to handle duplicate fields
    duplicate_field_behavior: enum { use_first, @"error", use_last } = .use_last,
    /// Whether to ignore unknown fields in structs
    ignore_unknown_fields: bool = true,
    /// Whether to always copy strings (true) or borrow from pool (false).
    /// Default true ensures safety; false allows zero-copy optimizations but requires
    /// the iterator to outlive the struct.
    copy_strings: bool = true,
    /// Maximum nesting depth for children blocks.
    /// Protects against stack exhaustion from deeply nested documents.
    max_depth: ?u16 = constants.DEFAULT_MAX_DEPTH,
};

/// Decode KDL source into a caller-owned value using streaming.
pub fn decode(
    out: anytype,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) ParseError!void {
    const T = @typeInfo(@TypeOf(out)).pointer.child;

    // Create stream from source
    var stream = std.io.fixedBufferStream(source);
    const ReaderType = @TypeOf(stream).Reader;

    var iter = StreamIterator(ReaderType).initWithOptions(
        allocator,
        stream.reader(),
        .{ .max_depth = options.max_depth },
    ) catch |err| return mapIterError(err);
    defer iter.deinit();

    var decoder = Decoder(ReaderType){
        .iter = &iter,
        .allocator = allocator,
        .options = options,
    };

    try decoder.parseInto(T, out);
}

fn mapIterError(err: stream_iterator_mod.Error) ParseError {
    return switch (err) {
        error.UnexpectedToken => ParseError.UnexpectedToken,
        error.UnexpectedEof => ParseError.UnexpectedEof,
        error.InvalidNumber => ParseError.InvalidNumber,
        error.InvalidString => ParseError.InvalidString,
        error.InvalidEscape => ParseError.InvalidEscape,
        error.NestingTooDeep => ParseError.NestingTooDeep,
        error.OutOfMemory => ParseError.OutOfMemory,
        error.EndOfStream => ParseError.EndOfStream,
        error.InputOutput => ParseError.InputOutput,
    };
}

/// Internal decoder state
fn Decoder(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        iter: *StreamIterator(ReaderType),
        allocator: Allocator,
        options: ParseOptions,
        current_event: ?Event = null,

        fn advance(self: *Self) ParseError!void {
            self.current_event = self.iter.next() catch |err| return mapIterError(err);
        }

        fn getString(self: *Self, ref: StringRef) []const u8 {
            return self.iter.getString(ref);
        }

        fn copyString(self: *Self, ref: StringRef) ParseError![]const u8 {
            const s = self.getString(ref);
            if (self.options.copy_strings) {
                return self.allocator.dupe(u8, s) catch return ParseError.OutOfMemory;
            }
            return s;
        }

        pub fn parseInto(self: *Self, comptime T: type, out: *T) ParseError!void {
            try self.advance(); // Prime with first event

            const info = @typeInfo(T);
            switch (info) {
                .@"struct" => try self.parseStruct(T, out),
                .pointer => |ptr| {
                    if (ptr.size == .slice) {
                        try self.parseNodesAsSlice(ptr.child, out);
                    } else {
                        return ParseError.TypeMismatch;
                    }
                },
                else => return ParseError.TypeMismatch,
            }
        }

        fn parseStruct(self: *Self, comptime T: type, out: *T) ParseError!void {
            const fields = std.meta.fields(T);
            var fields_set = [_]bool{false} ** fields.len;

            while (self.current_event) |event| {
                switch (event) {
                    .start_node => |node| {
                        const node_name = self.getString(node.name);

                        var found = false;
                        inline for (fields, 0..) |field, i| {
                            if (std.mem.eql(u8, node_name, field.name)) {
                                found = true;
                                if (fields_set[i]) {
                                    switch (self.options.duplicate_field_behavior) {
                                        .use_first => {
                                            try self.consumeNode();
                                            break;
                                        },
                                        .@"error" => return ParseError.DuplicateProperty,
                                        .use_last => {
                                            try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                                        },
                                    }
                                } else {
                                    try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                                    fields_set[i] = true;
                                }
                                break;
                            }
                        }

                        if (!found) {
                            if (!self.options.ignore_unknown_fields) {
                                return ParseError.UnknownField;
                            }
                            try self.consumeNode();
                        }
                    },
                    .end_node => {
                        // End of children block
                        try self.advance();
                        return;
                    },
                    else => {
                        try self.advance();
                    },
                }
            }
        }

        fn parseNodeBodyInto(self: *Self, comptime T: type, out: *T) ParseError!void {
            const info = @typeInfo(T);
            switch (info) {
                .@"struct" => try self.parseNodeAsStruct(T, out),
                .optional => |opt| {
                    const child_info = @typeInfo(opt.child);
                    switch (child_info) {
                        // For simple types, parse directly with optional type so assignValue handles null
                        .int, .float, .bool, .@"enum" => try self.parseSimpleValue(T, out),
                        .pointer => |ptr| {
                            if (ptr.size == .slice and ptr.child == u8) {
                                // String type - parse with optional type
                                try self.parseSimpleValue(T, out);
                            } else {
                                // Complex pointer type - unwrap and recurse
                                var temp: opt.child = undefined;
                                try self.parseNodeBodyInto(opt.child, &temp);
                                out.* = temp;
                            }
                        },
                        // For structs, unwrap and recurse
                        .@"struct" => {
                            var temp: opt.child = .{};
                            try self.parseNodeBodyInto(opt.child, &temp);
                            out.* = temp;
                        },
                        else => {
                            var temp: opt.child = undefined;
                            try self.parseNodeBodyInto(opt.child, &temp);
                            out.* = temp;
                        },
                    }
                },
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child != u8) {
                        var item: ptr.child = if (@typeInfo(ptr.child) == .@"struct") .{} else undefined;
                        try self.parseNodeBodyInto(ptr.child, &item);
                        try self.appendToSlice(ptr.child, out, item);
                    } else {
                        try self.parseSimpleValue(T, out);
                    }
                },
                .int, .float, .bool, .@"enum" => try self.parseSimpleValue(T, out),
                else => return ParseError.TypeMismatch,
            }
        }

        fn parseNodeAsStruct(self: *Self, comptime T: type, out: *T) ParseError!void {
            const fields = std.meta.fields(T);
            var fields_set = [_]bool{false} ** fields.len;

            try self.advance(); // Move past start_node

            while (self.current_event) |event| {
                switch (event) {
                    .argument => |arg| {
                        if (@hasField(T, "__args")) {
                            const ArgsFieldType = @TypeOf(@field(out, "__args"));
                            const ArgElemType = std.meta.Elem(ArgsFieldType);
                            var parsed_arg: ArgElemType = if (@typeInfo(ArgElemType) == .@"struct") .{} else std.mem.zeroes(ArgElemType);
                            try self.assignValue(ArgElemType, &parsed_arg, arg.value);
                            try self.appendToSlice(ArgElemType, &@field(out, "__args"), parsed_arg);
                        }
                        try self.advance();
                    },
                    .property => |prop| {
                        const key = self.getString(prop.name);

                        var found = false;
                        inline for (fields, 0..) |field, i| {
                            if (std.mem.eql(u8, key, field.name)) {
                                found = true;
                                if (fields_set[i]) {
                                    switch (self.options.duplicate_field_behavior) {
                                        .use_first => {},
                                        .@"error" => return ParseError.DuplicateProperty,
                                        .use_last => {
                                            try self.assignValue(field.type, &@field(out, field.name), prop.value);
                                        },
                                    }
                                } else {
                                    try self.assignValue(field.type, &@field(out, field.name), prop.value);
                                    fields_set[i] = true;
                                }
                                break;
                            }
                        }
                        if (!found and !self.options.ignore_unknown_fields) {
                            return ParseError.UnknownField;
                        }
                        try self.advance();
                    },
                    .start_node => |child_node| {
                        const child_name = self.getString(child_node.name);

                        var found = false;
                        inline for (fields, 0..) |field, i| {
                            if (std.mem.eql(u8, child_name, field.name)) {
                                found = true;
                                if (fields_set[i]) {
                                    switch (self.options.duplicate_field_behavior) {
                                        .use_first => {
                                            try self.consumeNode();
                                        },
                                        .@"error" => return ParseError.DuplicateProperty,
                                        .use_last => {
                                            try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                                        },
                                    }
                                } else {
                                    try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                                    fields_set[i] = true;
                                }
                                break;
                            }
                        }

                        if (!found) {
                            if (!self.options.ignore_unknown_fields) {
                                return ParseError.UnknownField;
                            }
                            try self.consumeNode();
                        }
                    },
                    .end_node => {
                        try self.advance();
                        return;
                    },
                }
            }
        }

        fn parseSimpleValue(self: *Self, comptime T: type, out: *T) ParseError!void {
            try self.advance(); // Move past start_node

            var assigned = false;

            while (self.current_event) |event| {
                switch (event) {
                    .argument => |arg| {
                        if (!assigned) {
                            try self.assignValue(T, out, arg.value);
                            assigned = true;
                        }
                        try self.advance();
                    },
                    .property => {
                        try self.advance();
                    },
                    .start_node => {
                        try self.consumeNode();
                    },
                    .end_node => {
                        try self.advance();
                        if (!assigned) return ParseError.MissingField;
                        return;
                    },
                }
            }

            if (!assigned) return ParseError.MissingField;
        }

        fn assignValue(self: *Self, comptime Target: type, out: *Target, val: StreamValue) ParseError!void {
            const info = @typeInfo(Target);
            switch (info) {
                .int => switch (val) {
                    .integer => |i| out.* = std.math.cast(Target, i) orelse return ParseError.TypeMismatch,
                    else => return ParseError.TypeMismatch,
                },
                .float => switch (val) {
                    .float => |f| out.* = @floatCast(f.value),
                    .integer => |i| out.* = @floatFromInt(i),
                    .positive_inf => out.* = std.math.inf(Target),
                    .negative_inf => out.* = -std.math.inf(Target),
                    .nan_value => out.* = std.math.nan(Target),
                    else => return ParseError.TypeMismatch,
                },
                .bool => switch (val) {
                    .boolean => |b| out.* = b,
                    else => return ParseError.TypeMismatch,
                },
                .pointer => |ptr| {
                    if (ptr.size == .slice and ptr.child == u8) {
                        switch (val) {
                            .string => |ref| {
                                out.* = try self.copyString(ref);
                            },
                            else => return ParseError.TypeMismatch,
                        }
                    } else {
                        return ParseError.TypeMismatch;
                    }
                },
                .optional => |opt| {
                    switch (val) {
                        .null_value => out.* = null,
                        else => {
                            var temp: opt.child = if (@typeInfo(opt.child) == .@"struct") .{} else std.mem.zeroes(opt.child);
                            try self.assignValue(opt.child, &temp, val);
                            out.* = temp;
                        },
                    }
                },
                .@"enum" => |e| {
                    switch (val) {
                        .string => |ref| {
                            const s = self.getString(ref);
                            inline for (e.fields) |field| {
                                if (std.mem.eql(u8, s, field.name)) {
                                    out.* = @enumFromInt(field.value);
                                    return;
                                }
                            }
                            return ParseError.InvalidEnumValue;
                        },
                        else => return ParseError.TypeMismatch,
                    }
                },
                else => return ParseError.TypeMismatch,
            }
        }

        fn appendToSlice(self: *Self, comptime Elem: type, slice_ptr: *[]Elem, item: Elem) ParseError!void {
            var list = std.ArrayListUnmanaged(Elem){
                .items = slice_ptr.*,
                .capacity = slice_ptr.*.len,
            };
            list.append(self.allocator, item) catch return ParseError.OutOfMemory;
            slice_ptr.* = list.items;
        }

        fn parseNodesAsSlice(self: *Self, comptime T: type, out: *[]T) ParseError!void {
            var list: std.ArrayListUnmanaged(T) = .{};

            while (self.current_event) |event| {
                switch (event) {
                    .start_node => {
                        var item: T = if (@typeInfo(T) == .@"struct") .{} else std.mem.zeroes(T);
                        try self.parseNodeBodyInto(T, &item);
                        list.append(self.allocator, item) catch return ParseError.OutOfMemory;
                    },
                    else => {
                        try self.advance();
                    },
                }
            }

            out.* = list.toOwnedSlice(self.allocator) catch return ParseError.OutOfMemory;
        }

        fn consumeNode(self: *Self) ParseError!void {
            var depth: usize = 1;

            try self.advance(); // Move past start_node

            while (self.current_event) |event| {
                switch (event) {
                    .start_node => {
                        depth += 1;
                        try self.advance();
                    },
                    .end_node => {
                        depth -= 1;
                        try self.advance();
                        if (depth == 0) return;
                    },
                    else => {
                        try self.advance();
                    },
                }
            }
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

test "stream decode simple struct" {
    const Config = struct {
        name: []const u8 = "",
        count: i32 = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Config = .{};
    try decode(&result, arena.allocator(),
        \\name "test"
        \\count 42
    , .{});

    try std.testing.expectEqualStrings("test", result.name);
    try std.testing.expectEqual(@as(i32, 42), result.count);
}

test "stream decode copies bare identifier strings" {
    const Config = struct {
        name: []const u8 = "",
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var source: [10]u8 = "name value".*;
    var result: Config = .{};
    try decode(&result, arena.allocator(), source[0..], .{});

    source[5] = 'X';
    try std.testing.expectEqualStrings("value", result.name);
}

test "stream decode float values" {
    const Config = struct {
        number: f64 = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Config = .{};
    try decode(&result, arena.allocator(),
        \\number 1.5e2
    , .{});

    try std.testing.expectApproxEqAbs(@as(f64, 150.0), result.number, 0.0001);
}

test "stream decode nested struct" {
    const Inner = struct {
        value: i32 = 0,
    };

    const Outer = struct {
        inner: ?Inner = null,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Outer = .{};
    try decode(&result, arena.allocator(),
        \\inner {
        \\    value 123
        \\}
    , .{});

    try std.testing.expectEqual(@as(i32, 123), result.inner.?.value);
}

test "stream decode with properties" {
    const Person = struct {
        name: []const u8 = "",
        age: i32 = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Person = .{};
    try decode(&result, arena.allocator(),
        \\name "Alice"
        \\age 30
    , .{});

    try std.testing.expectEqualStrings("Alice", result.name);
    try std.testing.expectEqual(@as(i32, 30), result.age);
}

test "stream decode optional fields" {
    const Config = struct {
        required: i32 = 0,
        optional: ?i32 = null,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Config = .{};
    try decode(&result, arena.allocator(),
        \\required 42
    , .{});

    try std.testing.expectEqual(@as(i32, 42), result.required);
    try std.testing.expectEqual(@as(?i32, null), result.optional);
}

test "stream decode array of nodes" {
    const Item = struct {
        __args: []i32 = &.{},
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: []Item = &[_]Item{};
    try decode(&result, arena.allocator(),
        \\item 1
        \\item 2
        \\item 3
    , .{});

    try std.testing.expectEqual(@as(usize, 3), result.len);
}

test "stream decode boolean values" {
    const Config = struct {
        enabled: bool = false,
        disabled: bool = true,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Config = .{};
    try decode(&result, arena.allocator(),
        \\enabled #true
        \\disabled #false
    , .{});

    try std.testing.expect(result.enabled);
    try std.testing.expect(!result.disabled);
}

test "stream decode enum values" {
    const Status = enum { active, inactive, pending };

    const Config = struct {
        status: Status = .pending,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Config = .{};
    try decode(&result, arena.allocator(),
        \\status active
    , .{});

    try std.testing.expectEqual(Status.active, result.status);
}

test "stream decode special floats" {
    const Config = struct {
        pos_inf: f64 = 0,
        neg_inf: f64 = 0,
        nan_val: f64 = 0,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Config = .{};
    try decode(&result, arena.allocator(),
        \\pos_inf #inf
        \\neg_inf #-inf
        \\nan_val #nan
    , .{});

    try std.testing.expect(std.math.isPositiveInf(result.pos_inf));
    try std.testing.expect(std.math.isNegativeInf(result.neg_inf));
    try std.testing.expect(std.math.isNan(result.nan_val));
}

test "stream decode null values" {
    const Config = struct {
        value: ?i32 = 42,
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var result: Config = .{};
    try decode(&result, arena.allocator(),
        \\value #null
    , .{});

    try std.testing.expectEqual(@as(?i32, null), result.value);
}
