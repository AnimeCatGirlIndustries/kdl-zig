/// Streaming Tokenizer for KDL 2.0.0
///
/// Incremental tokenizer that reads from any reader, supporting:
/// - Bounded memory usage (configurable buffer size)
/// - Tokens spanning buffer boundaries
/// - Pause/resume capability via state machine
///
/// Unlike the zero-copy Tokenizer which requires entire source in memory,
/// this tokenizer works with streaming input for files larger than memory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const constants = @import("constants.zig");
const simd = @import("simd.zig");

/// Default buffer size for streaming tokenization.
/// Re-exported from constants module for convenience.
pub const DEFAULT_BUFFER_SIZE: usize = constants.DEFAULT_BUFFER_SIZE;

/// Token types (same as regular tokenizer)
pub const TokenType = enum {
    identifier,
    quoted_string,
    raw_string,
    multiline_string,
    integer,
    float,
    hex_integer,
    octal_integer,
    binary_integer,
    keyword_true,
    keyword_false,
    keyword_null,
    keyword_inf,
    keyword_neg_inf,
    keyword_nan,
    open_paren,
    close_paren,
    open_brace,
    close_brace,
    equals,
    semicolon,
    slashdash,
    newline,
    eof,
    invalid,
};

/// A streaming token with owned text.
/// Unlike zero-copy tokens, text is owned by the tokenizer's buffer.
pub const StreamToken = struct {
    type: TokenType,
    /// Offset into accumulated token buffer
    text_start: usize,
    text_len: usize,
    line: u32,
    column: u32,
    preceded_by_whitespace: bool = true,
};

