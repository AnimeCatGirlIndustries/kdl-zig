/// KDL 2.0.0 Pull Parser (SAX-style)
///
/// Provides a streaming iterator of logical KDL events, similar to SAX-style XML parsing.
/// Events are emitted as nodes are encountered: `start_node`, `argument`, `property`, `end_node`.
///
/// ## Usage
/// ```zig
/// var parser = Parser.init(allocator, source);
/// while (try parser.next()) |event| {
///     switch (event) {
///         .start_node => |n| // Handle node start,
///         .argument => |a| // Handle argument,
///         .property => |p| // Handle property,
///         .end_node => // Handle node end,
///     }
/// }
/// ```
///
/// ## Thread Safety
///
/// Parser instances are **NOT** thread-safe. Each parser maintains mutable state
/// (tokenizer position, depth tracking) and must not be shared across threads.
///
/// ## Memory Ownership
///
/// **Critical:** Event data may contain slices that reference the source buffer:
/// - Identifiers (node names, property keys) are direct slices into the source
/// - Processed strings (quoted, raw, multiline) may be allocated or borrowed
///
/// The source buffer **must remain valid** for the lifetime of all event data
/// you retain. If you need strings to outlive the source, copy them explicitly.
///
/// When using `initReader()`, the parser owns the source buffer and frees it
/// on `deinit()`. Event data becomes invalid after `deinit()`.
///
/// ## Future: True Streaming
/// The current implementation buffers the entire source. Future versions may support
/// true streaming for sources larger than available memory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const tokenizer_mod = @import("tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const TokenType = tokenizer_mod.TokenType;
const strings = @import("strings.zig");
const numbers = @import("numbers.zig");

pub const Event = union(enum) {
    /// Start of a node. Contains the name and optional type annotation.
    start_node: struct {
        name: []const u8,
        type_annotation: ?[]const u8 = null,
    },
    /// End of a node.
    end_node,
    /// An argument associated with the current node.
    argument: types.TypedValue,
    /// A property associated with the current node.
    property: types.Property,
};

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    NestingTooDeep,
    OutOfMemory,
};

/// Options for parsing behavior.
pub const ParseOptions = struct {
    /// Maximum nesting depth for children blocks.
    /// Protects against stack overflow from deeply nested documents.
    /// Set to `null` for unlimited (use with caution).
    max_depth: ?u16 = 256,
};

/// Options for initializing a parser from a reader.
pub const ReaderOptions = struct {
    /// Maximum bytes to read from the source. Defaults to 256 MiB.
    /// Set to `null` for unlimited (use with caution - may exhaust memory).
    max_size: ?usize = 256 * 1024 * 1024,
};

