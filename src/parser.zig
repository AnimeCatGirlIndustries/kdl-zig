/// KDL 2.0.0 DOM Parser
///
/// Parses tokenized KDL into an AST (Document with Nodes).
///
/// ## Thread Safety
///
/// Parser instances are **NOT** thread-safe. Each parser maintains mutable state
/// (tokenizer position, current token, arena allocator) and must not be shared
/// across threads. Create separate Parser instances for concurrent parsing.
///
/// ## Memory Ownership
///
/// The parser uses an arena allocator for all AST allocations. When `copy_strings`
/// is true (default), all strings are copied into the arena, ensuring the Document
/// can outlive the source buffer. When false, identifiers and raw strings may
/// reference the source buffer directly—the source must remain valid for the
/// Document's lifetime.
const std = @import("std");
const Allocator = std.mem.Allocator;
const tokenizer_mod = @import("tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const TokenType = tokenizer_mod.TokenType;
const types = @import("types.zig");
const Value = types.Value;
const TypedValue = types.TypedValue;
const Property = types.Property;
const Node = types.Node;
const Document = types.Document;
const unicode = @import("unicode.zig");
const strings = @import("strings.zig");
const numbers = @import("numbers.zig");

/// Parse error with location information
pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    DuplicateProperty,
    NestingTooDeep,
    OutOfMemory,
};

/// Parser options
pub const ParseOptions = struct {
    /// When true, all strings are copied into the arena for owned lifetimes.
    /// When false, identifiers and raw strings may reference the input buffer.
    /// Set to false only when the source buffer will outlive the Document.
    copy_strings: bool = true,

    /// Maximum nesting depth for children blocks.
    /// Protects against stack overflow from deeply nested documents.
    /// Set to `null` for unlimited (use with caution).
    max_depth: ?u16 = 256,
};

/// Detailed parse error info
pub const ParseErrorInfo = struct {
    message: []const u8,
    line: u32,
    column: u32,
};