/// Streaming tokenizer that reads incrementally from any reader.
pub fn StreamingTokenizer(comptime ReaderType: type) type {
    return struct {
        const Self = @This();

        /// Input reader
        reader: ReaderType,
        /// Input buffer for reading chunks
        input_buffer: []u8,
        /// Current valid data in input buffer
        input_start: usize,
        input_end: usize,
        /// Token accumulator (for tokens spanning chunks)
        token_buffer: std.ArrayListUnmanaged(u8),
        /// Current position in input buffer
        pos: usize,
        /// Line/column tracking
        line: u32,
        column: u32,
        /// EOF reached on reader
        reader_eof: bool,
        /// Allocator for buffers
        allocator: Allocator,
        /// Whether BOM has been checked
        checked_bom: bool,
        /// Whether we've returned the first token (for preceded_by_whitespace handling)
        first_token_returned: bool,

        pub fn init(allocator: Allocator, reader: ReaderType, buffer_size: usize) Allocator.Error!Self {
            const input_buffer = try allocator.alloc(u8, buffer_size);
            return Self{
                .reader = reader,
                .input_buffer = input_buffer,
                .input_start = 0,
                .input_end = 0,
                .token_buffer = .{},
                .pos = 0,
                .line = 1,
                .column = 1,
                .reader_eof = false,
                .allocator = allocator,
                .checked_bom = false,
                .first_token_returned = false,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.input_buffer);
            self.token_buffer.deinit(self.allocator);
        }

        /// Get the text for a token.
        pub fn getText(self: *const Self, token: StreamToken) []const u8 {
            return self.token_buffer.items[token.text_start..][0..token.text_len];
        }

        /// Get the next token.
        pub fn next(self: *Self) !StreamToken {
            // Reset token buffer for new token
            self.token_buffer.clearRetainingCapacity();

            // Ensure we have data to work with
            try self.ensureData();

            // Check for BOM on first call
            if (!self.checked_bom) {
                self.checked_bom = true;
                try self.skipBOM();
            }

            // Track whitespace before token
            // Note: We use the return value instead of comparing pos because
            // buffer shifts can reset pos, making position comparison unreliable.
            // The first token is always considered preceded by whitespace (start of file).
            const is_first_token = !self.first_token_returned;
            const skipped_ws = self.skipWhitespaceAndComments();
            const preceded_by_ws = skipped_ws or is_first_token;
            self.first_token_returned = true;

            // Check for EOF
            if (self.isAtEnd()) {
                return StreamToken{
                    .type = .eof,
                    .text_start = 0,
                    .text_len = 0,
                    .line = self.line,
                    .column = self.column,
                    .preceded_by_whitespace = preceded_by_ws,
                };
            }

            const start_line = self.line;
            const start_column = self.column;
            const token_start = self.token_buffer.items.len;

            const c = try self.peek() orelse {
                return StreamToken{
                    .type = .eof,
                    .text_start = 0,
                    .text_len = 0,
                    .line = start_line,
                    .column = start_column,
                    .preceded_by_whitespace = preceded_by_ws,
                };
            };

            const token_type: TokenType = switch (c) {
                '(' => blk: {
                    try self.consumeChar('(');
                    break :blk .open_paren;
                },
                ')' => blk: {
                    try self.consumeChar(')');
                    break :blk .close_paren;
                },
                '{' => blk: {
                    try self.consumeChar('{');
                    break :blk .open_brace;
                },
                '}' => blk: {
                    try self.consumeChar('}');
                    break :blk .close_brace;
                },
                '=' => blk: {
                    try self.consumeChar('=');
                    break :blk .equals;
                },
                ';' => blk: {
                    try self.consumeChar(';');
                    break :blk .semicolon;
                },
                '\n' => blk: {
                    try self.consumeNewline();
                    break :blk .newline;
                },
                '\r' => blk: {
                    try self.consumeCRLF();
                    break :blk .newline;
                },
                '"' => try self.tokenizeString(),
                '#' => try self.tokenizeHashPrefixed(),
                '/' => try self.tokenizeSlash(),
                '0'...'9' => try self.tokenizeNumber(),
                '+', '-' => try self.tokenizeSignedNumberOrIdentifier(),
                '.' => try self.tokenizeDotOrNumber(),
                'a'...'z', 'A'...'Z', '_' => try self.tokenizeIdentifier(),
                else => blk: {
                    // Check for other newlines or identifier
                    if (self.isNewlineChar(c)) {
                        try self.consumeNewline();
                        break :blk .newline;
                    }

                    // Try identifier
                    const decoded = try self.peekCodepoint();
                    if (decoded) |cp| {
                        if (unicode.isIdentifierStart(cp.codepoint)) {
                            break :blk try self.tokenizeIdentifier();
                        }
                    }

                    // Invalid character
                    try self.consumeChar(c);
                    break :blk .invalid;
                },
            };

            const token_end = self.token_buffer.items.len;

            return StreamToken{
                .type = token_type,
                .text_start = token_start,
                .text_len = token_end - token_start,
                .line = start_line,
                .column = start_column,
                .preceded_by_whitespace = preceded_by_ws,
            };
        }

        // --- Buffer management ---

        fn ensureDataFor(self: *Self, needed_offset: usize) !void {
            // Defensive check: if needed_offset exceeds buffer capacity, we can never
            // satisfy the request. Return early (caller will get null from peek).
            // In practice, offsets are only 0-3 for UTF-8 sequences.
            if (needed_offset >= self.input_buffer.len) {
                return;
            }

            // Loop until we have enough data or hit EOF.
            // This handles partial reads where reader.read() returns fewer bytes
            // than requested (which is allowed by Zig's reader interface).
            while (self.pos + needed_offset >= self.input_end and !self.reader_eof) {
                // Shift remaining data to start of buffer (only if not already at start)
                if (self.pos > 0) {
                    const remaining = self.input_end - self.pos;
                    if (remaining > 0) {
                        std.mem.copyForwards(u8, self.input_buffer[0..remaining], self.input_buffer[self.pos..self.input_end]);
                    }
                    self.input_end = remaining;
                    self.pos = 0;
                }

                // Read more data
                const bytes_read = try self.reader.read(self.input_buffer[self.input_end..]);
                if (bytes_read == 0) {
                    self.reader_eof = true;
                } else {
                    self.input_end += bytes_read;
                }
            }
        }

        fn ensureData(self: *Self) !void {
            try self.ensureDataFor(0);
        }

        fn isAtEnd(self: *Self) bool {
            return self.pos >= self.input_end and self.reader_eof;
        }

        fn peek(self: *Self) !?u8 {
            try self.ensureDataFor(0);
            if (self.pos >= self.input_end) return null;
            return self.input_buffer[self.pos];
        }

        fn peekAhead(self: *Self, offset: usize) !?u8 {
            try self.ensureDataFor(offset);
            if (self.pos + offset >= self.input_end) return null;
            return self.input_buffer[self.pos + offset];
        }

        const DecodedCodepoint = struct {
            codepoint: u21,
            len: u3,
        };

        fn peekCodepoint(self: *Self) !?DecodedCodepoint {
            const first = try self.peek() orelse return null;
            const len: u3 = if ((first & 0x80) == 0)
                1
            else if ((first & 0xE0) == 0xC0)
                2
            else if ((first & 0xF0) == 0xE0)
                3
            else if ((first & 0xF8) == 0xF0)
                4
            else
                return null;

            // Ensure we have all bytes
            var i: u3 = 1;
            while (i < len) : (i += 1) {
                _ = try self.peekAhead(i) orelse return null;
            }

            const bytes = self.input_buffer[self.pos..][0..len];
            const decoded = unicode.decodeUtf8(bytes) orelse return null;
            return DecodedCodepoint{
                .codepoint = decoded.codepoint,
                .len = decoded.len,
            };
        }

        fn advance(self: *Self) void {
            if (self.pos < self.input_end) {
                self.pos += 1;
                self.column += 1;
            }
        }

        fn consumeChar(self: *Self, c: u8) !void {
            try self.token_buffer.append(self.allocator, c);
            self.advance();
        }

        fn consumeNewline(self: *Self) !void {
            const c = try self.peek() orelse return;
            try self.token_buffer.append(self.allocator, c);
            self.pos += 1;
            self.line += 1;
            self.column = 1;
        }

        fn consumeCRLF(self: *Self) !void {
            // Consume \r
            try self.token_buffer.append(self.allocator, '\r');
            self.pos += 1;

            // Check for \n after \r
            if (try self.peek()) |next_byte| {
                if (next_byte == '\n') {
                    try self.token_buffer.append(self.allocator, '\n');
                    self.pos += 1;
                }
            }

            self.line += 1;
            self.column = 1;
        }

        fn skipBOM(self: *Self) !void {
            if (self.input_end >= 3 and
                self.input_buffer[0] == 0xEF and
                self.input_buffer[1] == 0xBB and
                self.input_buffer[2] == 0xBF)
            {
                self.pos = 3;
            }
        }

        fn isNewlineChar(_: *Self, c: u8) bool {
            return switch (c) {
                '\n', '\r', 0x0B, 0x0C => true,
                else => false,
            };
        }

        /// Skips whitespace and comments. Returns true if any were skipped.
        /// Note: This returns a bool instead of checking pos difference because
        /// buffer shifts during reading can reset pos, making position comparison unreliable.
        fn skipWhitespaceAndComments(self: *Self) bool {
            var skipped_any = false;
            while (true) {
                // SIMD fast path for ASCII whitespace (space/tab)
                const available = self.input_buffer[self.pos..self.input_end];
                const ws_len = simd.findWhitespaceLength(available);
                if (ws_len > 0) {
                    self.pos += ws_len;
                    self.column += @intCast(ws_len);
                    skipped_any = true;
                }

                // Peek byte first for fast ASCII checks
                const byte = self.peek() catch return skipped_any orelse return skipped_any;

                // Check for comments (ASCII)
                if (byte == '/') {
                    const peek_next = self.peekAhead(1) catch return skipped_any orelse return skipped_any;
                    if (peek_next == '/') {
                        self.skipSingleLineComment();
                        skipped_any = true;
                        continue;
                    } else if (peek_next == '*') {
                        self.skipMultiLineComment();
                        skipped_any = true;
                        continue;
                    }
                }

                // Check for line continuation (ASCII)
                if (byte == '\\') {
                    if (self.trySkipLineContinuation()) {
                        skipped_any = true;
                        continue;
                    }
                }

                // Check for whitespace - need full codepoint for Unicode whitespace
                const maybe_decoded = self.peekCodepoint() catch return skipped_any;
                const decoded = maybe_decoded orelse return skipped_any;
                if (unicode.isWhitespace(decoded.codepoint)) {
                    self.advanceBytes(decoded.len);
                    skipped_any = true;
                    continue;
                }

                break;
            }
            return skipped_any;
        }

        fn advanceBytes(self: *Self, count: u3) void {
            var i: u3 = 0;
            while (i < count) : (i += 1) {
                self.advance();
            }
        }

        fn skipSingleLineComment(self: *Self) void {
            self.advance(); // /
            self.advance(); // /

            while (self.peek() catch null) |c| {
                if (c == '\n' or c == '\r' or self.isNewlineChar(c)) break;
                self.advance();
            }
        }

        fn skipMultiLineComment(self: *Self) void {
            self.advance(); // /
            self.advance(); // *

            var depth: u32 = 1;
            while (depth > 0) {
                const c = self.peek() catch return orelse return;

                if (c == '/' and (self.peekAhead(1) catch null) == @as(u8, '*')) {
                    depth += 1;
                    self.advance();
                    self.advance();
                } else if (c == '*' and (self.peekAhead(1) catch null) == @as(u8, '/')) {
                    depth -= 1;
                    self.advance();
                    self.advance();
                } else if (c == '\n' or c == '\r') {
                    self.pos += 1;
                    if (c == '\r' and (self.peek() catch null) == @as(u8, '\n')) {
                        self.pos += 1;
                    }
                    self.line += 1;
                    self.column = 1;
                } else {
                    self.advance();
                }
            }
        }

        fn trySkipLineContinuation(self: *Self) bool {
            const start = self.pos;
            const start_column = self.column;

            self.pos += 1;
            self.column += 1;

            // Skip whitespace
            while (self.peek() catch null) |c| {
                if (unicode.isWhitespace(c)) {
                    self.advance();
                } else {
                    break;
                }
            }

            // Must have newline or EOF
            if (self.peek() catch null) |c| {
                if (c == '\n' or c == '\r' or self.isNewlineChar(c)) {
                    self.pos += 1;
                    if (c == '\r' and (self.peek() catch null) == @as(u8, '\n')) {
                        self.pos += 1;
                    }
                    self.line += 1;
                    self.column = 1;
                    return true;
                }

                // Allow comment after backslash
                if (c == '/' and (self.peekAhead(1) catch null) == @as(u8, '/')) {
                    self.skipSingleLineComment();
                    if (self.isAtEnd()) return true;
                    const peek_result = self.peek() catch return false;
                    const nc = peek_result orelse return true;
                    if (nc == '\n' or nc == '\r' or nc == 0x0B or nc == 0x0C) {
                        self.pos += 1;
                        if (nc == '\r') {
                            const peek2 = self.peek() catch null;
                            if (peek2 != null and peek2.? == '\n') {
                                self.pos += 1;
                            }
                        }
                        self.line += 1;
                        self.column = 1;
                        return true;
                    }
                }
            } else {
                return true; // EOF after backslash
            }

            // Not valid, restore position
            self.pos = start;
            self.column = start_column;
            return false;
        }

        // --- Token handlers ---

        fn tokenizeString(self: *Self) !TokenType {
            // Check for multiline
            if ((try self.peekAhead(1)) == @as(u8, '"') and (try self.peekAhead(2)) == @as(u8, '"')) {
                return self.tokenizeMultilineString();
            }

            try self.consumeChar('"');

            while (true) {
                // SIMD fast path: scan for string terminators (", \, \n, \r)
                const start_pos = self.pos;
                const available = self.input_buffer[self.pos..self.input_end];
                const safe_len = simd.findStringTerminator(available);
                if (safe_len > 0) {
                    self.pos += safe_len;
                    self.column += @intCast(safe_len);
                }

                if (self.pos > start_pos) {
                    try self.token_buffer.appendSlice(self.allocator, self.input_buffer[start_pos..self.pos]);
                }

                if (self.pos >= self.input_end and !self.reader_eof) {
                    try self.ensureData();
                    if (self.isAtEnd()) return .invalid;
                    continue;
                }

                const c = try self.peek() orelse return .invalid;

                if (c == '"') {
                    try self.consumeChar('"');
                    break;
                } else if (c == '\\') {
                    try self.consumeChar('\\');
                    if (try self.peek()) |nc| {
                        if (nc == ' ' or nc == '\t' or nc == '\n' or nc == '\r') {
                            try self.skipWhitespaceEscape();
                        } else {
                            try self.consumeChar(nc);
                        }
                    }
                } else if (c == '\n' or c == '\r') {
                    return .invalid;
                } else {
                    try self.consumeChar(c);
                }
            }

            return .quoted_string;
        }

        fn tokenizeMultilineString(self: *Self) !TokenType {
            // Consume """
            try self.consumeChar('"');
            try self.consumeChar('"');
            try self.consumeChar('"');

            while (try self.peek()) |c| {
                if (c == '"' and (try self.peekAhead(1)) == @as(u8, '"') and (try self.peekAhead(2)) == @as(u8, '"')) {
                    try self.consumeChar('"');
                    try self.consumeChar('"');
                    try self.consumeChar('"');
                    break;
                } else if (c == '\\') {
                    try self.consumeChar('\\');
                    if (try self.peek()) |nc| {
                        if (nc == '\n' or nc == '\r' or nc == ' ' or nc == '\t') {
                            try self.skipWhitespaceEscape();
                        } else {
                            try self.consumeChar(nc);
                        }
                    }
                } else if (c == '\n' or c == '\r') {
                    if (c == '\r') {
                        try self.consumeCRLF();
                    } else {
                        try self.consumeNewline();
                    }
                } else {
                    try self.consumeChar(c);
                }
            }

            return .multiline_string;
        }

        fn skipWhitespaceEscape(self: *Self) !void {
            while (try self.peek()) |c| {
                if (c == ' ' or c == '\t') {
                    try self.consumeChar(c);
                } else if (c == '\n' or c == '\r') {
                    if (c == '\r') {
                        try self.consumeCRLF();
                    } else {
                        try self.consumeNewline();
                    }
                } else {
                    break;
                }
            }
        }

        fn tokenizeHashPrefixed(self: *Self) !TokenType {
            try self.consumeChar('#');

            const next_char = try self.peek() orelse return .invalid;

            // Raw string
            if (next_char == '"' or next_char == '#') {
                return self.tokenizeRawString();
            }

            // Keywords
            return switch (next_char) {
                't' => if (try self.matchKeyword("true")) .keyword_true else .invalid,
                'f' => if (try self.matchKeyword("false")) .keyword_false else .invalid,
                'n' => blk: {
                    if (try self.matchKeyword("null")) break :blk .keyword_null;
                    if (try self.matchKeyword("nan")) break :blk .keyword_nan;
                    break :blk .invalid;
                },
                'i' => if (try self.matchKeyword("inf")) .keyword_inf else .invalid,
                '-' => blk: {
                    try self.consumeChar('-');
                    if (try self.matchKeyword("inf")) break :blk .keyword_neg_inf;
                    break :blk .invalid;
                },
                else => .invalid,
            };
        }

        fn matchKeyword(self: *Self, keyword: []const u8) !bool {
            // First check if keyword matches using lookahead (don't consume)
            for (keyword, 0..) |expected, i| {
                const actual = try self.peekAhead(i) orelse return false;
                if (actual != expected) return false;
            }

            // Check not followed by identifier char
            const after_keyword = try self.peekAhead(keyword.len);
            if (after_keyword) |c| {
                if (unicode.isIdentifierChar(c)) return false;
            }

            // Now consume the matched keyword
            for (keyword) |ch| {
                try self.consumeChar(ch);
            }

            return true;
        }

        fn tokenizeRawString(self: *Self) !TokenType {
            // Count additional hashes
            var hash_count: usize = 1;
            while ((try self.peek()) == @as(u8, '#')) {
                hash_count += 1;
                try self.consumeChar('#');
            }

            // Must have opening "
            const c = try self.peek() orelse return .invalid;
            if (c != '"') return .invalid;

            // Check for multiline
            const is_multiline = (try self.peekAhead(1)) == @as(u8, '"') and (try self.peekAhead(2)) == @as(u8, '"');

            if (is_multiline) {
                try self.consumeChar('"');
                try self.consumeChar('"');
                try self.consumeChar('"');

                // Find closing """###
                while (try self.peek()) |ch| {
                    if (ch == '"' and (try self.peekAhead(1)) == @as(u8, '"') and (try self.peekAhead(2)) == @as(u8, '"')) {
                        // Check matching hashes
                        var matching: usize = 0;
                        var check_idx: usize = 3;
                        while (matching < hash_count) : (check_idx += 1) {
                            if ((try self.peekAhead(check_idx)) != @as(u8, '#')) break;
                            matching += 1;
                        }

                        if (matching == hash_count) {
                            try self.consumeChar('"');
                            try self.consumeChar('"');
                            try self.consumeChar('"');
                            var i: usize = 0;
                            while (i < hash_count) : (i += 1) {
                                try self.consumeChar('#');
                            }
                            return .raw_string;
                        }
                    }

                    if (ch == '\n' or ch == '\r') {
                        if (ch == '\r') {
                            try self.consumeCRLF();
                        } else {
                            try self.consumeNewline();
                        }
                    } else {
                        try self.consumeChar(ch);
                    }
                }
            } else {
                try self.consumeChar('"');

                // Find closing "###
                while (try self.peek()) |ch| {
                    if (ch == '"') {
                        var matching: usize = 0;
                        var check_idx: usize = 1;
                        while (matching < hash_count) : (check_idx += 1) {
                            if ((try self.peekAhead(check_idx)) != @as(u8, '#')) break;
                            matching += 1;
                        }

                        if (matching == hash_count) {
                            try self.consumeChar('"');
                            var i: usize = 0;
                            while (i < hash_count) : (i += 1) {
                                try self.consumeChar('#');
                            }
                            return .raw_string;
                        }
                    }

                    if (ch == '\n' or ch == '\r') {
                        if (ch == '\r') {
                            try self.consumeCRLF();
                        } else {
                            try self.consumeNewline();
                        }
                    } else {
                        try self.consumeChar(ch);
                    }
                }
            }

            return .invalid;
        }

        fn tokenizeSlash(self: *Self) !TokenType {
            try self.consumeChar('/');

            if (try self.peek()) |c| {
                if (c == '-') {
                    try self.consumeChar('-');
                    return .slashdash;
                }
            }

            return .invalid;
        }

        fn tokenizeNumber(self: *Self) !TokenType {
            const first = try self.peek() orelse return .invalid;

            // Check for radix prefix
            if (first == '0') {
                if (try self.peekAhead(1)) |second| {
                    if (second == 'x' or second == 'X') return self.tokenizeHexNumber();
                    if (second == 'o' or second == 'O') return self.tokenizeOctalNumber();
                    if (second == 'b' or second == 'B') return self.tokenizeBinaryNumber();
                }
            }

            return self.tokenizeDecimalNumber();
        }

        fn tokenizeDecimalNumber(self: *Self) !TokenType {
            var is_float = false;

            // Integer part
            while (true) {
                // Fast path for ASCII digits
                const start_pos = self.pos;
                while (self.pos < self.input_end) {
                    const c = self.input_buffer[self.pos];
                    if (unicode.isDigit(c) or c == '_') {
                        self.pos += 1;
                        self.column += 1;
                    } else {
                        break;
                    }
                }
                
                if (self.pos > start_pos) {
                    try self.token_buffer.appendSlice(self.allocator, self.input_buffer[start_pos..self.pos]);
                }

                if (self.pos >= self.input_end and !self.reader_eof) {
                    try self.ensureData();
                    if (self.isAtEnd()) break;
                    continue;
                }

                const c = (try self.peek()) orelse break;
                if (unicode.isDigit(c) or c == '_') {
                    try self.consumeChar(c);
                } else {
                    break;
                }
            }

            // Decimal point
            if ((try self.peek()) == @as(u8, '.')) {
                if (try self.peekAhead(1)) |frac_digit| {
                    if (unicode.isDigit(frac_digit)) {
                        is_float = true;
                        try self.consumeChar('.');

                        while (try self.peek()) |c| {
                            if (unicode.isDigit(c) or c == '_') {
                                try self.consumeChar(c);
                            } else {
                                break;
                            }
                        }
                    }
                }
            }

            // Exponent
            if (try self.peek()) |c| {
                if (c == 'e' or c == 'E') {
                    is_float = true;
                    try self.consumeChar(c);

                    if (try self.peek()) |sign| {
                        if (sign == '+' or sign == '-') {
                            try self.consumeChar(sign);
                        }
                    }

                    while (try self.peek()) |d| {
                        if (unicode.isDigit(d) or d == '_') {
                            try self.consumeChar(d);
                        } else {
                            break;
                        }
                    }
                }
            }

            // Check for invalid trailing identifier
            if (try self.peek()) |c| {
                if (unicode.isIdentifierStart(c)) {
                    while (try self.peek()) |ic| {
                        if (unicode.isIdentifierChar(ic)) {
                            try self.consumeChar(ic);
                        } else {
                            break;
                        }
                    }
                    return .invalid;
                }
            }

            return if (is_float) .float else .integer;
        }

        fn tokenizeHexNumber(self: *Self) !TokenType {
            try self.consumeChar('0');
            const x = try self.peek() orelse return .invalid;
            try self.consumeChar(x);

            // First character after 0x must be a hex digit, not underscore
            const first = try self.peek() orelse return .invalid;
            if (!unicode.isHexDigit(first)) return .invalid;
            try self.consumeChar(first);

            while (try self.peek()) |c| {
                if (unicode.isHexDigit(c) or c == '_') {
                    try self.consumeChar(c);
                } else {
                    break;
                }
            }

            return .hex_integer;
        }

        fn tokenizeOctalNumber(self: *Self) !TokenType {
            try self.consumeChar('0');
            const o = try self.peek() orelse return .invalid;
            try self.consumeChar(o);

            // First character after 0o must be an octal digit, not underscore
            const first = try self.peek() orelse return .invalid;
            if (!unicode.isOctalDigit(first)) return .invalid;
            try self.consumeChar(first);

            while (try self.peek()) |c| {
                if (unicode.isOctalDigit(c) or c == '_') {
                    try self.consumeChar(c);
                } else {
                    break;
                }
            }

            return .octal_integer;
        }

        fn tokenizeBinaryNumber(self: *Self) !TokenType {
            try self.consumeChar('0');
            const b = try self.peek() orelse return .invalid;
            try self.consumeChar(b);

            // First character after 0b must be a binary digit, not underscore
            const first = try self.peek() orelse return .invalid;
            if (!unicode.isBinaryDigit(first)) return .invalid;
            try self.consumeChar(first);

            while (try self.peek()) |c| {
                if (unicode.isBinaryDigit(c) or c == '_') {
                    try self.consumeChar(c);
                } else {
                    break;
                }
            }

            return .binary_integer;
        }

        fn tokenizeSignedNumberOrIdentifier(self: *Self) !TokenType {
            const sign = try self.peek() orelse return .invalid;
            try self.consumeChar(sign);

            if (try self.peek()) |c| {
                if (unicode.isDigit(c)) {
                    return self.tokenizeDecimalNumber();
                }
            }

            return self.tokenizeIdentifierContinuation();
        }

        fn tokenizeDotOrNumber(self: *Self) !TokenType {
            try self.consumeChar('.');

            if (try self.peek()) |c| {
                if (unicode.isDigit(c)) {
                    // .5 is invalid in KDL 2.0
                    while (try self.peek()) |ic| {
                        if (unicode.isIdentifierChar(ic)) {
                            try self.consumeChar(ic);
                        } else {
                            break;
                        }
                    }
                    return .invalid;
                }
            }

            return self.tokenizeIdentifierContinuation();
        }

        fn tokenizeIdentifier(self: *Self) !TokenType {
            while (true) {
                // Fast path: scan contiguous ASCII identifier characters
                const start_pos = self.pos;
                const available = self.input_buffer[self.pos..self.input_end];
                const ascii_len = simd.findIdentifierEnd(available);
                if (ascii_len > 0) {
                    self.pos += ascii_len;
                    self.column += @intCast(ascii_len);
                }

                // Bulk append scanned ASCII
                if (self.pos > start_pos) {
                    try self.token_buffer.appendSlice(self.allocator, self.input_buffer[start_pos..self.pos]);
                }

                // If we stopped because of buffer end, ensure more data and continue
                if (self.pos >= self.input_end and !self.reader_eof) {
                    try self.ensureData();
                    // If no more data, we're done
                    if (self.isAtEnd()) break;
                    // Otherwise continue the loop (try fast path again or fallback to peekCodepoint)
                    continue;
                }

                const decoded = try self.peekCodepoint() orelse break;
                if (unicode.isIdentifierChar(decoded.codepoint)) {
                    // Safety: peekCodepoint() called ensureDataFor() for all bytes 0..len-1,
                    // guaranteeing they are in the buffer. No additional reads occur in this
                    // loop, so direct buffer access is safe.
                    var i: u3 = 0;
                    while (i < decoded.len) : (i += 1) {
                        const byte = self.input_buffer[self.pos];
                        try self.token_buffer.append(self.allocator, byte);
                        self.pos += 1;
                        self.column += 1;
                    }
                } else {
                    break;
                }
            }

            // Check for bare keywords
            const text = self.token_buffer.items;
            if (isBareKeyword(text)) {
                return .invalid;
            }

            return .identifier;
        }

        fn tokenizeIdentifierContinuation(self: *Self) !TokenType {
            while (true) {
                // Fast path: scan contiguous ASCII identifier characters
                const start_pos = self.pos;
                const available = self.input_buffer[self.pos..self.input_end];
                const ascii_len = simd.findIdentifierEnd(available);
                if (ascii_len > 0) {
                    self.pos += ascii_len;
                    self.column += @intCast(ascii_len);
                }

                if (self.pos > start_pos) {
                    try self.token_buffer.appendSlice(self.allocator, self.input_buffer[start_pos..self.pos]);
                }

                if (self.pos >= self.input_end and !self.reader_eof) {
                    try self.ensureData();
                    if (self.isAtEnd()) break;
                    continue;
                }

                const decoded = try self.peekCodepoint() orelse break;
                if (unicode.isIdentifierChar(decoded.codepoint)) {
                    // Safety: peekCodepoint() called ensureDataFor() for all bytes 0..len-1,
                    // guaranteeing they are in the buffer. No additional reads occur in this
                    // loop, so direct buffer access is safe.
                    var i: u3 = 0;
                    while (i < decoded.len) : (i += 1) {
                        const byte = self.input_buffer[self.pos];
                        try self.token_buffer.append(self.allocator, byte);
                        self.pos += 1;
                        self.column += 1;
                    }
                } else {
                    break;
                }
            }

            return .identifier;
        }

        fn isBareKeyword(text: []const u8) bool {
            const bare_keywords = [_][]const u8{ "true", "false", "null", "inf", "nan" };
            for (bare_keywords) |kw| {
                if (std.mem.eql(u8, text, kw)) return true;
            }
            return false;
        }
    };
}

