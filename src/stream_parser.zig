/// Thread-Safe Streaming Parser for KDL 2.0.0
///
/// Parses KDL documents into the SoA-based StreamDocument IR.
/// Supports parallel graph construction through pool partitioning:
/// - Each thread gets its own pools (no contention)
/// - Parse subtrees independently
/// - Lock-free merge by concatenating pools and adjusting handle offsets
///
/// ## Thread Safety
///
/// `StreamParser` instances are **NOT** thread-safe. Each parser maintains mutable
/// state and must not be shared across threads. For concurrent parsing:
///
/// 1. Create separate `StreamParser` and `StreamDocument` instances per thread
/// 2. Use `findNodeBoundaries()` to partition input for parallel parsing
/// 3. Use `mergeDocuments()` to combine results after all threads complete
///
/// ## Usage Example (Single-Threaded)
///
/// ```zig
/// const kdl = @import("kdl");
///
/// var doc = try kdl.streamParse(allocator, "node \"value\"");
/// defer doc.deinit();
///
/// var roots = doc.rootIterator();
/// while (roots.next()) |node| {
///     const name = doc.getString(doc.nodes.getName(node));
///     // Process node...
/// }
/// ```
///
/// ## Usage Example (Parallel Parsing)
///
/// ```zig
/// const kdl = @import("kdl");
///
/// // Find partition boundaries (top-level node start positions)
/// const boundaries = try kdl.findNodeBoundaries(allocator, source, 4);
/// defer allocator.free(boundaries);
///
/// // Parse each partition in its own thread (pseudo-code)
/// var docs: [4]kdl.StreamDocument = undefined;
/// for (boundaries, 0..) |start, i| {
///     const end = if (i + 1 < boundaries.len) boundaries[i + 1] else source.len;
///     docs[i] = try kdl.streamParse(allocator, source[start..end]);
/// }
///
/// // Merge results
/// var merged = try kdl.mergeDocuments(allocator, &docs);
/// defer merged.deinit();
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const stream_types = @import("stream_types.zig");
const stream_tokenizer = @import("stream_tokenizer.zig");
const value_builder = @import("value_builder.zig");
const numbers = @import("numbers.zig");
const constants = @import("constants.zig");
const index_parser = @import("simd/index_parser.zig");
const structural = @import("simd/structural.zig");

const StringPool = stream_types.StringPool;
const StringRef = stream_types.StringRef;
const NodeHandle = stream_types.NodeHandle;
const Range = stream_types.Range;
const StreamValue = stream_types.StreamValue;
const StreamTypedValue = stream_types.StreamTypedValue;
const StreamProperty = stream_types.StreamProperty;
const NodeStorage = stream_types.NodeStorage;
const ValuePool = stream_types.ValuePool;
const StreamDocument = stream_types.StreamDocument;
const StreamingTokenizer = stream_tokenizer.StreamingTokenizer;
const TokenType = stream_tokenizer.TokenType;
const StreamToken = stream_tokenizer.StreamToken;

pub const ParseError = error{
    InvalidSyntax,
    InvalidString,
    InvalidNumber,
    InvalidEscape,
    UnexpectedToken,
    MaxDepthExceeded,
    OutOfMemory,
};

pub const ParseOptions = struct {
    /// Maximum nesting depth for nodes.
    /// Protects against stack exhaustion from deeply nested documents.
    max_depth: u16 = constants.DEFAULT_MAX_DEPTH,
    /// Buffer size for the streaming tokenizer.
    buffer_size: usize = constants.DEFAULT_BUFFER_SIZE,
    /// Parsing strategy (streaming vs structural index).
    strategy: ParseStrategy = .streaming,
    /// Max bytes to read when strategy requires buffering the whole input.
    max_document_size: usize = constants.MAX_POOL_SIZE,
};

/// Parser strategy selection.
pub const ParseStrategy = enum {
    streaming,
    structural_index,
};

