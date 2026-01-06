/// KDL 2.0.0 Stream Iterator (SAX-style)
///
/// True streaming parser that emits events without buffering the entire document.
/// Uses `StreamingTokenizer` for incremental tokenization and `value_builder`
/// for one-shot escape processing.
///
/// Unlike the DOM-building `StreamParser`, this iterator processes files
/// larger than available memory by yielding transient events.
///
/// ## Usage
/// ```zig
/// var iter = try StreamIterator.init(allocator, source);
/// defer iter.deinit();
///
/// while (try iter.next()) |event| {
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
/// Iterator instances are **NOT** thread-safe. Each iterator maintains mutable state
/// and must not be shared across threads. Create separate instances for concurrent parsing.
///
/// ## Memory Ownership
///
/// Events contain `StringRef` references into an internal `StringPool`.
/// The pool is owned by the iterator and freed on `deinit()`.
/// Copy strings if they need to outlive the iterator.
const std = @import("std");
const Allocator = std.mem.Allocator;
const stream_tokenizer = @import("stream_tokenizer.zig");
const StreamingTokenizer = stream_tokenizer.StreamingTokenizer;
const TokenType = stream_tokenizer.TokenType;
const StreamToken = stream_tokenizer.StreamToken;
const stream_types = @import("stream_types.zig");
const StringPool = stream_types.StringPool;
const StringRef = stream_types.StringRef;
const StreamValue = stream_types.StreamValue;
const value_builder = @import("value_builder.zig");
const numbers = @import("../util/numbers.zig");
const constants = @import("../util/constants.zig");

/// Events emitted by the stream iterator.
pub const Event = union(enum) {
    /// Start of a node. Contains name and optional type annotation.
    start_node: struct {
        name: StringRef,
        type_annotation: ?StringRef = null,
    },
    /// End of a node.
    end_node,
    /// An argument associated with the current node.
    argument: struct {
        value: StreamValue,
        type_annotation: ?StringRef = null,
    },
    /// A property associated with the current node.
    property: struct {
        name: StringRef,
        value: StreamValue,
        type_annotation: ?StringRef = null,
    },
};

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    NestingTooDeep,
    OutOfMemory,
    EndOfStream,
    InputOutput,
};

/// Options for parsing behavior.
pub const ParseOptions = struct {
    /// Maximum nesting depth for children blocks.
    /// Protects against stack exhaustion from deeply nested documents.
    /// Set to `null` for unlimited (use with caution).
    max_depth: ?u16 = constants.DEFAULT_MAX_DEPTH,
};