/// A streaming parser that emits KDL events.
pub const Parser = struct {
    tokenizer: Tokenizer,
    allocator: Allocator,
    options: ParseOptions,
    // Stack to track depth for matching braces to nodes
    depth: u16 = 0,
    // Track if we are currently inside a node's header (before children/terminator)
    in_node: bool = false,
    // We need to store current token in struct because init() called next()
    tokenizer_current: Token,
    // Optional owned source buffer (for initReader)
    owned_source: ?[]const u8 = null,

    pub fn init(allocator: Allocator, source: []const u8) Parser {
        return initWithOptions(allocator, source, .{});
    }

    pub fn initWithOptions(allocator: Allocator, source: []const u8, options: ParseOptions) Parser {
        var tokenizer = Tokenizer.init(source);
        // Prime the tokenizer
        const first = tokenizer.next();
        return .{
            .tokenizer = tokenizer,
            .allocator = allocator,
            .options = options,
            .tokenizer_current = first,
        };
    }

    /// Initialize parser by reading all content from a reader.
    ///
    /// The source buffer is owned by the parser and freed on `deinit()`.
    ///
    /// **Options:**
    /// - `max_size`: Maximum bytes to read (default: 256 MiB, `null` for unlimited)
    ///
    /// **Note:** This buffers the entire source into memory. For sources larger than
    /// available memory, future versions will support true streaming.
    pub fn initReader(allocator: Allocator, reader: anytype, options: ReaderOptions) !Parser {
        return initReaderWithOptions(allocator, reader, options, .{});
    }

    /// Initialize parser from a reader with custom parse options.
    pub fn initReaderWithOptions(allocator: Allocator, reader: anytype, reader_options: ReaderOptions, parse_options: ParseOptions) !Parser {
        const max = reader_options.max_size orelse std.math.maxInt(usize);
        const source = try reader.readAllAlloc(allocator, max);
        var parser = initWithOptions(allocator, source, parse_options);
        parser.owned_source = source;
        return parser;
    }

    pub fn deinit(self: *Parser) void {
        if (self.owned_source) |s| {
            self.allocator.free(s);
        }
    }

    fn advance(self: *Parser) void {
        self.tokenizer_current = self.tokenizer.next();
    }

    /// Get the next event in the stream. Returns null at EOF.
    pub fn next(self: *Parser) Error!?Event {
        while (true) {
            const token = self.tokenizer_current;
            
            switch (token.type) {
                .eof => {
                    if (self.depth > 0) return Error.UnexpectedEof;
                    return null;
                },
                .newline, .semicolon => {
                    self.advance();
                    if (self.in_node) {
                        self.in_node = false;
                        return Event.end_node;
                    }
                    continue;
                },
                .slashdash => {
                    // Slashdash comments out the next node, arg, or prop
                    self.advance();
                    self.skipNodeSpace();
                    try self.consumeIgnored();
                    continue;
                },
                .close_brace => {
                    self.advance();
                    if (self.depth == 0) return Error.UnexpectedToken;
                    self.depth -= 1;
                    // Closing brace ends the parent node
                    // But if we were already "in_node" (header only), we would have ended it?
                    // No, `node {` -> `start_node`, then `children`...
                    // The `end_node` event corresponding to `node { }` happens after `}`.
                    return Event.end_node;
                },
                .open_brace => {
                    if (!self.in_node) return Error.UnexpectedToken; // { without node
                    // Check depth limit before descending
                    if (self.options.max_depth) |max| {
                        if (self.depth >= max) {
                            return Error.NestingTooDeep;
                        }
                    }
                    self.advance();
                    self.in_node = false; // We are entering children, so node header ends
                    self.depth += 1;
                    continue; // Loop to find first child
                },
                else => {
                    // Argument, Property, or Start of Node?
                    if (self.in_node) {
                        // We are in a node header. Expect args or props.
                        return try self.parseArgOrProp();
                    } else {
                        // Start of a new node
                        return try self.parseNodeStart();
                    }
                }
            }
        }
    }

    fn skipNodeSpace(self: *Parser) void {
        while (self.tokenizer_current.type == .newline) {
            self.advance();
        }
    }

    fn consumeIgnored(self: *Parser) Error!void {
        // Parse and discard next item (Node, Arg, Prop, ChildrenBlock)
        // If we are at { -> consume block
        if (self.tokenizer_current.type == .open_brace) {
            try self.consumeBlock();
            return;
        }
        
        // It could be a Node (if not in_node) or Arg/Prop (if in_node)
        // Actually slashdash logic:
        // /- node ... -> ignores node
        // /- arg -> ignores arg
        // /- prop=val -> ignores prop
        // /- { ... } -> ignores children block? Only if attached to node?
        
        // Simpler: assume it's an item.
        // If it starts with { -> block.
        // Else -> consume value/key. If key, consume value.
        // Then consume args/props/children if it looked like a node?
        // This is complex because "Ignored" depends on context.
        // BUT, slashdash works on "the next element".
        
        // If we are at top level (not in_node), next element is a Node.
        // If we are in_node, next element is Arg or Prop.
        
        if (self.in_node) {
            // Arg or Prop
            _ = try self.parseArgOrPropInternal(true);
        } else {
            // Node
            try self.consumeNode();
        }
    }

    fn consumeNode(self: *Parser) Error!void {
        // Consume name (and type annot)
        if (self.tokenizer_current.type == .open_paren) {
            _ = try self.parseTypeAnnotation(); // ignore result
        }
        _ = try self.parseStringValue(); // name

        // Consume args/props
        while (true) {
            const t = self.tokenizer_current.type;
            if (t == .newline or t == .semicolon or t == .eof or t == .close_brace) break;
            if (t == .open_brace) {
                try self.consumeBlock();
                break;
            }
            if (t == .slashdash) {
                self.advance();
                self.skipNodeSpace();
                try self.consumeIgnored(); // Recurse for args
                continue;
            }
            
            // Consume Arg/Prop
            _ = try self.parseArgOrPropInternal(true);
        }
    }

    fn consumeBlock(self: *Parser) Error!void {
        self.advance(); // {
        var depth: usize = 1;
        while (depth > 0) {
            const t = self.tokenizer_current.type;
            if (t == .eof) return Error.UnexpectedEof;
            if (t == .open_brace) depth += 1;
            if (t == .close_brace) depth -= 1;
            self.advance();
        }
    }

    fn parseNodeStart(self: *Parser) Error!Event {
        var type_annot: ?[]const u8 = null;
        if (self.tokenizer_current.type == .open_paren) {
            type_annot = try self.parseTypeAnnotation();
        }
        const name = try self.parseStringValue();
        self.in_node = true;
        return Event{ .start_node = .{ .name = name, .type_annotation = type_annot } };
    }

    fn parseArgOrProp(self: *Parser) Error!Event {
        return self.parseArgOrPropInternal(false);
    }

    fn parseArgOrPropInternal(self: *Parser, ignore: bool) Error!Event {
        var type_annot: ?[]const u8 = null;
        if (self.tokenizer_current.type == .open_paren) {
            type_annot = try self.parseTypeAnnotation();
        }

        const first_val = try self.parseValue();

        if (self.tokenizer_current.type == .equals) {
            // Property
            if (type_annot != null) return Error.UnexpectedToken;
            self.advance(); // =
            
            var val_annot: ?[]const u8 = null;
            if (self.tokenizer_current.type == .open_paren) {
                val_annot = try self.parseTypeAnnotation();
            }
            const val = try self.parseValue();

            if (ignore) return Event{ .end_node = {} }; // Dummy

            const key = switch (first_val) {
                .string => |s| s.raw,
                else => return Error.UnexpectedToken,
            };

            return Event{ .property = .{ .name = key, .value = val, .type_annotation = val_annot } };
        } else {
            // Argument
            if (ignore) return Event{ .end_node = {} }; // Dummy
            return Event{ .argument = .{ .value = first_val, .type_annotation = type_annot } };
        }
    }

    fn parseTypeAnnotation(self: *Parser) Error![]const u8 {
        self.advance(); // (
        const name = try self.parseStringValue();
        if (self.tokenizer_current.type != .close_paren) return Error.UnexpectedToken;
        self.advance(); // )
        return name;
    }

    fn parseStringValue(self: *Parser) Error![]const u8 {
        const t = self.tokenizer_current;
        self.advance();
        return switch (t.type) {
            .identifier => t.text,
            .quoted_string => strings.processQuotedString(self.allocator, t.text) catch |err| self.mapStringError(err),
            .raw_string => strings.processRawString(self.allocator, t.text) catch |err| self.mapStringError(err),
            .multiline_string => strings.processMultilineString(self.allocator, t.text) catch |err| self.mapStringError(err),
            else => Error.UnexpectedToken,
        };
    }

    fn parseValue(self: *Parser) Error!types.Value {
        const t = self.tokenizer_current;
        self.advance();
        return switch (t.type) {
            .identifier => types.Value{ .string = .{ .raw = t.text } },
            .quoted_string => types.Value{ .string = .{ .raw = strings.processQuotedString(self.allocator, t.text) catch |e| return self.mapStringError(e) } },
            .raw_string => types.Value{ .string = .{ .raw = strings.processRawString(self.allocator, t.text) catch |e| return self.mapStringError(e) } },
            .multiline_string => types.Value{ .string = .{ .raw = strings.processMultilineString(self.allocator, t.text) catch |e| return self.mapStringError(e) } },
            .integer => types.Value{ .integer = numbers.parseDecimalInteger(self.allocator, t.text) catch return Error.InvalidNumber },
            .float => types.Value{ .float = blk: {
                const res = numbers.parseFloat(self.allocator, t.text) catch return Error.InvalidNumber;
                break :blk .{ .value = res.value, .original = res.original };
            }},
            .hex_integer => types.Value{ .integer = numbers.parseRadixInteger(self.allocator, t.text, 2, 16) catch return Error.InvalidNumber },
            .octal_integer => types.Value{ .integer = numbers.parseRadixInteger(self.allocator, t.text, 2, 8) catch return Error.InvalidNumber },
            .binary_integer => types.Value{ .integer = numbers.parseRadixInteger(self.allocator, t.text, 2, 2) catch return Error.InvalidNumber },
            .keyword_true => types.Value{ .boolean = true },
            .keyword_false => types.Value{ .boolean = false },
            .keyword_null => types.Value{ .null_value = {} },
            .keyword_inf => types.Value{ .positive_inf = {} },
            .keyword_neg_inf => types.Value{ .negative_inf = {} },
            .keyword_nan => types.Value{ .nan_value = {} },
            else => Error.UnexpectedToken,
        };
    }
    
    fn mapStringError(self: *Parser, err: strings.Error) Error {
        _ = self;
        return switch (err) {
            error.InvalidString => Error.InvalidString,
            error.InvalidEscape => Error.InvalidEscape,
            error.OutOfMemory => Error.OutOfMemory,
        };
    }
};