/// Create a streaming tokenizer from a reader.
pub fn streamingTokenizer(allocator: Allocator, reader: anytype) !StreamingTokenizer(@TypeOf(reader)) {
    return StreamingTokenizer(@TypeOf(reader)).init(allocator, reader, DEFAULT_BUFFER_SIZE);
}

// ============================================================================
// Tests
// ============================================================================

test "streaming tokenizer basic" {
    const source = "node 42";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    const tok1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, tok1.type);
    try std.testing.expectEqualStrings("node", tokenizer.getText(tok1));

    const tok2 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.integer, tok2.type);
    try std.testing.expectEqualStrings("42", tokenizer.getText(tok2));

    const tok3 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.eof, tok3.type);
}

test "streaming tokenizer string with escapes" {
    const source = "\"hello\\nworld\"";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    const tok = try tokenizer.next();
    try std.testing.expectEqual(TokenType.quoted_string, tok.type);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", tokenizer.getText(tok));
}

test "streaming tokenizer multiline string" {
    const source =
        \\"""
        \\    hello
        \\    """
    ;
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    const tok = try tokenizer.next();
    try std.testing.expectEqual(TokenType.multiline_string, tok.type);
}

test "streaming tokenizer keywords" {
    const source = "#true #false #null #inf #-inf #nan";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    try std.testing.expectEqual(TokenType.keyword_true, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.keyword_false, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.keyword_null, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.keyword_inf, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.keyword_neg_inf, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.keyword_nan, (try tokenizer.next()).type);
}