/// Stream iterator that emits KDL events from any reader.
pub fn StreamIterator(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        tokenizer: StreamingTokenizer(ReaderType),
        allocator: Allocator,
        options: ParseOptions,
        /// String pool for processed strings
        strings: StringPool,
        /// Stack to track depth for matching braces
        depth: u16 = 0,
        /// Track if we are inside a node's header (before children/terminator)
        in_node: bool = false,
        /// Current token (peeked ahead)
        current_token: ?StreamToken = null,

        pub fn init(allocator: Allocator, reader: ReaderType) Error!Self {
            return initWithOptions(allocator, reader, .{});
        }

        pub fn initWithOptions(allocator: Allocator, reader: ReaderType, options: ParseOptions) Error!Self {
            var tokenizer = StreamingTokenizer(ReaderType).init(allocator, reader, stream_tokenizer.DEFAULT_BUFFER_SIZE) catch return Error.OutOfMemory;
            errdefer tokenizer.deinit();

            // Prime the tokenizer
            const first_token = tokenizer.next() catch |err| return mapTokenizerError(err);

            const strings = StringPool.init(allocator) catch return Error.OutOfMemory;

            return Self{
                .tokenizer = tokenizer,
                .allocator = allocator,
                .options = options,
                .strings = strings,
                .current_token = first_token,
            };
        }

        pub fn deinit(self: *Self) void {
            self.strings.deinit();
            self.tokenizer.deinit();
        }

        fn mapTokenizerError(err: anyerror) Error {
            return switch (err) {
                error.OutOfMemory => Error.OutOfMemory,
                error.EndOfStream => Error.EndOfStream,
                else => Error.InputOutput,
            };
        }

        fn advance(self: *Self) Error!void {
            self.current_token = self.tokenizer.next() catch |err| return mapTokenizerError(err);
        }

        fn currentTokenType(self: *const Self) TokenType {
            if (self.current_token) |tok| {
                return tok.type;
            }
            return .eof;
        }

        fn getCurrentText(self: *const Self) []const u8 {
            if (self.current_token) |tok| {
                return self.tokenizer.getText(tok);
            }
            return "";
        }

        /// Get the next event in the stream. Returns null at EOF.
        pub fn next(self: *Self) Error!?Event {
            while (true) {
                const token_type = self.currentTokenType();

                switch (token_type) {
                    .eof => {
                        if (self.depth > 0) return Error.UnexpectedEof;
                        if (self.in_node) {
                            self.in_node = false;
                            return Event.end_node;
                        }
                        return null;
                    },
                    .newline, .semicolon => {
                        try self.advance();
                        if (self.in_node) {
                            self.in_node = false;
                            return Event.end_node;
                        }
                        continue;
                    },
                    .slashdash => {
                        try self.advance();
                        self.skipNodeSpace();
                        try self.consumeIgnored();
                        continue;
                    },
                    .close_brace => {
                        try self.advance();
                        if (self.depth == 0) return Error.UnexpectedToken;
                        self.depth -= 1;
                        return Event.end_node;
                    },
                    .open_brace => {
                        if (!self.in_node) return Error.UnexpectedToken;
                        if (self.options.max_depth) |max| {
                            if (self.depth >= max) {
                                return Error.NestingTooDeep;
                            }
                        }
                        try self.advance();
                        self.in_node = false;
                        self.depth += 1;
                        continue;
                    },
                    else => {
                        if (self.in_node) {
                            return try self.parseArgOrProp();
                        } else {
                            return try self.parseNodeStart();
                        }
                    },
                }
            }
        }

        fn skipNodeSpace(self: *Self) void {
            while (self.currentTokenType() == .newline) {
                self.advance() catch return;
            }
        }

        fn consumeIgnored(self: *Self) Error!void {
            // Slashdash comments out the next item
            if (self.currentTokenType() == .open_brace) {
                try self.consumeBlock();
                return;
            }

            if (self.in_node) {
                _ = try self.parseArgOrPropInternal(true);
            } else {
                try self.consumeNode();
            }
        }

        fn consumeNode(self: *Self) Error!void {
            // Consume type annotation if present
            if (self.currentTokenType() == .open_paren) {
                _ = try self.parseTypeAnnotation();
            }
            // Consume name
            _ = try self.parseStringValue();

            // Consume args/props
            while (true) {
                const t = self.currentTokenType();
                if (t == .newline or t == .semicolon or t == .eof or t == .close_brace) break;
                if (t == .open_brace) {
                    try self.consumeBlock();
                    break;
                }
                if (t == .slashdash) {
                    try self.advance();
                    self.skipNodeSpace();
                    try self.consumeIgnored();
                    continue;
                }
                _ = try self.parseArgOrPropInternal(true);
            }
        }

        fn consumeBlock(self: *Self) Error!void {
            try self.advance(); // {
            var block_depth: usize = 1;
            while (block_depth > 0) {
                const t = self.currentTokenType();
                if (t == .eof) return Error.UnexpectedEof;
                if (t == .open_brace) block_depth += 1;
                if (t == .close_brace) block_depth -= 1;
                try self.advance();
            }
        }

        fn parseNodeStart(self: *Self) Error!Event {
            var type_annot: ?StringRef = null;
            if (self.currentTokenType() == .open_paren) {
                type_annot = try self.parseTypeAnnotation();
            }
            const name = try self.parseStringValue();
            self.in_node = true;
            return Event{ .start_node = .{ .name = name, .type_annotation = type_annot } };
        }

        fn parseArgOrProp(self: *Self) Error!Event {
            return self.parseArgOrPropInternal(false);
        }

        fn parseArgOrPropInternal(self: *Self, ignore: bool) Error!Event {
            var type_annot: ?StringRef = null;
            if (self.currentTokenType() == .open_paren) {
                type_annot = try self.parseTypeAnnotation();
            }

            const first_val = try self.parseValue();

            if (self.currentTokenType() == .equals) {
                // Property
                if (type_annot != null) return Error.UnexpectedToken;
                try self.advance(); // =

                var val_annot: ?StringRef = null;
                if (self.currentTokenType() == .open_paren) {
                    val_annot = try self.parseTypeAnnotation();
                }
                const val = try self.parseValue();

                if (ignore) return Event.end_node; // Dummy

                const key = switch (first_val) {
                    .string => |s| s,
                    else => return Error.UnexpectedToken,
                };

                return Event{ .property = .{ .name = key, .value = val, .type_annotation = val_annot } };
            } else {
                // Argument
                if (ignore) return Event.end_node; // Dummy
                return Event{ .argument = .{ .value = first_val, .type_annotation = type_annot } };
            }
        }

        fn parseTypeAnnotation(self: *Self) Error!StringRef {
            try self.advance(); // (
            const name = try self.parseStringValue();
            if (self.currentTokenType() != .close_paren) return Error.UnexpectedToken;
            try self.advance(); // )
            return name;
        }

        fn parseStringValue(self: *Self) Error!StringRef {
            const text = self.getCurrentText();
            const token_type = self.currentTokenType();

            // IMPORTANT: Add to pool BEFORE advancing, as advance() invalidates text slice
            const result: StringRef = switch (token_type) {
                .identifier => self.strings.add(text) catch return Error.OutOfMemory,
                .quoted_string => value_builder.buildQuotedString(&self.strings, text) catch |err| return mapValueError(err),
                .raw_string => value_builder.buildRawString(&self.strings, text) catch |err| return mapValueError(err),
                .multiline_string => value_builder.buildMultilineString(&self.strings, text) catch |err| return mapValueError(err),
                else => return Error.UnexpectedToken,
            };

            try self.advance();
            return result;
        }

        fn parseValue(self: *Self) Error!StreamValue {
            const text = self.getCurrentText();
            const token_type = self.currentTokenType();

            // IMPORTANT: Parse value BEFORE advancing, as advance() invalidates text slice
            const result: StreamValue = switch (token_type) {
                .identifier => StreamValue{ .string = self.strings.add(text) catch return Error.OutOfMemory },
                .quoted_string => StreamValue{ .string = value_builder.buildQuotedString(&self.strings, text) catch |err| return mapValueError(err) },
                .raw_string => StreamValue{ .string = value_builder.buildRawString(&self.strings, text) catch |err| return mapValueError(err) },
                .multiline_string => StreamValue{ .string = value_builder.buildMultilineString(&self.strings, text) catch |err| return mapValueError(err) },
                .integer => StreamValue{ .integer = numbers.parseDecimalInteger(self.allocator, text) catch return Error.InvalidNumber },
                .float => blk: {
                    const res = numbers.parseFloat(self.allocator, text) catch return Error.InvalidNumber;
                    // Defer cleanup to end of blk scope
                    defer if (res.original) |orig| self.allocator.free(orig);
                    
                    const orig_text = res.original orelse text;
                    const ref = self.strings.add(orig_text) catch return Error.OutOfMemory;
                    break :blk StreamValue{ .float = .{ .value = res.value, .original = ref } };
                },
                .hex_integer => StreamValue{ .integer = numbers.parseRadixInteger(self.allocator, text, 2, 16) catch return Error.InvalidNumber },
                .octal_integer => StreamValue{ .integer = numbers.parseRadixInteger(self.allocator, text, 2, 8) catch return Error.InvalidNumber },
                .binary_integer => StreamValue{ .integer = numbers.parseRadixInteger(self.allocator, text, 2, 2) catch return Error.InvalidNumber },
                .keyword_true => StreamValue{ .boolean = true },
                .keyword_false => StreamValue{ .boolean = false },
                .keyword_null => StreamValue{ .null_value = {} },
                .keyword_inf => StreamValue{ .positive_inf = {} },
                .keyword_neg_inf => StreamValue{ .negative_inf = {} },
                .keyword_nan => StreamValue{ .nan_value = {} },
                else => return Error.UnexpectedToken,
            };

            try self.advance();
            return result;
        }

        fn mapValueError(err: value_builder.Error) Error {
            return switch (err) {
                error.InvalidString => Error.InvalidString,
                error.InvalidEscape => Error.InvalidEscape,
                error.OutOfMemory => Error.OutOfMemory,
            };
        }

        /// Get string content from a StringRef.
        pub fn getString(self: *const Self, ref: StringRef) []const u8 {
            return self.strings.get(ref);
        }
    };
}