/// Streaming parser that builds a StreamDocument from KDL source.
/// Thread-safe when each thread uses its own StreamParser instance.
pub fn StreamParser(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        const Tokenizer = StreamingTokenizer(ReaderType);

        tokenizer: Tokenizer,
        current: StreamToken,
        doc: *StreamDocument,
        options: ParseOptions,
        depth: u16,

        pub fn init(allocator: Allocator, doc: *StreamDocument, reader: ReaderType, options: ParseOptions) !Self {
            var tokenizer = try Tokenizer.init(allocator, reader, options.buffer_size);
            errdefer tokenizer.deinit();
            
            var parser = Self{
                .tokenizer = tokenizer,
                .current = undefined,
                .doc = doc,
                .options = options,
                .depth = 0,
            };
            
            // Prime the tokenizer
            parser.current = try parser.tokenizer.next();
            return parser;
        }

        pub fn deinit(self: *Self) void {
            self.tokenizer.deinit();
        }

        /// Slashdash context determines what can be skipped
        const SlashdashContext = enum { document, children, entries };

        /// Parse the complete document.
        pub fn parse(self: *Self) !void {
            while (self.current.type != .eof) {
                // Skip newlines between nodes
                while (self.current.type == .newline) {
                    try self.advance();
                }
                if (self.current.type == .eof) break;

                // Handle slashdash at document level
                if (self.current.type == .slashdash) {
                    _ = try self.consumeSlashdash(.document, null);
                    continue;
                }

                const node = try self.parseNode(null);
                self.doc.addRoot(node) catch return ParseError.OutOfMemory;
            }
        }

        /// What was slashdash'd
        const SlashdashResult = enum { entry, children_block };

        /// Centralized slashdash handling - advances past /- and skips the target
        /// Returns what was slashdash'd so caller can handle appropriately
        fn consumeSlashdash(self: *Self, context: SlashdashContext, parent: ?NodeHandle) ParseError!SlashdashResult {
            // Advance past /-
            try self.advance();

            // Skip newlines/whitespace after slashdash
            while (self.current.type == .newline) {
                try self.advance();
            }

            // Dispatch based on what follows and context
            switch (self.current.type) {
                .open_brace => {
                    try self.skipChildrenBlock();
                    return .children_block;
                },
                .eof, .close_brace => {
                    // Slashdash with nothing to comment out is an error
                    return ParseError.UnexpectedToken;
                },
                else => {
                    switch (context) {
                        .document, .children => _ = try self.parseNode(parent),
                        .entries => _ = try self.parseSlashdashArgumentOrProperty(),
                    }
                    return .entry;
                },
            }
        }

        fn parseNode(self: *Self, parent: ?NodeHandle) !NodeHandle {
            // Check depth limit
            if (self.depth >= self.options.max_depth) {
                return ParseError.MaxDepthExceeded;
            }
            self.depth += 1;
            defer self.depth -= 1;

            // Parse type annotation if present
            var type_annotation = StringRef.empty;
            if (self.current.type == .open_paren) {
                try self.advance();
                type_annotation = try self.parseIdentifierOrString();
                if (self.current.type != .close_paren) {
                    return ParseError.InvalidSyntax;
                }
                try self.advance();
            }

            // Parse node name
            const name = try self.parseIdentifierOrString();

            // Track argument and property ranges
            const arg_start: u64 = @intCast(self.doc.values.arguments.items.len);
            const prop_start: u64 = @intCast(self.doc.values.properties.items.len);

            // Parse arguments and properties
            var saw_children_block = false;
            while (true) {
                // Skip any slashdash'd items
                while (self.current.type == .slashdash) {
                    const result = try self.consumeSlashdash(.entries, parent);
                    if (result == .children_block) {
                        // Slashdash'd children block ends entry parsing
                        saw_children_block = true;
                        break;
                    }
                }
                if (saw_children_block) break;

                if (self.current.type == .newline or
                    self.current.type == .semicolon or
                    self.current.type == .eof or
                    self.current.type == .open_brace or
                    self.current.type == .close_brace)
                {
                    break;
                }

                _ = try self.parseArgumentOrProperty();
            }

            const arg_end: u64 = @intCast(self.doc.values.arguments.items.len);
            const prop_end: u64 = @intCast(self.doc.values.properties.items.len);

            // After a slashdash'd children block, only children block, slashdash, terminator, or EOF allowed
            if (saw_children_block) {
                if (self.current.type != .open_brace and
                    self.current.type != .slashdash and
                    self.current.type != .newline and
                    self.current.type != .semicolon and
                    self.current.type != .eof and
                    self.current.type != .close_brace)
                {
                    return ParseError.UnexpectedToken;
                }
            }

            // Create the node
            const node = self.doc.nodes.addNode(
                name,
                type_annotation,
                parent,
                Range{ .start = arg_start, .count = arg_end - arg_start },
                Range{ .start = prop_start, .count = prop_end - prop_start },
            ) catch return ParseError.OutOfMemory;

            // Handle slashdash'd children blocks before actual children
            while (self.current.type == .slashdash) {
                const result = try self.consumeSlashdash(.children, node);
                if (result != .children_block) {
                    // Only children blocks allowed here (not nodes)
                    return ParseError.UnexpectedToken;
                }
            }

            // Parse children if present
            var had_children = false;
            if (self.current.type == .open_brace) {
                had_children = true;
                try self.advance();

                while (self.current.type != .close_brace and self.current.type != .eof) {
                    while (self.current.type == .newline) {
                        try self.advance();
                    }
                    if (self.current.type == .close_brace or self.current.type == .eof) break;

                    // Handle slashdash
                    if (self.current.type == .slashdash) {
                        _ = try self.consumeSlashdash(.children, node);
                        continue;
                    }

                    const child = try self.parseNode(node);
                    self.doc.nodes.linkChild(node, child);
                }

                if (self.current.type == .close_brace) {
                    try self.advance();
                } else {
                    // Hit EOF without closing brace - unclosed children block
                    return ParseError.UnexpectedToken;
                }
            }

            // Handle slashdash'd children blocks after actual children
            while (self.current.type == .slashdash) {
                const result = try self.consumeSlashdash(.children, node);
                if (result != .children_block) {
                    // Only children blocks allowed here (not nodes)
                    return ParseError.UnexpectedToken;
                }
            }

            // Consume node terminator
            if (self.current.type == .semicolon) {
                try self.advance();
            } else if (self.current.type == .newline) {
                try self.advance();
            } else if (had_children) {
                // After children block, require terminator (semicolon, newline, EOF, or close_brace)
                if (self.current.type != .eof and self.current.type != .close_brace) {
                    return ParseError.UnexpectedToken;
                }
            }

            return node;
        }

        const ArgOrProp = union(enum) {
            argument: StreamTypedValue,
            property: StreamProperty,
        };

        fn parseArgumentOrProperty(self: *Self) !ArgOrProp {
            return self.parseArgumentOrPropertyImpl(false, true);
        }

        fn parseSlashdashArgumentOrProperty(self: *Self) !ArgOrProp {
            // After slashdash, no whitespace is required before the slashdash'd item
            return self.parseArgumentOrPropertyImpl(true, false);
        }

        fn parseArgumentOrPropertyImpl(self: *Self, skip_add: bool, require_whitespace: bool) !ArgOrProp {
            // KDL requires whitespace between node name and arguments/properties,
            // and between consecutive arguments/properties (but not after slashdash)
            if (require_whitespace and !self.current.preceded_by_whitespace) {
                return ParseError.UnexpectedToken;
            }

            // Check for type annotation
            var type_annotation = StringRef.empty;
            if (self.current.type == .open_paren) {
                try self.advance();
                type_annotation = try self.parseIdentifierOrString();
                if (self.current.type != .close_paren) {
                    return ParseError.InvalidSyntax;
                }
                try self.advance();
            }

            // Check if this is a property (has =)
            const name_or_value = try self.parseValue();

            if (self.current.type == .equals) {
                // This is a property
                // Type annotations on property KEYS are not allowed
                if (type_annotation.len != 0) {
                    return ParseError.InvalidSyntax;
                }
                try self.advance();

                // Property VALUE might have type annotation
                var prop_type = StringRef.empty;
                if (self.current.type == .open_paren) {
                    try self.advance();
                    prop_type = try self.parseIdentifierOrString();
                    if (self.current.type != .close_paren) {
                        return ParseError.InvalidSyntax;
                    }
                    try self.advance();
                }

                const value = try self.parseValue();

                const prop = StreamProperty{
                    .name = name_or_value.string, // name_or_value must be string for property
                    .value = value,
                    .type_annotation = prop_type,
                };
                if (!skip_add) {
                    _ = self.doc.values.addProperty(prop) catch return ParseError.OutOfMemory;
                }
                return ArgOrProp{ .property = prop };
            } else {
                // This is an argument
                const arg = StreamTypedValue{
                    .value = name_or_value,
                    .type_annotation = type_annotation,
                };
                if (!skip_add) {
                    _ = self.doc.values.addArgument(arg) catch return ParseError.OutOfMemory;
                }
                return ArgOrProp{ .argument = arg };
            }
        }

        fn parseValue(self: *Self) !StreamValue {
            const text = self.tokenizer.getText(self.current);
            return switch (self.current.type) {
                .quoted_string => blk: {
                    const ref = value_builder.buildQuotedString(&self.doc.strings, text) catch |err| {
                        return switch (err) {
                            error.InvalidString => ParseError.InvalidString,
                            error.InvalidEscape => ParseError.InvalidEscape,
                            error.OutOfMemory => ParseError.OutOfMemory,
                        };
                    };
                    try self.advance();
                    break :blk StreamValue{ .string = ref };
                },
                .raw_string => blk: {
                    const ref = value_builder.buildRawString(&self.doc.strings, text) catch |err| {
                        return switch (err) {
                            error.InvalidString => ParseError.InvalidString,
                            error.InvalidEscape => ParseError.InvalidEscape,
                            error.OutOfMemory => ParseError.OutOfMemory,
                        };
                    };
                    try self.advance();
                    break :blk StreamValue{ .string = ref };
                },
                .multiline_string => blk: {
                    const ref = value_builder.buildMultilineString(&self.doc.strings, text) catch |err| {
                        return switch (err) {
                            error.InvalidString => ParseError.InvalidString,
                            error.InvalidEscape => ParseError.InvalidEscape,
                            error.OutOfMemory => ParseError.OutOfMemory,
                        };
                    };
                    try self.advance();
                    break :blk StreamValue{ .string = ref };
                },
                .identifier => blk: {
                    const ref = value_builder.buildIdentifier(&self.doc.strings, text) catch {
                        return ParseError.OutOfMemory;
                    };
                    try self.advance();
                    break :blk StreamValue{ .string = ref };
                },
                .integer => blk: {
                    const val = numbers.parseDecimalInteger(self.doc.strings.allocator, text) catch {
                        return ParseError.InvalidNumber;
                    };
                    try self.advance();
                    break :blk StreamValue{ .integer = val };
                },
                .float => blk: {
                    const result = numbers.parseFloat(self.doc.strings.allocator, text) catch {
                        return ParseError.InvalidNumber;
                    };
                    // Defer cleanup to end of blk scope (after pool.add copies the string)
                    defer if (result.original) |orig| self.doc.strings.allocator.free(orig);
                    // Always preserve original text for round-tripping
                    // Add to pool BEFORE advance() since text points to token buffer
                    const orig_text = result.original orelse text;
                    const ref = self.doc.strings.add(orig_text) catch {
                        return ParseError.OutOfMemory;
                    };
                    try self.advance();
                    break :blk StreamValue{ .float = .{ .value = result.value, .original = ref } };
                },
                .hex_integer => blk: {
                    const val = numbers.parseRadixInteger(self.doc.strings.allocator, text, 2, 16) catch {
                        return ParseError.InvalidNumber;
                    };
                    try self.advance();
                    break :blk StreamValue{ .integer = val };
                },
                .octal_integer => blk: {
                    const val = numbers.parseRadixInteger(self.doc.strings.allocator, text, 2, 8) catch {
                        return ParseError.InvalidNumber;
                    };
                    try self.advance();
                    break :blk StreamValue{ .integer = val };
                },
                .binary_integer => blk: {
                    const val = numbers.parseRadixInteger(self.doc.strings.allocator, text, 2, 2) catch {
                        return ParseError.InvalidNumber;
                    };
                    try self.advance();
                    break :blk StreamValue{ .integer = val };
                },
                .keyword_true => blk: {
                    try self.advance();
                    break :blk StreamValue{ .boolean = true };
                },
                .keyword_false => blk: {
                    try self.advance();
                    break :blk StreamValue{ .boolean = false };
                },
                .keyword_null => blk: {
                    try self.advance();
                    break :blk StreamValue{ .null_value = {} };
                },
                .keyword_inf => blk: {
                    try self.advance();
                    break :blk StreamValue{ .positive_inf = {} };
                },
                .keyword_neg_inf => blk: {
                    try self.advance();
                    break :blk StreamValue{ .negative_inf = {} };
                },
                .keyword_nan => blk: {
                    try self.advance();
                    break :blk StreamValue{ .nan_value = {} };
                },
                else => ParseError.UnexpectedToken,
            };
        }

        fn parseIdentifierOrString(self: *Self) !StringRef {
            const text = self.tokenizer.getText(self.current);
            return switch (self.current.type) {
                .identifier => blk: {
                    const ref = value_builder.buildIdentifier(&self.doc.strings, text) catch {
                        return ParseError.OutOfMemory;
                    };
                    try self.advance();
                    break :blk ref;
                },
                .quoted_string => blk: {
                    const ref = value_builder.buildQuotedString(&self.doc.strings, text) catch |err| {
                        return switch (err) {
                            error.InvalidString => ParseError.InvalidString,
                            error.InvalidEscape => ParseError.InvalidEscape,
                            error.OutOfMemory => ParseError.OutOfMemory,
                        };
                    };
                    try self.advance();
                    break :blk ref;
                },
                .raw_string => blk: {
                    const ref = value_builder.buildRawString(&self.doc.strings, text) catch |err| {
                        return switch (err) {
                            error.InvalidString => ParseError.InvalidString,
                            error.InvalidEscape => ParseError.InvalidEscape,
                            error.OutOfMemory => ParseError.OutOfMemory,
                        };
                    };
                    try self.advance();
                    break :blk ref;
                },
                else => ParseError.UnexpectedToken,
            };
        }

        fn advance(self: *Self) !void {
            self.current = try self.tokenizer.next();
        }

        /// Skip a children block (for slashdash handling).
        /// Enforces max_depth to protect against deeply nested malicious input.
        fn skipChildrenBlock(self: *Self) ParseError!void {
            if (self.current.type != .open_brace) return;
            try self.advance();

            var depth: u16 = 1;
            while (depth > 0 and self.current.type != .eof) {
                if (self.current.type == .open_brace) {
                    depth += 1;
                    // Check against max_depth (relative to current parser depth)
                    if (self.depth + depth >= self.options.max_depth) {
                        return ParseError.MaxDepthExceeded;
                    }
                } else if (self.current.type == .close_brace) {
                    depth -= 1;
                }
                try self.advance();
            }
        }
    };
}