/// Parser state
pub const Parser = struct {
    tokenizer: Tokenizer,
    current: Token,
    allocator: Allocator,
    arena: *std.heap.ArenaAllocator,
    options: ParseOptions,
    error_info: ?ParseErrorInfo = null,
    depth: u16 = 0,

    /// Initialize parser with source and arena
    pub fn init(
        allocator: Allocator,
        source: []const u8,
        arena: *std.heap.ArenaAllocator,
        options: ParseOptions,
    ) Parser {
        var tokenizer = Tokenizer.init(source);
        const first_token = tokenizer.next();
        return .{
            .tokenizer = tokenizer,
            .current = first_token,
            .allocator = allocator,
            .arena = arena,
            .options = options,
        };
    }

    fn advance(self: *Parser) void {
        self.current = self.tokenizer.next();
    }

    fn ensureOwnedString(self: *Parser, text: []const u8) Error![]const u8 {
        if (!self.options.copy_strings) return text;
        if (text.len == 0) return "";

        const source = self.tokenizer.source;
        const source_start = @intFromPtr(source.ptr);
        const source_end = source_start + source.len;
        const text_start = @intFromPtr(text.ptr);
        const text_end = text_start + text.len;

        if (text_start >= source_start and text_end <= source_end) {
            const alloc = self.arena.allocator();
            return alloc.dupe(u8, text) catch return Error.OutOfMemory;
        }

        return text;
    }

    /// Skip node-space: whitespace, newlines, and comments.
    /// Used after slashdash to find the element being commented out.
    fn skipNodeSpace(self: *Parser) void {
        while (self.current.type == .newline) {
            self.advance();
        }
        // Tokenizer already skips whitespace and comments between tokens
    }

    fn parseNode(self: *Parser) Error!Node {
        const alloc = self.arena.allocator();

        // Optional type annotation
        var type_annotation: ?[]const u8 = null;
        if (self.current.type == .open_paren) {
            type_annotation = try self.parseTypeAnnotation();
        }

        // Node name (must be a string-like token)
        const name = try self.parseNodeName();

        // Collect arguments and properties
        var arguments: std.ArrayListUnmanaged(TypedValue) = .{};
        var properties: std.ArrayListUnmanaged(Property) = .{};
        var children: []Node = &.{};
        var seen_children: bool = false;

        // Parse node body (arguments, properties, children)
        while (true) {
            // Skip to next meaningful token
            if (self.current.type == .newline or
                self.current.type == .semicolon or
                self.current.type == .eof or
                self.current.type == .close_brace)
            {
                break;
            }

            // Slashdash comments out next element
            if (self.current.type == .slashdash) {
                self.advance();
                self.skipNodeSpace(); // Skip newlines/whitespace/comments
                // Parse and discard the next element
                if (self.current.type == .open_brace) {
                    _ = try self.parseChildren();
                    seen_children = true;
                } else {
                    // Entries after any children block is an error
                    if (seen_children) {
                        self.error_info = .{
                            .message = "Entries not allowed after children block",
                            .line = self.current.line,
                            .column = self.current.column,
                        };
                        return Error.UnexpectedToken;
                    }
                    _ = try self.parseArgOrProp();
                }
                continue;
            }

            // Children block
            if (self.current.type == .open_brace) {
                // Only one non-slashdashed children block allowed
                if (children.len > 0) {
                    self.error_info = .{
                        .message = "Only one children block allowed per node",
                        .line = self.current.line,
                        .column = self.current.column,
                    };
                    return Error.UnexpectedToken;
                }
                children = try self.parseChildren();
                seen_children = true;
                continue; // Allow more slashdashed children blocks
            }

            // Argument or property - but not after children block
            if (seen_children) {
                self.error_info = .{
                    .message = "Entries not allowed after children block",
                    .line = self.current.line,
                    .column = self.current.column,
                };
                return Error.UnexpectedToken;
            }

            // VALIDATION: Arguments and properties must be preceded by whitespace
            if (!self.current.preceded_by_whitespace) {
                self.error_info = .{
                    .message = "Whitespace required before argument or property",
                    .line = self.current.line,
                    .column = self.current.column,
                };
                return Error.UnexpectedToken;
            }

            const arg_or_prop = try self.parseArgOrProp();
            switch (arg_or_prop) {
                .argument => |arg| try arguments.append(alloc, arg),
                .property => |prop| {
                    // Handle duplicate properties (rightmost wins)
                    var found = false;
                    for (properties.items, 0..) |existing, i| {
                        if (std.mem.eql(u8, existing.name, prop.name)) {
                            properties.items[i] = prop;
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        try properties.append(alloc, prop);
                    }
                },
            }
        }

        return Node{
            .name = name,
            .type_annotation = type_annotation,
            .arguments = try arguments.toOwnedSlice(alloc),
            .properties = try properties.toOwnedSlice(alloc),
            .children = children,
        };
    }

    fn parseTypeAnnotation(self: *Parser) Error![]const u8 {
        // Skip (
        self.advance();

        // Get type name
        const type_name = try self.parseStringValue();

        // Expect )
        if (self.current.type != .close_paren) {
            self.error_info = .{
                .message = "Expected ')' after type annotation",
                .line = self.current.line,
                .column = self.current.column,
            };
            return Error.UnexpectedToken;
        }
        self.advance();

        return type_name;
    }

    fn parseNodeName(self: *Parser) Error![]const u8 {
        return self.parseStringValue();
    }

    const ArgOrProp = union(enum) {
        argument: TypedValue,
        property: Property,
    };

    fn parseArgOrProp(self: *Parser) Error!ArgOrProp {
        // Check for type annotation
        var type_annotation: ?[]const u8 = null;
        if (self.current.type == .open_paren) {
            type_annotation = try self.parseTypeAnnotation();
        }

        // Get the value or property name
        const first_token = self.current;
        const first_value = try self.parseValue();

        // Check if this is a property (followed by =)
        if (self.current.type == .equals) {
            // Type annotation before property key is invalid (must be on value)
            if (type_annotation != null) {
                self.error_info = .{
                    .message = "Type annotation not allowed before property key",
                    .line = first_token.line,
                    .column = first_token.column,
                };
                return Error.UnexpectedToken;
            }

            self.advance();

            // Property value may have its own type annotation
            var prop_type_annotation: ?[]const u8 = null;
            if (self.current.type == .open_paren) {
                prop_type_annotation = try self.parseTypeAnnotation();
            }

            const prop_value = try self.parseValue();

            // Property name must be a string
            const prop_name = switch (first_value) {
                .string => |s| s.raw,
                else => {
                    self.error_info = .{
                        .message = "Property name must be a string",
                        .line = first_token.line,
                        .column = first_token.column,
                    };
                    return Error.UnexpectedToken;
                },
            };

            return .{ .property = Property{
                .name = prop_name,
                .value = prop_value,
                .type_annotation = prop_type_annotation,
            } };
        }

        // It's an argument
        return .{ .argument = TypedValue{
            .value = first_value,
            .type_annotation = type_annotation,
        } };
    }

    fn parseValue(self: *Parser) Error!Value {
        const token = self.current;
        self.advance();

        return switch (token.type) {
            .identifier => Value{ .string = .{ .raw = try self.ensureOwnedString(token.text) } },
            .quoted_string => Value{ .string = .{ .raw = try self.ensureOwnedString(try self.processQuotedString(token.text)) } },
            .raw_string => Value{ .string = .{ .raw = try self.ensureOwnedString(try self.processRawString(token.text)) } },
            .multiline_string => Value{ .string = .{ .raw = try self.ensureOwnedString(try self.processMultilineString(token.text)) } },
            .integer => Value{ .integer = try self.parseInteger(token.text) },
            .float => Value{ .float = try self.parseFloat(token.text) },
            .hex_integer => Value{ .integer = try self.parseHexInteger(token.text) },
            .octal_integer => Value{ .integer = try self.parseOctalInteger(token.text) },
            .binary_integer => Value{ .integer = try self.parseBinaryInteger(token.text) },
            .keyword_true => Value{ .boolean = true },
            .keyword_false => Value{ .boolean = false },
            .keyword_null => Value{ .null_value = {} },
            .keyword_inf => Value{ .positive_inf = {} },
            .keyword_neg_inf => Value{ .negative_inf = {} },
            .keyword_nan => Value{ .nan_value = {} },
            else => {
                self.error_info = .{
                    .message = "Expected value",
                    .line = token.line,
                    .column = token.column,
                };
                return Error.UnexpectedToken;
            },
        };
    }

    fn parseStringValue(self: *Parser) Error![]const u8 {
        const token = self.current;
        self.advance();

        return switch (token.type) {
            .identifier => try self.ensureOwnedString(token.text),
            .quoted_string => try self.ensureOwnedString(try self.processQuotedString(token.text)),
            .raw_string => try self.ensureOwnedString(try self.processRawString(token.text)),
            .multiline_string => try self.ensureOwnedString(try self.processMultilineString(token.text)),
            else => {
                self.error_info = .{
                    .message = "Expected string",
                    .line = token.line,
                    .column = token.column,
                };
                return Error.UnexpectedToken;
            },
        };
    }

    fn parseChildren(self: *Parser) Error![]Node {
        // Check depth limit before descending
        if (self.options.max_depth) |max| {
            if (self.depth >= max) {
                self.error_info = .{
                    .message = "Maximum nesting depth exceeded",
                    .line = self.current.line,
                    .column = self.current.column,
                };
                return Error.NestingTooDeep;
            }
        }
        self.depth += 1;
        defer self.depth -= 1;

        const alloc = self.arena.allocator();
        var children: std.ArrayListUnmanaged(Node) = .{};

        // Skip {
        self.advance();

        while (self.current.type != .close_brace and self.current.type != .eof) {
            // Skip newlines and semicolons
            if (self.current.type == .newline or self.current.type == .semicolon) {
                self.advance();
                continue;
            }

            // Handle slashdash
            if (self.current.type == .slashdash) {
                self.advance();
                self.skipNodeSpace(); // Skip newlines/whitespace/comments
                _ = try self.parseNode();
                continue;
            }

            const node = try self.parseNode();
            try children.append(alloc, node);
        }

        if (self.current.type != .close_brace) {
            self.error_info = .{
                .message = "Expected '}' to close children block",
                .line = self.current.line,
                .column = self.current.column,
            };
            return Error.UnexpectedEof;
        }
        self.advance();

        return try children.toOwnedSlice(alloc);
    }

    fn mapStringError(self: *Parser, err: strings.Error) Error {
        _ = self;
        return switch (err) {
            error.InvalidString => Error.InvalidString,
            error.InvalidEscape => Error.InvalidEscape,
            error.OutOfMemory => Error.OutOfMemory,
        };
    }

    // --- String processing (delegated to strings module) ---

    fn processQuotedString(self: *Parser, text: []const u8) Error![]const u8 {
        const alloc = self.arena.allocator();
        return strings.processQuotedString(alloc, text) catch |err| self.mapStringError(err);
    }

    fn processRawString(self: *Parser, text: []const u8) Error![]const u8 {
        const alloc = self.arena.allocator();
        return strings.processRawString(alloc, text) catch |err| self.mapStringError(err);
    }

    fn processMultilineString(self: *Parser, text: []const u8) Error![]const u8 {
        const alloc = self.arena.allocator();
        return strings.processMultilineString(alloc, text) catch |err| self.mapStringError(err);
    }

    // --- Number parsing (delegated to numbers module) ---

    fn parseInteger(self: *Parser, text: []const u8) Error!i128 {
        const alloc = self.arena.allocator();
        return numbers.parseDecimalInteger(alloc, text) catch return Error.InvalidNumber;
    }

    fn parseFloat(self: *Parser, text: []const u8) Error!Value.FloatValue {
        const alloc = self.arena.allocator();
        const result = numbers.parseFloat(alloc, text) catch return Error.InvalidNumber;
        return .{ .value = result.value, .original = result.original };
    }

    fn parseHexInteger(self: *Parser, text: []const u8) Error!i128 {
        const alloc = self.arena.allocator();
        return numbers.parseRadixInteger(alloc, text, 2, 16) catch return Error.InvalidNumber;
    }

    fn parseOctalInteger(self: *Parser, text: []const u8) Error!i128 {
        const alloc = self.arena.allocator();
        return numbers.parseRadixInteger(alloc, text, 2, 8) catch return Error.InvalidNumber;
    }

    fn parseBinaryInteger(self: *Parser, text: []const u8) Error!i128 {
        const alloc = self.arena.allocator();
        return numbers.parseRadixInteger(alloc, text, 2, 2) catch return Error.InvalidNumber;
    }
};

/// Parse a KDL document from source
pub fn parse(allocator: Allocator, source: []const u8) Error!Document {
    return parseWithOptions(allocator, source, .{});
}

/// Parse a KDL document from source with options
pub fn parseWithOptions(allocator: Allocator, source: []const u8, options: ParseOptions) Error!Document {
    // Create arena on heap so Document can own it
    const arena = allocator.create(std.heap.ArenaAllocator) catch return Error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    var parser = Parser.init(allocator, source, arena, options);

    var nodes: std.ArrayListUnmanaged(Node) = .{};
    const alloc = arena.allocator();

    while (parser.current.type != .eof) {
        if (parser.current.type == .newline or parser.current.type == .semicolon) {
            parser.advance();
            continue;
        }

        if (parser.current.type == .slashdash) {
            parser.advance();
            parser.skipNodeSpace(); // Skip newlines/whitespace/comments
            _ = try parser.parseNode();
            continue;
        }

        const node = try parser.parseNode();
        try nodes.append(alloc, node);
    }

    return Document{
        .nodes = try nodes.toOwnedSlice(alloc),
        .allocator = alloc,
        .arena = arena,
    };
}

// Tests

test "parse empty document" {
    const doc = try parse(std.testing.allocator, "");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.nodes.len);
}

