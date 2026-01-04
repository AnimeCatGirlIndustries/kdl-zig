/// KDL 2.0.0 Parser
/// Parses tokenized KDL into an AST (Document with Nodes).
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

/// Parse error with location information
pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    DuplicateProperty,
    OutOfMemory,
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
    error_info: ?ParseErrorInfo = null,

    /// Initialize parser with source and arena
    pub fn init(allocator: Allocator, source: []const u8, arena: *std.heap.ArenaAllocator) Parser {
        var tokenizer = Tokenizer.init(source);
        const first_token = tokenizer.next();
        return .{
            .tokenizer = tokenizer,
            .current = first_token,
            .allocator = allocator,
            .arena = arena,
        };
    }

    fn advance(self: *Parser) void {
        self.current = self.tokenizer.next();
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
            .identifier => Value{ .string = .{ .raw = token.text } },
            .quoted_string => Value{ .string = .{ .raw = try self.processQuotedString(token.text) } },
            .raw_string => Value{ .string = .{ .raw = try self.processRawString(token.text) } },
            .multiline_string => Value{ .string = .{ .raw = try self.processMultilineString(token.text) } },
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
            .identifier => token.text,
            .quoted_string => try self.processQuotedString(token.text),
            .raw_string => try self.processRawString(token.text),
            .multiline_string => try self.processMultilineString(token.text),
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

    // --- String processing ---

    fn processQuotedString(self: *Parser, text: []const u8) Error![]const u8 {
        // Remove surrounding quotes
        if (text.len < 2) return Error.InvalidString;
        const content = text[1 .. text.len - 1];

        // Process escape sequences
        return self.processEscapes(content);
    }

    fn processRawString(self: *Parser, text: []const u8) Error![]const u8 {
        // Format: #"..."# or ##"..."## etc.
        // Or multiline: #"""..."""# or ##"""..."""## etc.
        // Count leading hashes
        var hash_count: usize = 0;
        while (hash_count < text.len and text[hash_count] == '#') {
            hash_count += 1;
        }

        // Check if it's multiline (starts with """)
        const quote_start = hash_count;
        if (quote_start + 3 <= text.len and
            std.mem.eql(u8, text[quote_start .. quote_start + 3], "\"\"\""))
        {
            // Multiline raw string - dedent like regular multiline
            return self.processMultilineRawString(text, hash_count);
        }

        // Single-line raw string
        // Skip hashes and opening quote
        const start = hash_count + 1;
        // Skip closing quote and hashes
        const end = text.len - hash_count - 1;

        if (start > end) return Error.InvalidString;
        const content = text[start..end];

        // Single-line raw strings cannot contain newlines (use multiline syntax instead)
        if (std.mem.indexOfAny(u8, content, "\n\r") != null) {
            return Error.InvalidString;
        }

        return content;
    }

    fn processMultilineRawString(self: *Parser, text: []const u8, hash_count: usize) Error![]const u8 {
        const alloc = self.arena.allocator();

        // Skip opening #...#""" and closing """#...#
        const start = hash_count + 3; // Skip #"""
        const end = text.len - hash_count - 3; // Skip """#

        // Multiline strings MUST span multiple lines (have content between """ and """)
        if (start >= end) return Error.InvalidString;
        const content = text[start..end];

        // VALIDATION: Must span multiple lines (contain at least one newline)
        if (std.mem.indexOfAny(u8, content, "\n\r") == null) {
            return Error.InvalidString;
        }

        // Split into lines
        var lines: std.ArrayListUnmanaged([]const u8) = .{};
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < content.len) {
            if (content[i] == '\n') {
                try lines.append(alloc, content[line_start..i]);
                line_start = i + 1;
                i += 1;
            } else if (content[i] == '\r') {
                try lines.append(alloc, content[line_start..i]);
                i += 1;
                if (i < content.len and content[i] == '\n') {
                    i += 1;
                }
                line_start = i;
            } else {
                i += 1;
            }
        }
        if (line_start <= content.len) {
            try lines.append(alloc, content[line_start..]);
        }

        if (lines.items.len < 2) return Error.InvalidString;

        const line_slice = lines.items;

        // Get dedent from last line (which should be whitespace only)
        const last_line = line_slice[line_slice.len - 1];
        const dedent = getWhitespacePrefix(last_line);

        // VALIDATION: Check all content lines have matching prefix
        for (line_slice[1 .. line_slice.len - 1]) |line| {
            // Whitespace-only lines are always valid
            if (isWhitespaceOnly(line)) continue;

            // Content line must start with the dedent prefix (exact character match)
            if (!std.mem.startsWith(u8, line, dedent)) {
                return Error.InvalidString;
            }
        }

        // Build result by dedenting each line
        var result: std.ArrayListUnmanaged(u8) = .{};
        for (line_slice[1 .. line_slice.len - 1], 0..) |line, idx| {
            if (idx > 0) try result.append(alloc, '\n');

            // Whitespace-only lines become empty
            if (isWhitespaceOnly(line)) {
                continue;
            }

            // Dedent the line
            if (std.mem.startsWith(u8, line, dedent)) {
                try result.appendSlice(alloc, line[dedent.len..]);
            } else {
                try result.appendSlice(alloc, line);
            }
        }

        return try result.toOwnedSlice(alloc);
    }

    fn processMultilineString(self: *Parser, text: []const u8) Error![]const u8 {
        const alloc = self.arena.allocator();

        // Remove surrounding """
        if (text.len < 6) return Error.InvalidString;
        const raw_content = text[3 .. text.len - 3];

        // VALIDATION: Must span multiple lines (contain at least one newline)
        if (std.mem.indexOfAny(u8, raw_content, "\n\r") == null) {
            return Error.InvalidString;
        }

        // Split RAW content into lines for prefix validation
        var raw_lines: std.ArrayListUnmanaged([]const u8) = .{};
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < raw_content.len) {
            if (raw_content[i] == '\n') {
                try raw_lines.append(alloc, raw_content[line_start..i]);
                line_start = i + 1;
                i += 1;
            } else if (raw_content[i] == '\r') {
                try raw_lines.append(alloc, raw_content[line_start..i]);
                i += 1;
                if (i < raw_content.len and raw_content[i] == '\n') {
                    i += 1;
                }
                line_start = i;
            } else {
                i += 1;
            }
        }
        if (line_start <= raw_content.len) {
            try raw_lines.append(alloc, raw_content[line_start..]);
        }

        if (raw_lines.items.len < 2) return Error.InvalidString;

        // Get dedent prefix from RAW last line (must be LITERAL whitespace)
        const raw_last_line = raw_lines.items[raw_lines.items.len - 1];
        const raw_dedent = getWhitespacePrefix(raw_last_line);

        // VALIDATION: Check all RAW content lines have matching LITERAL prefix
        // Also track which lines are whitespace-only in RAW form (before escape processing)
        // Skip lines that are continuations (following a line ending with \)
        var raw_whitespace_only: std.ArrayListUnmanaged(bool) = .{};
        try raw_whitespace_only.append(alloc, true); // Line 0 (after opening """) - placeholder

        var prev_is_continuation = false;
        for (raw_lines.items[1 .. raw_lines.items.len - 1]) |line| {
            const is_ws_only = isWhitespaceOnly(line);
            try raw_whitespace_only.append(alloc, is_ws_only);

            // If previous line ended with backslash, this is a continuation line - skip validation
            if (prev_is_continuation) {
                // Check if this line also ends with backslash for next iteration
                prev_is_continuation = endsWithBackslash(line);
                continue;
            }

            // Check if this line ends with backslash (continuation to next line)
            prev_is_continuation = endsWithBackslash(line);

            // Whitespace-only lines are always valid
            if (is_ws_only) continue;

            // Content line must start with the LITERAL dedent prefix
            if (raw_dedent.len > 0 and !std.mem.startsWith(u8, line, raw_dedent)) {
                return Error.InvalidString;
            }
        }

        // Now process escape sequences
        const processed_content = try self.processEscapes(raw_content);

        // Re-split the processed content for dedenting
        var lines: std.ArrayListUnmanaged([]const u8) = .{};
        line_start = 0;
        i = 0;
        while (i < processed_content.len) {
            if (processed_content[i] == '\n') {
                try lines.append(alloc, processed_content[line_start..i]);
                line_start = i + 1;
                i += 1;
            } else if (processed_content[i] == '\r') {
                try lines.append(alloc, processed_content[line_start..i]);
                i += 1;
                if (i < processed_content.len and processed_content[i] == '\n') {
                    i += 1;
                }
                line_start = i;
            } else {
                i += 1;
            }
        }
        if (line_start <= processed_content.len) {
            try lines.append(alloc, processed_content[line_start..]);
        }

        if (lines.items.len == 0) return "";

        const line_slice = lines.items;
        if (line_slice.len < 2) return processed_content;

        // Get dedent from PROCESSED last line (may differ due to whitespace escapes)
        const processed_last_line = line_slice[line_slice.len - 1];
        const dedent = getWhitespacePrefix(processed_last_line);

        // VALIDATION: Last line must be whitespace-only after escape processing
        if (!isWhitespaceOnly(processed_last_line)) {
            return Error.InvalidString;
        }

        // VALIDATION: Content lines must have the processed dedent prefix
        for (line_slice[1 .. line_slice.len - 1]) |line| {
            if (isWhitespaceOnly(line)) continue;
            if (dedent.len > 0 and !std.mem.startsWith(u8, line, dedent)) {
                return Error.InvalidString;
            }
        }

        // Build result by dedenting each content line (skip first and last)
        var result: std.ArrayListUnmanaged(u8) = .{};
        for (line_slice[1 .. line_slice.len - 1], 0..) |line, idx| {
            if (idx > 0) try result.append(alloc, '\n');

            // Lines that were whitespace-only in RAW form become empty
            // (Use raw status, not processed, since \s becomes whitespace after processing)
            const raw_idx = idx + 1; // offset by 1 since we skip line 0
            if (raw_idx < raw_whitespace_only.items.len and raw_whitespace_only.items[raw_idx]) {
                continue;
            }

            // Dedent content lines
            if (std.mem.startsWith(u8, line, dedent)) {
                try result.appendSlice(alloc, line[dedent.len..]);
            } else {
                try result.appendSlice(alloc, line);
            }
        }

        return try result.toOwnedSlice(alloc);
    }

    fn processEscapes(self: *Parser, text: []const u8) Error![]const u8 {
        const alloc = self.arena.allocator();

        // Quick check if there are any escapes
        if (std.mem.indexOfScalar(u8, text, '\\') == null) {
            return text;
        }

        var result: std.ArrayListUnmanaged(u8) = .{};
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len) {
                i += 1;
                switch (text[i]) {
                    'n' => {
                        try result.append(alloc, '\n');
                        i += 1;
                    },
                    'r' => {
                        try result.append(alloc, '\r');
                        i += 1;
                    },
                    't' => {
                        try result.append(alloc, '\t');
                        i += 1;
                    },
                    '\\' => {
                        try result.append(alloc, '\\');
                        i += 1;
                    },
                    '"' => {
                        try result.append(alloc, '"');
                        i += 1;
                    },
                    'b' => {
                        try result.append(alloc, 0x08);
                        i += 1;
                    },
                    'f' => {
                        try result.append(alloc, 0x0C);
                        i += 1;
                    },
                    's' => {
                        try result.append(alloc, ' ');
                        i += 1;
                    },
                    'u' => {
                        // Unicode escape: \u{XXXX} (1-6 hex digits)
                        i += 1;
                        if (i >= text.len or text[i] != '{') {
                            return Error.InvalidEscape;
                        }
                        i += 1;

                        const esc_start = i;
                        while (i < text.len and text[i] != '}') {
                            i += 1;
                        }
                        if (i >= text.len) return Error.InvalidEscape;

                        const hex = text[esc_start..i];
                        // Unicode escapes must be 1-6 hex digits
                        if (hex.len == 0 or hex.len > 6) {
                            return Error.InvalidEscape;
                        }
                        const codepoint = std.fmt.parseInt(u21, hex, 16) catch return Error.InvalidEscape;
                        i += 1; // Skip }

                        // Encode as UTF-8
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch return Error.InvalidEscape;
                        try result.appendSlice(alloc, buf[0..len]);
                    },
                    '\n', '\r', ' ', '\t' => {
                        // Whitespace escape - skip whitespace until non-whitespace
                        // Must handle Unicode whitespace characters
                        while (i < text.len) {
                            // Try to decode UTF-8 and check if it's whitespace or newline
                            const decoded = unicode.decodeUtf8(text[i..]) orelse break;
                            if (unicode.isWhitespace(decoded.codepoint) or unicode.isNewline(decoded.codepoint)) {
                                i += decoded.len;
                            } else {
                                break;
                            }
                        }
                    },
                    else => {
                        // Unknown escape - error in KDL 2.0
                        return Error.InvalidEscape;
                    },
                }
            } else {
                try result.append(alloc, text[i]);
                i += 1;
            }
        }

        return try result.toOwnedSlice(alloc);
    }

    // --- Number parsing ---

    fn parseInteger(self: *Parser, text: []const u8) Error!i128 {
        _ = self;
        const cleaned = stripUnderscores(text);
        return std.fmt.parseInt(i128, cleaned, 10) catch return Error.InvalidNumber;
    }

    fn parseFloat(self: *Parser, text: []const u8) Error!Value.FloatValue {
        const alloc = self.arena.allocator();
        const cleaned = stripUnderscores(text);
        const f = std.fmt.parseFloat(f64, cleaned) catch return Error.InvalidNumber;

        // Check for overflow/underflow - preserve original text for round-tripping
        if (std.math.isInf(f) or (f == 0.0 and containsNonZeroDigit(cleaned))) {
            // Overflow (inf) or underflow (0.0 from non-zero value) - keep original
            const original = try alloc.dupe(u8, text);
            return .{ .value = f, .original = original };
        }

        // Check if has exponent - preserve original for correct formatting
        if (std.mem.indexOfAny(u8, cleaned, "eE") != null) {
            const original = try alloc.dupe(u8, text);
            return .{ .value = f, .original = original };
        }

        return .{ .value = f };
    }

    fn containsNonZeroDigit(s: []const u8) bool {
        for (s) |c| {
            if (c >= '1' and c <= '9') return true;
        }
        return false;
    }

    fn parseHexInteger(self: *Parser, text: []const u8) Error!i128 {
        _ = self;
        // Skip 0x prefix and handle sign
        var start: usize = 0;
        var negative = false;
        if (text.len > 0 and text[0] == '-') {
            negative = true;
            start = 1;
        } else if (text.len > 0 and text[0] == '+') {
            start = 1;
        }

        if (text.len < start + 2) return Error.InvalidNumber;
        const hex_part = text[start + 2 ..]; // Skip 0x
        const cleaned = stripUnderscores(hex_part);
        const value = std.fmt.parseInt(i128, cleaned, 16) catch return Error.InvalidNumber;
        return if (negative) -value else value;
    }

    fn parseOctalInteger(self: *Parser, text: []const u8) Error!i128 {
        _ = self;
        var start: usize = 0;
        var negative = false;
        if (text.len > 0 and text[0] == '-') {
            negative = true;
            start = 1;
        } else if (text.len > 0 and text[0] == '+') {
            start = 1;
        }

        if (text.len < start + 2) return Error.InvalidNumber;
        const oct_part = text[start + 2 ..]; // Skip 0o
        const cleaned = stripUnderscores(oct_part);
        const value = std.fmt.parseInt(i128, cleaned, 8) catch return Error.InvalidNumber;
        return if (negative) -value else value;
    }

    fn parseBinaryInteger(self: *Parser, text: []const u8) Error!i128 {
        _ = self;
        var start: usize = 0;
        var negative = false;
        if (text.len > 0 and text[0] == '-') {
            negative = true;
            start = 1;
        } else if (text.len > 0 and text[0] == '+') {
            start = 1;
        }

        if (text.len < start + 2) return Error.InvalidNumber;
        const bin_part = text[start + 2 ..]; // Skip 0b
        const cleaned = stripUnderscores(bin_part);
        const value = std.fmt.parseInt(i128, cleaned, 2) catch return Error.InvalidNumber;
        return if (negative) -value else value;
    }
};

