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

    /// Whether whitespace/comments preceded this token
    preceded_by_whitespace: bool = true,
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
        // Track if whitespace was skipped before this token
        const index_before = self.index;

        // Skip whitespace (but not newlines)
        self.skipWhitespaceAndComments();

        const preceded_by_ws = self.index > index_before;

        // Check for EOF
        if (self.index >= self.source.len) {
            var tok = self.makeToken(.eof, self.index, self.index);
            tok.preceded_by_whitespace = preceded_by_ws;
            return tok;
        }

        const start_index = self.index;
        const start_line = self.line;
        const start_column = self.column;
        const c = self.source[self.index];

        // Single-character tokens
        var token: Token = switch (c) {
            '(' => blk: {
                self.advance();
                break :blk .{
                    .type = .open_paren,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            ')' => blk: {
                self.advance();
                break :blk .{
                    .type = .close_paren,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '{' => blk: {
                self.advance();
                break :blk .{
                    .type = .open_brace,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '}' => blk: {
                self.advance();
                break :blk .{
                    .type = .close_brace,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '=' => blk: {
                self.advance();
                break :blk .{
                    .type = .equals,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            ';' => blk: {
                self.advance();
                break :blk .{
                    .type = .semicolon,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '\n' => blk: {
                self.advanceNewline();
                break :blk .{
                    .type = .newline,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '\r' => blk: {
                self.advanceCRLF();
                break :blk .{
                    .type = .newline,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '"' => self.tokenizeString(start_index, start_line, start_column),
            '#' => self.tokenizeHashPrefixed(start_index, start_line, start_column),
            '/' => self.tokenizeSlash(start_index, start_line, start_column),
            '0'...'9' => self.tokenizeNumber(start_index, start_line, start_column),
            '+', '-' => self.tokenizeSignedNumberOrIdentifier(start_index, start_line, start_column),
            '.' => self.tokenizeDotOrNumber(start_index, start_line, start_column),
            else => blk: {
                // Check for other newline characters
                if (self.isNewlineChar(c)) {
                    self.advanceNewline();
                    break :blk .{
                        .type = .newline,
                        .text = self.source[start_index..self.index],
                        .line = start_line,
                        .column = start_column,
                    };
                }

                // Try to parse as identifier - decode UTF-8 first
                const remaining = self.source[self.index..];
                if (unicode.decodeUtf8(remaining)) |decoded| {
                    if (unicode.isIdentifierStart(decoded.codepoint)) {
                        break :blk self.tokenizeIdentifier(start_index, start_line, start_column);
                    }
                }

                // Invalid character
                self.advance();
                break :blk .{
                    .type = .invalid,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
        };

        token.preceded_by_whitespace = preceded_by_ws;
        return token;
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

    /// Advance past a newline character, handling CR, LF, and CRLF uniformly.
    /// Assumes current position is at a newline character (\r or \n).
    fn advanceCRLF(self: *Tokenizer) void {
        if (self.index >= self.source.len) return;
        const c = self.source[self.index];
        if (c == '\r') {
            self.index += 1;
            // Consume following LF if present (CRLF)
            if (self.index < self.source.len and self.source[self.index] == '\n') {
                self.index += 1;
            }
        } else if (c == '\n') {
            self.index += 1;
        }
        self.line += 1;
        self.column = 1;
    }

    /// Skip whitespace after a whitespace escape (\s, \ , \t, \n, \r).
    /// Consumes all subsequent whitespace including newlines.
    fn skipWhitespaceEscape(self: *Tokenizer) void {
        while (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == ' ' or c == '\t') {
                self.advance();
            } else if (c == '\n' or c == '\r') {
                self.advanceCRLF();
            } else {
                break;
            }
        }
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

            // Skip whitespace (but not newlines) - decode UTF-8 for multi-byte whitespace
            const remaining = self.source[self.index..];
            if (unicode.decodeUtf8(remaining)) |decoded| {
                if (unicode.isWhitespace(decoded.codepoint)) {
                    // Advance by the number of bytes in this codepoint
                    var i: u3 = 0;
                    while (i < decoded.len) : (i += 1) {
                        self.advance();
                    }
                    continue;
                }
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
            } else if (c == '\n' or c == '\r') {
                self.advanceCRLF();
            } else {
                self.advance();
            }
        }
    }

    fn trySkipLineContinuation(self: *Tokenizer) bool {
        // Line continuation is: \ followed by optional whitespace, then newline
        const start = self.index;
        const start_column = self.column;

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

        // Must have a newline (or single-line comment then newline) or EOF
        if (self.index < self.source.len) {
            const c = self.source[self.index];
            if (c == '\n' or c == '\r' or self.isNewlineChar(c)) {
                self.advanceCRLF();
                return true;
            }
            // Allow single-line comment after backslash
            if (c == '/' and self.peekAhead(1) == @as(u8, '/')) {
                self.skipSingleLineComment();
                // After comment, must be at newline or EOF
                if (self.index >= self.source.len) {
                    return true; // EOF after comment is valid
                }
                const nc = self.source[self.index];
                if (nc == '\n' or nc == '\r' or self.isNewlineChar(nc)) {
                    self.advanceCRLF();
                    return true;
                }
            }
        } else {
            // EOF after backslash and optional whitespace is a valid line continuation
            return true;
        }

        // Not a valid line continuation, restore position
        self.index = start;
        self.column = start_column;
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
                // Escape sequence
                self.advance(); // Skip backslash
                if (self.index < self.source.len) {
                    const nc = self.source[self.index];
                    // Whitespace escape - skip ALL subsequent whitespace including newlines
                    if (nc == ' ' or nc == '\t' or nc == '\n' or nc == '\r') {
                        self.skipWhitespaceEscape();
                    } else {
                        // Regular escape - skip one char
                        self.advance();
                    }
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
            } else if (c == '\\') {
                // Escape sequence - skip the backslash
                self.advance();
                // Skip the escaped character if present
                if (self.index < self.source.len) {
                    const nc = self.source[self.index];
                    if (nc == '\n' or nc == '\r' or nc == ' ' or nc == '\t') {
                        // Whitespace escape - skip all subsequent whitespace
                        self.skipWhitespaceEscape();
                    } else {
                        // Regular escape - skip one char
                        self.advance();
                    }
                }
            } else if (c == '\n' or c == '\r') {
                self.advanceCRLF();
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
        switch (next_char) {
            't' => if (self.matchKeyword("true")) {
                return .{
                    .type = .keyword_true,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            'f' => if (self.matchKeyword("false")) {
                return .{
                    .type = .keyword_false,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            'n' => {
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
            },
            'i' => if (self.matchKeyword("inf")) {
                return .{
                    .type = .keyword_inf,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
            },
            '-' => {
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
            },
            else => {},
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

        // Check if it's multiline (""")
        const is_multiline = self.peekAhead(1) == @as(u8, '"') and self.peekAhead(2) == @as(u8, '"');

        if (is_multiline) {
            // Skip opening """
            self.advance();
            self.advance();
            self.advance();

            // Find closing """###
            while (self.index < self.source.len) {
                const c = self.source[self.index];
                if (c == '"' and
                    self.peekAhead(1) == @as(u8, '"') and
                    self.peekAhead(2) == @as(u8, '"'))
                {
                    // Check for matching hash count after """
                    var matching_hashes: usize = 0;
                    var check_idx = self.index + 3; // Skip """
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
                        self.column += @as(u32, @intCast(3 + hash_count));
                        return .{
                            .type = .raw_string,
                            .text = self.source[start_index..self.index],
                            .line = start_line,
                            .column = start_column,
                        };
                    }
                }

                if (c == '\n' or c == '\r') {
                    self.advanceCRLF();
                } else {
                    self.advance();
                }
            }
        } else {
            // Single-line raw string
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

                if (c == '\n' or c == '\r') {
                    self.advanceCRLF();
                } else {
                    self.advance();
                }
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

        // Check for invalid trailing identifier characters (e.g., 0n, 123abc)
        if (self.index < self.source.len) {
            const next_char = self.source[self.index];
            if (unicode.isIdentifierStart(next_char)) {
                // Consume the invalid part to provide better error
                while (self.index < self.source.len and unicode.isIdentifierChar(self.source[self.index])) {
                    self.advance();
                }
                return .{
                    .type = .invalid,
                    .text = self.source[start_index..self.index],
                    .line = start_line,
                    .column = start_column,
                };
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

        // First character after 0x must be a hex digit, not underscore
        if (self.index < self.source.len and self.source[self.index] == '_') {
            // Consume rest of invalid token
            while (self.index < self.source.len) {
                const c = self.source[self.index];
                if (unicode.isHexDigit(c) or c == '_') {
                    self.advance();
                } else {
                    break;
                }
            }
            return .{
                .type = .invalid,
                .text = self.source[start_index..self.index],
                .line = start_line,
                .column = start_column,
            };
        }

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
        // In KDL 2.0, .5 is not a valid number - must be 0.5
        // But .5 or .0 also can't be a valid identifier (looks like a number)
        // So if dot is followed by a digit, it's invalid
        self.advance(); // consume the dot
        if (self.index < self.source.len and unicode.isDigit(self.source[self.index])) {
            // Consume the rest of the number-like token
            while (self.index < self.source.len) {
                const c = self.source[self.index];
                if (unicode.isIdentifierChar(c)) {
                    self.advance();
                } else {
                    break;
                }
            }
            return .{
                .type = .invalid,
                .text = self.source[start_index..self.index],
                .line = start_line,
                .column = start_column,
            };
        }
        // Otherwise it's a valid identifier starting with dot
        return self.tokenizeIdentifierContinuation(start_index, start_line, start_column);
    }

    fn tokenizeIdentifierContinuation(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        // Continue consuming identifier characters
        while (self.index < self.source.len) {
            const remaining = self.source[self.index..];
            if (unicode.decodeUtf8(remaining)) |decoded| {
                if (unicode.isIdentifierChar(decoded.codepoint)) {
                    var i: u3 = 0;
                    while (i < decoded.len) : (i += 1) {
                        self.advance();
                    }
                } else {
                    break;
                }
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

    fn tokenizeIdentifier(self: *Tokenizer, start_index: usize, start_line: u32, start_column: u32) Token {
        // Already at first character, consume rest
        while (self.index < self.source.len) {
            // Decode UTF-8 to get the actual codepoint
            const remaining = self.source[self.index..];
            if (unicode.decodeUtf8(remaining)) |decoded| {
                if (unicode.isIdentifierChar(decoded.codepoint)) {
                    // Advance by the number of bytes in this codepoint
                    var i: u3 = 0;
                    while (i < decoded.len) : (i += 1) {
                        self.advance();
                    }
                } else {
                    break;
                }
            } else {
                // Invalid UTF-8, stop here
                break;
            }
        }

        const text = self.source[start_index..self.index];

        // KDL 2.0: bare keywords are illegal (must use # prefix)
        if (isBareKeyword(text)) {
            return .{
                .type = .invalid,
                .text = text,
                .line = start_line,
                .column = start_column,
            };
        }

        // KDL 2.0: legacy raw string syntax is illegal
        // Check if identifier is 'r' or 'R' followed by " or #
        if ((text.len == 1 and (text[0] == 'r' or text[0] == 'R'))) {
            if (self.peek()) |next_char| {
                if (next_char == '"' or next_char == '#') {
                    // Legacy raw string syntax - consume rest and return invalid
                    // Consume until we hit whitespace, newline, or end
                    while (self.index < self.source.len) {
                        const c = self.source[self.index];
                        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or
                            c == '{' or c == '}' or c == '(' or c == ')' or c == ';')
                        {
                            break;
                        }
                        self.advance();
                    }
                    return .{
                        .type = .invalid,
                        .text = self.source[start_index..self.index],
                        .line = start_line,
                        .column = start_column,
                    };
                }
            }
        }

        return .{
            .type = .identifier,
            .text = text,
            .line = start_line,
            .column = start_column,
        };
    }

    fn isBareKeyword(text: []const u8) bool {
        // KDL 2.0 bare keywords that are illegal without # prefix
        const bare_keywords = [_][]const u8{ "true", "false", "null", "inf", "nan" };
        for (bare_keywords) |kw| {
            if (std.mem.eql(u8, text, kw)) return true;
        }
        return false;
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

test "advanceCRLF handles LF" {
    var t = Tokenizer.init("a\nb");
    t.index = 1; // position at \n
    t.advanceCRLF();
    try std.testing.expectEqual(@as(usize, 2), t.index);
    try std.testing.expectEqual(@as(u32, 2), t.line);
    try std.testing.expectEqual(@as(u32, 1), t.column);
}

test "advanceCRLF handles CR" {
    var t = Tokenizer.init("a\rb");
    t.index = 1; // position at \r
    t.advanceCRLF();
    try std.testing.expectEqual(@as(usize, 2), t.index);
    try std.testing.expectEqual(@as(u32, 2), t.line);
    try std.testing.expectEqual(@as(u32, 1), t.column);
}

test "advanceCRLF handles CRLF as single newline" {
    var t = Tokenizer.init("a\r\nb");
    t.index = 1; // position at \r
    t.advanceCRLF();
    try std.testing.expectEqual(@as(usize, 3), t.index); // skipped both \r and \n
    try std.testing.expectEqual(@as(u32, 2), t.line);
    try std.testing.expectEqual(@as(u32, 1), t.column);
}

test "skipWhitespaceEscape skips spaces and tabs" {
    var t = Tokenizer.init("\\   \t  x");
    t.index = 1; // position after backslash at first space
    t.skipWhitespaceEscape();
    try std.testing.expectEqual(@as(usize, 7), t.index); // at 'x'
}

test "skipWhitespaceEscape skips across newlines" {
    var t = Tokenizer.init("\\\n   x");
    t.index = 1; // position at \n
    t.skipWhitespaceEscape();
    try std.testing.expectEqual(@as(usize, 5), t.index); // at 'x'
    try std.testing.expectEqual(@as(u32, 2), t.line);
}

test "skipWhitespaceEscape skips CRLF and following whitespace" {
    var t = Tokenizer.init("\\\r\n  x");
    t.index = 1; // position at \r
    t.skipWhitespaceEscape();
    try std.testing.expectEqual(@as(usize, 5), t.index); // at 'x'
    try std.testing.expectEqual(@as(u32, 2), t.line);
}

test "invalid line continuation restores column" {
    var t = Tokenizer.init(" \\x");
    const tok = t.next();
    try std.testing.expectEqual(TokenType.invalid, tok.type);
    try std.testing.expectEqual(@as(u32, 1), tok.line);
    try std.testing.expectEqual(@as(u32, 2), tok.column);
}