test "parse simple node" {
    const doc = try parse(std.testing.allocator, "node");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqualStrings("node", doc.nodes[0].name);
}

test "parse copies identifiers by default" {
    var source: [4]u8 = "node".*;
    const doc = try parse(std.testing.allocator, source[0..]);
    defer @constCast(&doc).deinit();
    source[0] = 'X';
    try std.testing.expectEqualStrings("node", doc.nodes[0].name);
}

test "parseWithOptions can reference input when copy_strings is false" {
    var source: [4]u8 = "node".*;
    const doc = try parseWithOptions(std.testing.allocator, source[0..], .{ .copy_strings = false });
    defer @constCast(&doc).deinit();
    source[0] = 'X';
    try std.testing.expectEqualStrings("Xode", doc.nodes[0].name);
}

test "parse node with argument" {
    const doc = try parse(std.testing.allocator, "node 42");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), doc.nodes[0].arguments.len);
    try std.testing.expectEqual(@as(i128, 42), doc.nodes[0].arguments[0].value.integer);
}

test "parse node with string argument" {
    const doc = try parse(std.testing.allocator,
        \\node "hello"
    );
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), doc.nodes[0].arguments.len);
    try std.testing.expectEqualStrings("hello", doc.nodes[0].arguments[0].value.string.raw);
}