/// Parse KDL source into a StreamDocument.
pub fn parse(allocator: Allocator, source: []const u8) !StreamDocument {
    return parseWithOptions(allocator, source, .{});
}

/// Parse KDL source with options.
pub fn parseWithOptions(allocator: Allocator, source: []const u8, options: ParseOptions) !StreamDocument {
    if (options.strategy == .structural_index) {
        return index_parser.parseWithOptions(allocator, source, .{ .max_depth = options.max_depth });
    }
    var stream = std.io.fixedBufferStream(source);
    return parseReaderWithOptions(allocator, stream.reader(), options);
}

/// Parse KDL from a reader.
pub fn parseReader(allocator: Allocator, reader: anytype) !StreamDocument {
    return parseReaderWithOptions(allocator, reader, .{});
}

/// Parse KDL from a reader with options.
pub fn parseReaderWithOptions(allocator: Allocator, reader: anytype, options: ParseOptions) !StreamDocument {
    if (options.strategy == .structural_index) {
        const scan_result = try structural.scanReader(allocator, reader, .{
            .chunk_size = options.buffer_size,
            .max_document_size = options.max_document_size,
        });
        defer scan_result.deinit(allocator);

        var doc = try StreamDocument.init(allocator);
        errdefer doc.deinit();

        var parser = index_parser.initChunkedParser(allocator, scan_result.source, scan_result.index, &doc, .{
            .max_depth = options.max_depth,
        });
        defer parser.deinit();
        try parser.parse();
        return doc;
    }
    var doc = try StreamDocument.init(allocator);
    errdefer doc.deinit();

    const Parser = StreamParser(@TypeOf(reader));
    var parser = try Parser.init(allocator, &doc, reader, options);
    defer parser.deinit();
    
    try parser.parse();

    return doc;
}