/// Create a stream iterator from a slice (for convenience).
pub fn streamIterator(allocator: Allocator, source: []const u8) Error!StreamIterator(std.io.FixedBufferStream([]const u8).Reader) {
    var stream = std.io.fixedBufferStream(source);
    return StreamIterator(std.io.FixedBufferStream([]const u8).Reader).init(allocator, stream.reader());
}

/// Create a stream iterator from any reader.
pub fn streamIteratorReader(comptime ReaderType: type, allocator: Allocator, reader: ReaderType) Error!StreamIterator(ReaderType) {
    return StreamIterator(ReaderType).init(allocator, reader);
}

// ============================================================================
// Tests
// ============================================================================

test "StreamIterator basic node" {
    const source = "node";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    const e1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("node", iter.getString(e1.start_node.name));

    const e2 = (try iter.next()).?;
    try std.testing.expectEqual(Event.end_node, e2);

    try std.testing.expect(try iter.next() == null);
}

test "StreamIterator node with integer argument" {
    const source = "node 42";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    const e1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("node", iter.getString(e1.start_node.name));

    const e2 = (try iter.next()).?;
    try std.testing.expectEqual(@as(i128, 42), e2.argument.value.integer);

    const e3 = (try iter.next()).?;
    try std.testing.expectEqual(Event.end_node, e3);
}