// Helper functions

fn stripUnderscores(text: []const u8) []const u8 {
    // Count underscores to see if we need to do anything
    var underscore_count: usize = 0;
    for (text) |c| {
        if (c == '_') underscore_count += 1;
    }
    if (underscore_count == 0) return text;

    // For simplicity, use a static buffer (numbers shouldn't be > 128 chars)
    const S = struct {
        var buf: [128]u8 = undefined;
    };

    var i: usize = 0;
    for (text) |c| {
        if (c != '_') {
            if (i < S.buf.len) {
                S.buf[i] = c;
                i += 1;
            }
        }
    }
    return S.buf[0..i];
}

fn getWhitespacePrefix(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) {
        // Try to decode UTF-8 codepoint
        const decoded = unicode.decodeUtf8(line[i..]) orelse break;
        if (!unicode.isWhitespace(decoded.codepoint)) break;
        i += decoded.len;
    }
    return line[0..i];
}

fn isWhitespaceOnly(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) {
        // Try to decode UTF-8 codepoint
        const decoded = unicode.decodeUtf8(line[i..]) orelse return false;
        if (!unicode.isWhitespace(decoded.codepoint)) return false;
        i += decoded.len;
    }
    return true;
}

fn endsWithBackslash(line: []const u8) bool {
    // Check if line ends with \ (possibly followed by whitespace)
    // Need to scan forward and track last backslash position
    var last_backslash: ?usize = null;
    var i: usize = 0;
    while (i < line.len) {
        const decoded = unicode.decodeUtf8(line[i..]) orelse {
            i += 1;
            continue;
        };
        if (decoded.codepoint == '\\') {
            last_backslash = i;
        } else if (!unicode.isWhitespace(decoded.codepoint)) {
            last_backslash = null; // Reset if non-whitespace after backslash
        }
        i += decoded.len;
    }
    return last_backslash != null;
}

/// Parse a KDL document from source
pub fn parse(allocator: Allocator, source: []const u8) Error!Document {
    // Create arena on heap so Document can own it
    const arena = allocator.create(std.heap.ArenaAllocator) catch return Error.OutOfMemory;
    arena.* = std.heap.ArenaAllocator.init(allocator);
    errdefer {
        arena.deinit();
        allocator.destroy(arena);
    }

    var parser = Parser.init(allocator, source, arena);

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