// ============================================================================ 
// Parallel Parsing Support
// ============================================================================ 

/// Find boundaries in source for parallel parsing.
/// Returns offsets where top-level nodes begin.
/// Each partition can be parsed independently and merged.
pub fn findNodeBoundaries(allocator: Allocator, source: []const u8, max_partitions: usize) ![]usize {
    if (source.len == 0 or max_partitions <= 1) {
        return &[_]usize{};
    }

    var boundaries = std.ArrayListUnmanaged(usize){};
    defer boundaries.deinit(allocator);

    // Target partition size
    const target_size = source.len / max_partitions;

    var pos: usize = 0;
    var last_boundary: usize = 0;
    var brace_depth: usize = 0;
    var in_string = false;
    var in_raw_string = false;
    var in_line_comment = false;
    var in_block_comment: usize = 0;

    while (pos < source.len) {
        const c = source[pos];

        // Handle line comments
        if (in_line_comment) {
            if (c == '\n') {
                in_line_comment = false;
            }
            pos += 1;
            continue;
        }

        // Handle block comments
        if (in_block_comment > 0) {
            if (pos + 1 < source.len and c == '/' and source[pos + 1] == '*') {
                in_block_comment += 1;
                pos += 2;
                continue;
            }
            if (pos + 1 < source.len and c == '*' and source[pos + 1] == '/') {
                in_block_comment -= 1;
                pos += 2;
                continue;
            }
            pos += 1;
            continue;
        }

        // Handle raw strings
        if (in_raw_string) {
            if (c == '"') {
                in_raw_string = false;
            }
            pos += 1;
            continue;
        }

        // Handle regular strings
        if (in_string) {
            if (c == '\\' and pos + 1 < source.len) {
                pos += 2; // Skip escape sequence
                continue;
            }
            if (c == '"') {
                in_string = false;
            }
            pos += 1;
            continue;
        }

        // Check for comment start
        if (c == '/' and pos + 1 < source.len) {
            const next = source[pos + 1];
            if (next == '/') {
                in_line_comment = true;
                pos += 2;
                continue;
            }
            if (next == '*') {
                in_block_comment = 1;
                pos += 2;
                continue;
            }
        }

        // Check for string start
        if (c == '"') {
            in_string = true;
            pos += 1;
            continue;
        }

        // Check for raw string start
        if (c == '#') {
            var hash_count: usize = 0;
            var scan = pos;
            while (scan < source.len and source[scan] == '#') {
                hash_count += 1;
                scan += 1;
            }
            if (scan < source.len and source[scan] == '"') {
                in_raw_string = true;
                pos = scan + 1;
                continue;
            }
        }

        // Track brace depth
        if (c == '{') {
            brace_depth += 1;
        } else if (c == '}') {
            if (brace_depth > 0) brace_depth -= 1;
        }

        // At top level, check for node boundaries (newlines or semicolons)
        if (brace_depth == 0 and (c == '\n' or c == ';')) {
            const boundary_end = pos + 1;

            // Skip whitespace/newlines after boundary
            var next_start = boundary_end;
            while (next_start < source.len and
                (source[next_start] == ' ' or source[next_start] == '\t' or
                source[next_start] == '\n' or source[next_start] == '\r'))
            {
                next_start += 1;
            }

            // Check if we've passed the target partition size
            if (next_start >= last_boundary + target_size and
                boundaries.items.len < max_partitions - 1 and
                next_start < source.len)
            {
                try boundaries.append(allocator, next_start);
                last_boundary = next_start;
            }
        }

        pos += 1;
    }

    return try boundaries.toOwnedSlice(allocator);
}