// Tests
test "PullParser basic" {
    const src = "node 1 key=\"val\" { child; }";
    var parser = Parser.init(std.testing.allocator, src);
    
    const e1 = (try parser.next()).?;
    try std.testing.expectEqualStrings("node", e1.start_node.name);
    
    const e2 = (try parser.next()).?;
    try std.testing.expectEqual(@as(i128, 1), e2.argument.value.integer);
    
    const e3 = (try parser.next()).?;
    try std.testing.expectEqualStrings("key", e3.property.name);
    try std.testing.expectEqualStrings("val", e3.property.value.string.raw);
    
    const e4 = (try parser.next()).?;
    try std.testing.expectEqualStrings("child", e4.start_node.name);
    
    const e5 = (try parser.next()).?;
    try std.testing.expectEqual(Event.end_node, e5); // child end
    
    const e6 = (try parser.next()).?;
    try std.testing.expectEqual(Event.end_node, e6); // node end
    
    try std.testing.expect(try parser.next() == null);
}

test "PullParser initReader" {
    const src = "node 1";
    var fbs = std.io.fixedBufferStream(src);
    var parser = try Parser.initReader(std.testing.allocator, fbs.reader(), .{});
    defer parser.deinit();

    const e = (try parser.next()).?;
    try std.testing.expectEqualStrings("node", e.start_node.name);
}

test "PullParser initReader with custom max_size" {
    const src = "node 1";
    var fbs = std.io.fixedBufferStream(src);
    // Test with unlimited max_size
    var parser = try Parser.initReader(std.testing.allocator, fbs.reader(), .{ .max_size = null });
    defer parser.deinit();

    const e = (try parser.next()).?;
    try std.testing.expectEqualStrings("node", e.start_node.name);
}
