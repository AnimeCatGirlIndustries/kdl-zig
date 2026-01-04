/// KDL 2.0.0 Tokenizer
/// Lexes KDL source into tokens for parsing.
const std = @import("std");
const unicode = @import("unicode.zig");

/// Types of tokens produced by the tokenizer
pub const TokenType = enum {
    // Identifiers and strings
    identifier,
    quoted_string,
    raw_string,
    multiline_string,

    // Numbers
    integer,
    float,
    hex_integer,
    octal_integer,
    binary_integer,

    // Keywords (KDL 2.0 uses # prefix)
    keyword_true,
    keyword_false,
    keyword_null,
    keyword_inf,
    keyword_neg_inf,
    keyword_nan,

    // Punctuation
    open_paren,
    close_paren,
    open_brace,
    close_brace,
    equals,
    semicolon,

    // Special
    slashdash,
    newline,
    eof,
    invalid,
};

/// A token produced by the tokenizer
pub const Token = struct {
    /// The type of this token
    type: TokenType,

    /// The raw text of the token (slice into source)
    text: []const u8,

    /// Line number (1-indexed)
    line: u32,

    /// Column number (1-indexed)
    column: u32,
};

/// Tokenizer for KDL 2.0.0 documents.
/// Zero-allocation design - tokens reference slices into the source buffer.
pub const Tokenizer = struct {
    /// Source buffer being tokenized
    source: []const u8,

    /// Current byte index into source
    index: usize,

    /// Current line number (1-indexed)
    line: u32,

    /// Current column number (1-indexed)
    column: u32,

    /// Whether we've seen BOM at start
    seen_bom: bool,

    /// Initialize a tokenizer for the given source
    pub fn init(source: []const u8) Tokenizer {
        var t = Tokenizer{
            .source = source,
            .index = 0,
            .line = 1,
            .column = 1,
            .seen_bom = false,
        };

        // Skip BOM if present at start
        if (source.len >= 3 and
            source[0] == 0xEF and
            source[1] == 0xBB and
            source[2] == 0xBF)
        {
            t.index = 3;
            t.seen_bom = true;
        }

        return t;
    }

    /// Get the next token from the source
    pub fn next(self: *Tokenizer) Token {
        // Skip whitespace (but not newlines)
        self.skipWhitespaceAndComments();

        // Check for EOF
        if (self.index >= self.source.len) {
            return self.makeToken(.eof, self.index, self.index);
        }

        const start_index = self.index;
        const start_line = self.line;
        const start_column = self.column;
        const c = self.source[self.index];

        // Single-character tokens
        switch (c) {
            '(' => {
                self.advance();
                return .{
                    .type = .open_paren,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            ')' => {
                self.advance();
                return .{
                    .type = .close_paren,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '{' => {
                self.advance();
                return .{
                    .type = .open_brace,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '}' => {
                self.advance();
                return .{
                    .type = .close_brace,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '=' => {
                self.advance();
                return .{
                    .type = .equals,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            ';' => {
                self.advance();
                return .{
                    .type = .semicolon,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '\n' => {
                self.advanceNewline();
                return .{
                    .type = .newline,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '\r' => {
                self.advance();
                // Handle CRLF as single newline
                if (self.index < self.source.len and self.source[self.index] == '\n') {
                    self.advance();
                }
                self.line += 1;
                self.column = 1;
                return .{
                    .type = .newline,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '"' => return self.tokenizeString(start_index, start_line, start_column),
            '#' => return self.tokenizeHashPrefixed(start_index, start_line, start_column),
            '/' => return self.tokenizeSlash(start_index, start_line, start_column),
            '0'...'9' => return self.tokenizeNumber(start_index, start_line, start_column),
            '+', '-' => return self.tokenizeSignedNumberOrIdentifier(start_index, start_line, start_column),
            '.' => return self.tokenizeDotOrNumber(start_index, start_line, start_column),
            else => {
                // Check for other newline characters
                if (self.isNewlineChar(c)) {
                    self.advanceNewline();
                    return .{
                        .type = .newline,
                        .text = self.source[start_index..self.index],
                        .line = start_line,
                        .column = start_column,
                    };
                }

                // Try to parse as identifier
                if (unicode.isIdentifierStart(c)) {
                    return self.tokenizeIdentifier(start_index, start_line, start_column);
                }

                // Invalid character
                self.advance();
                return .{
                    .type = .invalid,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
        }
    }

    // --- Helper functions ---

    fn advance(self: *Tokenizer) void {
        if (self.index < self.source.len) {
            self.index += 1;
            self.column += 1;
        }
    }

    fn advanceNewline(self: *Tokenizer) void {
        self.index += 1;
        self.line += 1;
        self.column = 1;
    }

    fn peek(self: *Tokenizer) ?u8 {
        if (self.index < self.source.len) {
            return self.source[self.index];
        }
        return null;
    }

    fn peekAhead(self: *Tokenizer, offset: usize) ?u8 {
        const idx = self.index + offset;
        if (idx < self.source.len) {
            return self.source[idx];
        }
        return null;
    }

    fn isNewlineChar(self: *Tokenizer, c: u8) bool {
        _ = self;
        return switch (c) {
            '\n', '\r', 0x0B, 0x0C => true,
            else => false,
        };
    }

    fn makeToken(self: *Tokenizer, token_type: TokenType, start: usize, end: usize) Token {
        return .{
            .type = token_type,
            .text = self.source[start..end],
            .line = self.line,
            .column = self.column,
        };
    }

    fn skipWhitespaceAndComments(self: *Tokenizer) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];

            // Skip whitespace (but not newlines)
            if (unicode.isWhitespace(c)) {
                self.advance();
                continue;
            }

            // Check for comments (but not slashdash)
            if (c == '/') {
                if (self.peekAhead(1)) |next_char| {
                    if (next_char == '/') {
                        // Single-line comment - skip to end of line
                        self.skipSingleLineComment();
                        continue;
                    } else if (next_char == '*') {
                        // Multi-line comment
                        self.skipMultiLineComment();
                        continue;
                    }
                }
            }

            // Check for line continuation (backslash followed by whitespace/newline)
            if (c == '\\') {
                if (self.trySkipLineContinuation()) {
                    continue;
                }
            }

            break;
        }
    }

    fn skipSingleLineComment(self: *Tokenizer) void {
        // Skip the //
        self.advance();
        self.advance();

        // Skip until newline (but don't consume the newline)
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '\n' or c == '\r' or self.isNewlineChar(c)) {
                break;
            }
            self.advance();
        }
    }

    fn skipMultiLineComment(self: *Tokenizer) void {
        // Skip the /*
        self.advance();
        self.advance();

        var depth: u32 = 1;
        while (self.index < self.source.len and depth > 0) {
            const c = self.source[self.index];

            if (c == '/' and self.peekAhead(1) == @as(u8, '*')) {
                depth += 1;
                self.advance();
                self.advance();
            } else if (c == '*' and self.peekAhead(1) == @as(u8, '/')) {
                depth -= 1;
                self.advance();
                self.advance();
            } else if (c == '\n') {
                self.advanceNewline();
            } else if (c == '\r') {
                self.advance();
                if (self.peek() == @as(u8, '\n')) {
                    self.advance();
                }
                self.line += 1;
                self.column = 1;
            } else {
                self.advance();
            }
        }
    }

    fn trySkipLineContinuation(self: *Tokenizer) bool {
        // Line continuation is: \ followed by optional whitespace, then newline
        const start = self.index;

        // Skip the backslash
        self.index += 1;
        self.column += 1;

        // Skip optional whitespace
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (unicode.isWhitespace(c)) {
                self.advance();
            } else {
                break;
            }
        }

        // Must have a newline (or single-line comment then newline)
        if (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '\n' or c == '\r' or self.isNewlineChar(c)) {
                if (c == '\r') {
                    self.advance();
                    if (self.peek() == @as(u8, '\n')) {
                        self.advance();
                    }
                    self.line += 1;
                    self.column = 1;
                } else {
                    self.advanceNewline();
                }
                return true;
            }
            // Allow single-line comment after backslash
            if (c == '/' and self.peekAhead(1) == @as(u8, '/')) {
                self.skipSingleLineComment();
                // After comment, must be at newline
                if (self.index < self.source.len) {
                    const nc = self.source[self.index];
                    if (nc == '\n' or nc == '\r' or self.isNewlineChar(nc)) {
                        if (nc == '\r') {
                            self.advance();
                            if (self.peek() == @as(u8, '\n')) {
                                self.advance();
                            }
                            self.line += 1;
                            self.column = 1;
                        } else {
                            self.advanceNewline();
                        }
                        return true;
                    }
                }
            }
        }

        // Not a valid line continuation, restore position
        self.index = start;
        self.column = self.column - @as(u32, @intCast(self.index - start + 1)) + 1;
        return false;
    }

    fn tokenizeString(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        // Check for multiline string (""")
        if (self.peekAhead(1) == @as(u8, '"') and self.peekAhead(2) == @as(u8, '"')) {
            return self.tokenizeMultilineString(start_index, start_line, start_column);
        }

        // Regular quoted string
        self.advance(); // Skip opening "

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '"') {
                self.advance(); // Skip closing "
                break;
            } else if (c == '\\') {
                // Escape sequence - skip the backslash and next char
                self.advance();
                if (self.index < self.source.len) {
                    self.advance();
                }
            } else if (c == '\n' or c == '\r') {
                // Unescaped newline in quoted string is invalid
                // Return what we have as invalid
                return .{
                    .type = .invalid,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            } else {
                self.advance();
            }
        }

        return .{
            .type = .quoted_string,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeMultilineString(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        // Skip the opening """
        self.advance();
        self.advance();
        self.advance();

        // Find closing """
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '"' and
                self.peekAhead(1) == @as(u8, '"') and
                self.peekAhead(2) == @as(u8, '"'))
            {
                self.advance();
                self.advance();
                self.advance();
                break;
            } else if (c == '\n') {
                self.advanceNewline();
            } else if (c == '\r') {
                self.advance();
                if (self.peek() == @as(u8, '\n')) {
                    self.advance();
                }
                self.line += 1;
                self.column = 1;
            } else {
                self.advance();
            }
        }

        return .{
            .type = .multiline_string,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeHashPrefixed(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        self.advance(); // Skip #

        // Check what follows the #
        if (self.index >= self.source.len) {
            return .{
                .type = .invalid,
                .text = self.source[start_index..self.index],
                .line = start_line,
                .column = start_column,
            };
        }

        const next_char = self.source[self.index];

        // Raw string: #"..."# or ##"..."## etc.
        if (next_char == '"' or next_char == '#') {
            return self.tokenizeRawString(start_index, start_line, start_column);
        }

        // Keywords: #true, #false, #null, #inf, #-inf, #nan
        if (next_char == 't') {
            if (self.matchKeyword("true")) {
                return .{
                    .type = .keyword_true,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            }
        } else if (next_char == 'f') {
            if (self.matchKeyword("false")) {
                return .{
                    .type = .keyword_false,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            }
        } else if (next_char == 'n') {
            if (self.matchKeyword("null")) {
                return .{
                    .type = .keyword_null,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            }
            if (self.matchKeyword("nan")) {
                return .{
                    .type = .keyword_nan,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            }
        } else if (next_char == 'i') {
            if (self.matchKeyword("inf")) {
                return .{
                    .type = .keyword_inf,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            }
        } else if (next_char == '-') {
            // Check for #-inf
            self.advance(); // Skip -
            if (self.matchKeyword("inf")) {
                return .{
                    .type = .keyword_neg_inf,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            }
            // Not #-inf, treat as invalid
            return .{
                .type = .invalid,
                .text = self.source[start_index..self.index],
                .line = start_line,
                .column = start_column,
            };
        }

        // Invalid # sequence
        return .{
            .type = .invalid,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn matchKeyword(self: *Tokenizer, keyword: []const u8) bool {
        const remaining = self.source.len - self.index;
        if (remaining < keyword.len) return false;

        if (std.mem.eql(u8, self.source[self.index .. self.index + keyword.len], keyword)) {
            // Check that keyword is not followed by identifier char
            const end = self.index + keyword.len;
            if (end < self.source.len) {
                const following = self.source[end];
                if (unicode.isIdentifierChar(following)) {
                    return false;
                }
            }
            self.index += keyword.len;
            self.column += @as(u32, @intCast(keyword.len));
            return true;
        }
        return false;
    }

    fn tokenizeRawString(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        // Count additional # characters
        var hash_count: usize = 1; // We already consumed one #
        while (self.index < self.source.len and self.source[self.index] == '#') {
            hash_count += 1;
            self.advance();
        }

        // Must have opening "
        if (self.index >= self.source.len or self.source[self.index] != '"') {
            return .{
                .type = .invalid,
                .text = self.source[start_index..self.index],
                .line = start_line,
                .column = start_column,
            };
        }
        self.advance(); // Skip opening "

        // Find closing "###
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '"') {
                // Check for matching hash count
                var matching_hashes: usize = 0;
                var check_idx = self.index + 1;
                while (check_idx < self.source.len and
                    self.source[check_idx] == '#' and
                    matching_hashes < hash_count)
                {
                    matching_hashes += 1;
                    check_idx += 1;
                }

                if (matching_hashes == hash_count) {
                    // Found closing delimiter
                    self.index = check_idx;
                    self.column += @as(u32, @intCast(1 + hash_count));
                    return .{
                        .type = .raw_string,
                        .text = self.source[start_index..self.index],
                        .line = start_line,
                        .column = start_column,
                    };
                }
            }

            if (c == '\n') {
                self.advanceNewline();
            } else if (c == '\r') {
                self.advance();
                if (self.peek() == @as(u8, '\n')) {
                    self.advance();
                }
                self.line += 1;
                self.column = 1;
            } else {
                self.advance();
            }
        }

        // Unclosed raw string
        return .{
            .type = .invalid,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeSlash(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        self.advance(); // Skip /

        if (self.index < self.source.len) {
            const next_char = self.source[self.index];
            if (next_char == '-') {
                // Slashdash
                self.advance();
                return .{
                    .type = .slashdash,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            }
            // Note: // and /* are handled in skipWhitespaceAndComments
            // If we get here, it's a bare / which is invalid
        }

        return .{
            .type = .invalid,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeNumber(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        const first = self.source[self.index];

        // Check for 0x, 0o, 0b prefixes
        if (first == '0' and self.index + 1 < self.source.len) {
            const second = self.source[self.index + 1];
            if (second == 'x' or second == 'X') {
                return self.tokenizeHexNumber(start_index, start_line, start_column);
            } else if (second == 'o' or second == 'O') {
                return self.tokenizeOctalNumber(start_index, start_line, start_column);
            } else if (second == 'b' or second == 'B') {
                return self.tokenizeBinaryNumber(start_index, start_line, start_column);
            }
        }

        return self.tokenizeDecimalNumber(start_index, start_line, start_column);
    }

    fn tokenizeDecimalNumber(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        var is_float = false;

        // Consume integer part
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (unicode.isDigit(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        // Check for decimal point
        if (self.index < self.source.len and self.source[self.index] == '.') {
            // Look ahead to make sure it's followed by digit (not .something)
            if (self.index + 1 < self.source.len and unicode.isDigit(self.source[self.index + 1])) {
                is_float = true;
                self.advance(); // Skip .

                // Consume fractional part
                while (self.index < self.source.len) {
                    const c = self.source[self.index];
                    if (unicode.isDigit(c) or c == '_') {
                        self.advance();
                    } else {
                        break;
                    }
                }
            }
        }

        // Check for exponent
        if (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == 'e' or c == 'E') {
                is_float = true;
                self.advance(); // Skip e/E

                // Optional sign
                if (self.index < self.source.len) {
                    const sign = self.source[self.index];
                    if (sign == '+' or sign == '-') {
                        self.advance();
                    }
                }

                // Exponent digits
                while (self.index < self.source.len) {
                    const d = self.source[self.index];
                    if (unicode.isDigit(d) or d == '_') {
                        self.advance();
                    } else {
                        break;
                    }
                }
            }
        }

        return .{
            .type = if (is_float) .float else .integer,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeHexNumber(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        self.advance(); // Skip 0
        self.advance(); // Skip x

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (unicode.isHexDigit(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        return .{
            .type = .hex_integer,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeOctalNumber(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        self.advance(); // Skip 0
        self.advance(); // Skip o

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (unicode.isOctalDigit(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        return .{
            .type = .octal_integer,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeBinaryNumber(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        self.advance(); // Skip 0
        self.advance(); // Skip b

        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (unicode.isBinaryDigit(c) or c == '_') {
                self.advance();
            } else {
                break;
            }
        }

        return .{
            .type = .binary_integer,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }

    fn tokenizeSignedNumberOrIdentifier(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        self.advance(); // Skip + or -

        // If followed by digit, it's a number
        if (self.index < self.source.len and unicode.isDigit(self.source[self.index])) {
            return self.tokenizeNumber(start_index, start_line, start_column);
        }

        // Otherwise it's an identifier starting with + or -
        return self.tokenizeIdentifier(start_index, start_line, start_column);
    }

    fn tokenizeDotOrNumber(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        // In KDL, .5 is not a valid number - must be 0.5
        // So a leading dot is part of an identifier
        return self.tokenizeIdentifier(start_index, start_line, start_column);
    }

    fn tokenizeIdentifier(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        // Already at first character, consume rest
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (unicode.isIdentifierChar(c)) {
                self.advance();
            } else {
                break;
            }
        }

        return .{
            .type = .identifier,
            .text = self.source[start_index..self.index],
            .line = start_line,
            .column = start_column,
        };
    }
};

// Basic tests for token types
test "TokenType enum" {
    const t: TokenType = .identifier;
    try std.testing.expectEqual(TokenType.identifier, t);
}

test "Token struct" {
    const token = Token{
        .type = .identifier,
        .text = "test",
        .line = 1,
        .column = 1,
    };
    try std.testing.expectEqualStrings("test", token.text);
}