test "StreamIterator node with string argument" {
    const source = "node \"hello\"";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expectEqualStrings("hello", iter.getString(e2.argument.value.string));
}

test "StreamIterator node with property" {
    const source = "node key=\"value\"";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expectEqualStrings("key", iter.getString(e2.property.name));
    try std.testing.expectEqualStrings("value", iter.getString(e2.property.value.string));
}

test "StreamIterator nested children" {
    const source = "parent { child; }";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    const e1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("parent", iter.getString(e1.start_node.name));

    const e2 = (try iter.next()).?;
    try std.testing.expectEqualStrings("child", iter.getString(e2.start_node.name));

    const e3 = (try iter.next()).?;
    try std.testing.expectEqual(Event.end_node, e3); // child end

    const e4 = (try iter.next()).?;
    try std.testing.expectEqual(Event.end_node, e4); // parent end

    try std.testing.expect(try iter.next() == null);
}

test "StreamIterator type annotation" {
    const source = "(mytype)node";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    const e1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("node", iter.getString(e1.start_node.name));
    try std.testing.expectEqualStrings("mytype", iter.getString(e1.start_node.type_annotation.?));
}

test "StreamIterator slashdash node" {
    const source = "/-ignored\nvisible";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    const e1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("visible", iter.getString(e1.start_node.name));
}

test "StreamIterator slashdash argument" {
    const source = "node /-ignored 42";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expectEqual(@as(i128, 42), e2.argument.value.integer);
}