/// Merge multiple StreamDocuments into one.
/// Adjusts all handles to account for offset changes.
pub fn mergeDocuments(allocator: Allocator, documents: []StreamDocument) ParseError!StreamDocument {
    var result = StreamDocument.init(allocator) catch return ParseError.OutOfMemory;
    errdefer result.deinit();

    for (documents) |*doc| {
        const string_offset: u64 = @intCast(result.strings.data.items.len);
        const arg_offset: u64 = @intCast(result.values.arguments.items.len);
        const prop_offset: u64 = @intCast(result.values.properties.items.len);
        const node_offset: u64 = @intCast(result.nodes.names.items.len);

        // Copy strings
        result.strings.data.appendSlice(result.strings.allocator, doc.strings.data.items) catch
            return ParseError.OutOfMemory;

        // Copy arguments (adjust string refs or copy borrowed refs)
        for (doc.values.arguments.items) |arg| {
            var new_arg = arg;
            new_arg.value = try adjustValueStringRefs(arg.value, string_offset, doc, &result.strings);
            new_arg.type_annotation = try adjustOrCopyStringRef(arg.type_annotation, string_offset, doc, &result.strings);
            _ = result.values.addArgument(new_arg) catch return ParseError.OutOfMemory;
        }

        // Copy properties (adjust string refs or copy borrowed refs)
        for (doc.values.properties.items) |prop| {
            var new_prop = prop;
            new_prop.name = try adjustOrCopyStringRef(prop.name, string_offset, doc, &result.strings);
            new_prop.value = try adjustValueStringRefs(prop.value, string_offset, doc, &result.strings);
            new_prop.type_annotation = try adjustOrCopyStringRef(prop.type_annotation, string_offset, doc, &result.strings);
            _ = result.values.addProperty(new_prop) catch return ParseError.OutOfMemory;
        }

        // Copy nodes (adjust all references or copy borrowed refs)
        for (0..doc.nodes.names.items.len) |i| {
            const name = try adjustOrCopyStringRef(doc.nodes.names.items[i], string_offset, doc, &result.strings);
            const type_ann = try adjustOrCopyStringRef(doc.nodes.type_annotations.items[i], string_offset, doc, &result.strings);
            const parent = if (doc.nodes.parents.items[i]) |p|
                NodeHandle.fromIndex(p.toIndex() + node_offset)
            else
                null;
            const arg_range = Range{
                .start = doc.nodes.arg_ranges.items[i].start + arg_offset,
                .count = doc.nodes.arg_ranges.items[i].count,
            };
            const prop_range = Range{
                .start = doc.nodes.prop_ranges.items[i].start + prop_offset,
                .count = doc.nodes.prop_ranges.items[i].count,
            };

            _ = result.nodes.addNode(name, type_ann, parent, arg_range, prop_range) catch
                return ParseError.OutOfMemory;
        }

        // Update child/sibling links
        for (0..doc.nodes.names.items.len) |i| {
            const new_idx = i + node_offset;
            if (doc.nodes.first_child.items[i]) |fc| {
                result.nodes.first_child.items[new_idx] = NodeHandle.fromIndex(fc.toIndex() + node_offset);
            }
            if (doc.nodes.next_sibling.items[i]) |ns| {
                result.nodes.next_sibling.items[new_idx] = NodeHandle.fromIndex(ns.toIndex() + node_offset);
            }
        }

        // Copy root references
        for (doc.roots.items) |root| {
            result.addRoot(NodeHandle.fromIndex(root.toIndex() + node_offset)) catch
                return ParseError.OutOfMemory;
        }
    }

    return result;
}