test "parse node with property" {
    const doc = try parse(std.testing.allocator, "node key=42");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), doc.nodes[0].properties.len);
    try std.testing.expectEqualStrings("key", doc.nodes[0].properties[0].name);
    try std.testing.expectEqual(@as(i128, 42), doc.nodes[0].properties[0].value.integer);
}

test "parse node with children" {
    const doc = try parse(std.testing.allocator,
        \\parent {
        \\    child
        \\}
    );
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), doc.nodes[0].children.len);
    try std.testing.expectEqualStrings("child", doc.nodes[0].children[0].name);
}

test "parse keywords" {
    const doc = try parse(std.testing.allocator, "node #true #false #null");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.nodes[0].arguments.len);
    try std.testing.expect(doc.nodes[0].arguments[0].value.boolean == true);
    try std.testing.expect(doc.nodes[0].arguments[1].value.boolean == false);
    try std.testing.expectEqual(Value.null_value, doc.nodes[0].arguments[2].value);
}

test "parse type annotation" {
    const doc = try parse(std.testing.allocator, "(mytype)node");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqualStrings("mytype", doc.nodes[0].type_annotation.?);
}

test "parse slashdash node" {
    const doc = try parse(std.testing.allocator,
        \\/-commented
        \\visible
    );
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqualStrings("visible", doc.nodes[0].name);
}

test "parse slashdash argument" {
    const doc = try parse(std.testing.allocator, "node /-1 2 3");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.nodes[0].arguments.len);
    try std.testing.expectEqual(@as(i128, 2), doc.nodes[0].arguments[0].value.integer);
    try std.testing.expectEqual(@as(i128, 3), doc.nodes[0].arguments[1].value.integer);
}

test "parse hex integer" {
    const doc = try parse(std.testing.allocator, "node 0xFF");
    defer @constCast(&doc).deinit();
    try std.testing.expectEqual(@as(i128, 255), doc.nodes[0].arguments[0].value.integer);
}

test "parse escape sequences" {
    const doc = try parse(std.testing.allocator,
        \\node "hello\nworld"
    );
    defer @constCast(&doc).deinit();
    try std.testing.expectEqualStrings("hello\nworld", doc.nodes[0].arguments[0].value.string.raw);
}