test "StreamIterator keywords" {
    const source = "node #true #false #null";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expect(e2.argument.value.boolean == true);

    const e3 = (try iter.next()).?;
    try std.testing.expect(e3.argument.value.boolean == false);

    const e4 = (try iter.next()).?;
    try std.testing.expectEqual(StreamValue{ .null_value = {} }, e4.argument.value);
}

test "StreamIterator number types" {
    const source = "node 42 3.14 0xff 0o77 0b1010";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e1 = (try iter.next()).?;
    try std.testing.expectEqual(@as(i128, 42), e1.argument.value.integer);

    const e2 = (try iter.next()).?;
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), e2.argument.value.float.value, 0.001);

    const e3 = (try iter.next()).?;
    try std.testing.expectEqual(@as(i128, 0xff), e3.argument.value.integer);

    const e4 = (try iter.next()).?;
    try std.testing.expectEqual(@as(i128, 0o77), e4.argument.value.integer);

    const e5 = (try iter.next()).?;
    try std.testing.expectEqual(@as(i128, 0b1010), e5.argument.value.integer);
}

test "StreamIterator escape sequences" {
    const source = "node \"hello\\nworld\"";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expectEqualStrings("hello\nworld", iter.getString(e2.argument.value.string));
}

test "StreamIterator multiple nodes" {
    const source = "node1\nnode2\nnode3";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    const e1 = (try iter.next()).?;
    try std.testing.expectEqualStrings("node1", iter.getString(e1.start_node.name));
    _ = try iter.next(); // end_node

    const e3 = (try iter.next()).?;
    try std.testing.expectEqualStrings("node2", iter.getString(e3.start_node.name));
    _ = try iter.next(); // end_node

    const e5 = (try iter.next()).?;
    try std.testing.expectEqualStrings("node3", iter.getString(e5.start_node.name));
}

test "StreamIterator depth limit" {
    const source = "a { b { c { d { e { f { } } } } } }";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).initWithOptions(
        std.testing.allocator,
        stream.reader(),
        .{ .max_depth = 3 },
    );
    defer iter.deinit();

    // depth starts at 0
    _ = try iter.next(); // a start, then processes { -> depth=1
    _ = try iter.next(); // b start, then processes { -> depth=2
    _ = try iter.next(); // c start, then processes { -> depth=3
    _ = try iter.next(); // d start

    // Next call will try to process { with depth=3, which should fail
    const result = iter.next();
    try std.testing.expectError(Error.NestingTooDeep, result);
}

test "StreamIterator inf and nan" {
    const source = "node #inf #-inf #nan";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e1 = (try iter.next()).?;
    try std.testing.expectEqual(StreamValue{ .positive_inf = {} }, e1.argument.value);

    const e2 = (try iter.next()).?;
    try std.testing.expectEqual(StreamValue{ .negative_inf = {} }, e2.argument.value);

    const e3 = (try iter.next()).?;
    try std.testing.expectEqual(StreamValue{ .nan_value = {} }, e3.argument.value);
}

test "StreamIterator raw string" {
    const source = "node #\"raw string\"#";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expectEqualStrings("raw string", iter.getString(e2.argument.value.string));
}

test "StreamIterator property type annotation" {
    const source = "node key=(mytype)\"value\"";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expectEqualStrings("key", iter.getString(e2.property.name));
    try std.testing.expectEqualStrings("value", iter.getString(e2.property.value.string));
    try std.testing.expectEqualStrings("mytype", iter.getString(e2.property.type_annotation.?));
}

test "StreamIterator argument type annotation" {
    const source = "node (mytype)42";
    var stream = std.io.fixedBufferStream(source);
    var iter = try StreamIterator(@TypeOf(stream).Reader).init(std.testing.allocator, stream.reader());
    defer iter.deinit();

    _ = try iter.next(); // start_node

    const e2 = (try iter.next()).?;
    try std.testing.expectEqual(@as(i128, 42), e2.argument.value.integer);
    try std.testing.expectEqualStrings("mytype", iter.getString(e2.argument.type_annotation.?));
}