/// Adjust or copy a StringRef for merging.
/// For owned refs, adjust the offset. For borrowed refs, copy to the target pool.
fn adjustOrCopyStringRef(
    ref: StringRef,
    string_offset: u64,
    source_doc: *StreamDocument,
    target_pool: *StringPool,
) ParseError!StringRef {
    if (ref.len == 0) return ref;

    if (ref.isBorrowed()) {
        // Borrowed refs need to be copied to the target pool
        const str = source_doc.getString(ref);
        return target_pool.add(str) catch return ParseError.OutOfMemory;
    } else {
        // Owned refs just need offset adjustment
        return StringRef{
            .offset = ref.offset + string_offset,
            .len = ref.len,
        };
    }
}

fn adjustValueStringRefs(
    value: StreamValue,
    string_offset: u64,
    source_doc: *StreamDocument,
    target_pool: *StringPool,
) ParseError!StreamValue {
    return switch (value) {
        .string => |ref| StreamValue{ .string = try adjustOrCopyStringRef(ref, string_offset, source_doc, target_pool) },
        .float => |f| StreamValue{ .float = .{
            .value = f.value,
            .original = try adjustOrCopyStringRef(f.original, string_offset, source_doc, target_pool),
        } },
        else => value,
    };
}

// ============================================================================ 
// Tests
// ============================================================================ 

test "parse simple node" {
    var doc = try parse(std.testing.allocator, "node");
    defer doc.deinit();

    var roots = doc.rootIterator();
    const node = roots.next().?;
    try std.testing.expectEqualStrings("node", doc.getString(doc.nodes.getName(node)));
    try std.testing.expectEqual(@as(?NodeHandle, null), roots.next());
}

test "parse node with argument" {
    var doc = try parse(std.testing.allocator, "node 42");
    defer doc.deinit();

    var roots = doc.rootIterator();
    const node = roots.next().?;
    try std.testing.expectEqualStrings("node", doc.getString(doc.nodes.getName(node)));

    const args = doc.values.getArguments(doc.nodes.getArgRange(node));
    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqual(@as(i128, 42), args[0].value.integer);
}

test "parse node with string argument" {
    var doc = try parse(std.testing.allocator, "node \"hello\\nworld\"");
    defer doc.deinit();

    var roots = doc.rootIterator();
    const node = roots.next().?;

    const args = doc.values.getArguments(doc.nodes.getArgRange(node));
    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqualStrings("hello\nworld", doc.getString(args[0].value.string));
}