test "streaming tokenizer punctuation" {
    const source = "(){}=;/-";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    try std.testing.expectEqual(TokenType.open_paren, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.close_paren, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.open_brace, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.close_brace, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.equals, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.semicolon, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.slashdash, (try tokenizer.next()).type);
}

test "streaming tokenizer numbers" {
    const source = "42 3.14 0xff 0o77 0b1010";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    try std.testing.expectEqual(TokenType.integer, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.float, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.hex_integer, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.octal_integer, (try tokenizer.next()).type);
    try std.testing.expectEqual(TokenType.binary_integer, (try tokenizer.next()).type);
}

test "streaming tokenizer comments" {
    const source = "node // comment\nother /* block */";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    const tok1 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, tok1.type);
    try std.testing.expectEqualStrings("node", tokenizer.getText(tok1));

    try std.testing.expectEqual(TokenType.newline, (try tokenizer.next()).type);

    const tok2 = try tokenizer.next();
    try std.testing.expectEqual(TokenType.identifier, tok2.type);
    try std.testing.expectEqualStrings("other", tokenizer.getText(tok2));
}

test "streaming tokenizer line numbers" {
    const source = "a\nb\nc";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try streamingTokenizer(std.testing.allocator, stream.reader());
    defer tokenizer.deinit();

    const tok1 = try tokenizer.next();
    try std.testing.expectEqual(@as(u32, 1), tok1.line);

    _ = try tokenizer.next(); // newline

    const tok2 = try tokenizer.next();
    try std.testing.expectEqual(@as(u32, 2), tok2.line);

    _ = try tokenizer.next(); // newline

    const tok3 = try tokenizer.next();
    try std.testing.expectEqual(@as(u32, 3), tok3.line);
}