test "parse node with property" {
    var doc = try parse(std.testing.allocator, "node key=\"value\"");
    defer doc.deinit();

    var roots = doc.rootIterator();
    const node = roots.next().?;

    const props = doc.values.getProperties(doc.nodes.getPropRange(node));
    try std.testing.expectEqual(@as(usize, 1), props.len);
    try std.testing.expectEqualStrings("key", doc.getString(props[0].name));
    try std.testing.expectEqualStrings("value", doc.getString(props[0].value.string));
}

test "parse node with children" {
    var doc = try parse(std.testing.allocator,
        \\parent {
        \\    child1
        \\    child2
        \\}
    );
    defer doc.deinit();

    var roots = doc.rootIterator();
    const parent = roots.next().?;
    try std.testing.expectEqualStrings("parent", doc.getString(doc.nodes.getName(parent)));

    var children = doc.childIterator(parent);
    const child1 = children.next().?;
    try std.testing.expectEqualStrings("child1", doc.getString(doc.nodes.getName(child1)));
    const child2 = children.next().?;
    try std.testing.expectEqualStrings("child2", doc.getString(doc.nodes.getName(child2)));
    try std.testing.expectEqual(@as(?NodeHandle, null), children.next());
}

test "parse multiple nodes" {
    var doc = try parse(std.testing.allocator, "node1\nnode2\nnode3");
    defer doc.deinit();

    var roots = doc.rootIterator();
    try std.testing.expectEqualStrings("node1", doc.getString(doc.nodes.getName(roots.next().?)));
    try std.testing.expectEqualStrings("node2", doc.getString(doc.nodes.getName(roots.next().?)));
    try std.testing.expectEqualStrings("node3", doc.getString(doc.nodes.getName(roots.next().?)));
    try std.testing.expectEqual(@as(?NodeHandle, null), roots.next());
}

test "parse keywords" {
    var doc = try parse(std.testing.allocator, "node #true #false #null #inf #-inf #nan");
    defer doc.deinit();

    var roots = doc.rootIterator();
    const node = roots.next().?;

    const args = doc.values.getArguments(doc.nodes.getArgRange(node));
    try std.testing.expectEqual(@as(usize, 6), args.len);
    try std.testing.expect(args[0].value.boolean);
    try std.testing.expect(!args[1].value.boolean);
    try std.testing.expectEqual(StreamValue.null_value, args[2].value);
    try std.testing.expectEqual(StreamValue.positive_inf, args[3].value);
    try std.testing.expectEqual(StreamValue.negative_inf, args[4].value);
    try std.testing.expectEqual(StreamValue.nan_value, args[5].value);
}

test "parse type annotations" {
    var doc = try parse(std.testing.allocator, "(type)node (int)42");
    defer doc.deinit();

    var roots = doc.rootIterator();
    const node = roots.next().?;

    try std.testing.expectEqualStrings("type", doc.getString(doc.nodes.getTypeAnnotation(node)));

    const args = doc.values.getArguments(doc.nodes.getArgRange(node));
    try std.testing.expectEqualStrings("int", doc.getString(args[0].type_annotation));
}

test "parse slashdash" {
    var doc = try parse(std.testing.allocator, "node /-42 1");
    defer doc.deinit();

    var roots = doc.rootIterator();
    const node = roots.next().?;

    const args = doc.values.getArguments(doc.nodes.getArgRange(node));
    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqual(@as(i128, 1), args[0].value.integer);
}

test "merge documents" {
    var doc1 = try parse(std.testing.allocator, "node1 \"value1\"");
    defer doc1.deinit();

    var doc2 = try parse(std.testing.allocator, "node2 \"value2\"");
    defer doc2.deinit();

    var docs = [_]StreamDocument{ doc1, doc2 };
    var merged = try mergeDocuments(std.testing.allocator, &docs);
    defer merged.deinit();

    var roots = merged.rootIterator();
    const n1 = roots.next().?;
    try std.testing.expectEqualStrings("node1", merged.getString(merged.nodes.getName(n1)));
    const n2 = roots.next().?;
    try std.testing.expectEqualStrings("node2", merged.getString(merged.nodes.getName(n2)));
}

test "findNodeBoundaries empty source" {
    const boundaries = try findNodeBoundaries(std.testing.allocator, "", 4);
    defer if (boundaries.len > 0) std.testing.allocator.free(boundaries);
    try std.testing.expectEqual(@as(usize, 0), boundaries.len);
}

test "findNodeBoundaries single partition" {
    const boundaries = try findNodeBoundaries(std.testing.allocator, "node1\nnode2\nnode3", 1);
    defer if (boundaries.len > 0) std.testing.allocator.free(boundaries);
    try std.testing.expectEqual(@as(usize, 0), boundaries.len);
}

test "findNodeBoundaries multiple nodes" {
    const source =
        \\node1 "value"
        \\node2 42
        \\node3 true
        \\node4 null
    ;
    const boundaries = try findNodeBoundaries(std.testing.allocator, source, 2);
    defer if (boundaries.len > 0) std.testing.allocator.free(boundaries);

    // Should have at least one boundary for 2 partitions
    try std.testing.expect(boundaries.len >= 1);

    // Each boundary should be at the start of a node
    for (boundaries) |b| {
        try std.testing.expect(b < source.len);
        // Should start with 'n' (node)
        try std.testing.expectEqual(@as(u8, 'n'), source[b]);
    }
}

test "findNodeBoundaries respects braces" {
    const source =
        \\parent1 {
        \\    child1
        \\    child2
        \\}
        \\parent2 {
        \\    child3
        \\}
    ;
    const boundaries = try findNodeBoundaries(std.testing.allocator, source, 4);
    defer if (boundaries.len > 0) std.testing.allocator.free(boundaries);

    // Boundaries should only be at top-level nodes
    for (boundaries) |b| {
        try std.testing.expect(b < source.len);
        // Should start with 'p' (parent) - top level only
        try std.testing.expectEqual(@as(u8, 'p'), source[b]);
    }
}

test "findNodeBoundaries respects strings" {
    const source =
        \\node1 "string with\nnewline"
        \\node2 "another"
    ;
    const boundaries = try findNodeBoundaries(std.testing.allocator, source, 4);
    defer if (boundaries.len > 0) std.testing.allocator.free(boundaries);

    // Should not split inside strings
    for (boundaries) |b| {
        try std.testing.expect(b < source.len);
    }
}

test "parse second partition directly" {
    // This is what the second partition would contain
    // Note: KDL 2.0 keywords use # prefix
    const source = "node3 #true\nnode4 #null\n";
    var doc = try parse(std.testing.allocator, source);
    defer doc.deinit();

    var count: usize = 0;
    var roots = doc.rootIterator();
    while (roots.next()) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "parallel parse and merge" {
    // Use explicit newlines to avoid multiline string escaping issues
    // Note: KDL 2.0 keywords use # prefix
    const source = "node1 \"value1\"\nnode2 42\nnode3 #true\nnode4 #null\n";

    // Find boundaries for 2 partitions
    const boundaries = try findNodeBoundaries(std.testing.allocator, source, 2);
    defer if (boundaries.len > 0) std.testing.allocator.free(boundaries);

    if (boundaries.len == 0) {
        // Single partition - just parse normally
        var doc = try parse(std.testing.allocator, source);
        defer doc.deinit();

        var count: usize = 0;
        var roots = doc.rootIterator();
        while (roots.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 4), count);
    } else {
        // Parse partitions separately
        var docs = std.ArrayListUnmanaged(StreamDocument){};
        defer {
            for (docs.items) |*d| d.deinit();
            docs.deinit(std.testing.allocator);
        }

        // First partition: start to first boundary
        const doc1 = try parse(std.testing.allocator, source[0..boundaries[0]]);
        try docs.append(std.testing.allocator, doc1);

        // Middle and last partitions
        var i: usize = 0;
        while (i < boundaries.len) : (i += 1) {
            const start = boundaries[i];
            const end = if (i + 1 < boundaries.len) boundaries[i + 1] else source.len;
            const doc = try parse(std.testing.allocator, source[start..end]);
            try docs.append(std.testing.allocator, doc);
        }

        // Merge
        var merged = try mergeDocuments(std.testing.allocator, docs.items);
        defer merged.deinit();

        // Verify all 4 nodes are present
        var count: usize = 0;
        var roots = merged.rootIterator();
        while (roots.next()) |_| count += 1;
        try std.testing.expectEqual(@as(usize, 4), count);
    }
}

test "thread-safe independent parsing" {
    // Test that multiple StreamParser instances can work independently
    // (Not actual threading, but verifies no shared mutable state)
    const source1 = "node1 42";
    const source2 = "node2 \"hello\"";

    var doc1 = try StreamDocument.init(std.testing.allocator);
    defer doc1.deinit();
    var doc2 = try StreamDocument.init(std.testing.allocator);
    defer doc2.deinit();

    var stream1 = std.io.fixedBufferStream(source1);
    var stream2 = std.io.fixedBufferStream(source2);
    
    // Parser 1
    const Parser1 = StreamParser(@TypeOf(stream1.reader()));
    var parser1 = try Parser1.init(std.testing.allocator, &doc1, stream1.reader(), .{});
    defer parser1.deinit();
    try parser1.parse();

    // Parser 2
    const Parser2 = StreamParser(@TypeOf(stream2.reader()));
    var parser2 = try Parser2.init(std.testing.allocator, &doc2, stream2.reader(), .{});
    defer parser2.deinit();
    try parser2.parse();

    // Verify doc1
    var roots1 = doc1.rootIterator();
    const n1 = roots1.next().?;
    try std.testing.expectEqualStrings("node1", doc1.getString(doc1.nodes.getName(n1)));
    const args1 = doc1.values.getArguments(doc1.nodes.getArgRange(n1));
    try std.testing.expectEqual(@as(i128, 42), args1[0].value.integer);

    // Verify doc2
    var roots2 = doc2.rootIterator();
    const n2 = roots2.next().?;
    try std.testing.expectEqualStrings("node2", doc2.getString(doc2.nodes.getName(n2)));
    const args2 = doc2.values.getArguments(doc2.nodes.getArgRange(n2));
    try std.testing.expectEqualStrings("hello", doc2.getString(args2[0].value.string));
}
