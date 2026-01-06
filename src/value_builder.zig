/// One-Shot Value Builder for Streaming IR
///
/// Processes token text (with quotes, escapes, delimiters) and writes
/// resolved values directly to StringPool. Returns StringRef, never
/// borrowed slices - eliminates ownership ambiguity.
///
/// Key differences from strings.zig:
/// - Always writes to pool (no borrowed vs allocated distinction)
/// - Returns StringRef for pool lookup
/// - Integrated escape processing during write
const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");
const stream_types = @import("stream_types.zig");
const StringPool = stream_types.StringPool;
const StringRef = stream_types.StringRef;
const constants = @import("constants.zig");

pub const Error = error{
    InvalidString,
    InvalidEscape,
    OutOfMemory,
};

/// Build a quoted string value, processing escapes and writing to pool.
/// Input: `"hello\nworld"` (with quotes)
/// Output: StringRef to `hello\nworld` (with actual newline)
pub fn buildQuotedString(pool: *StringPool, text: []const u8) Error!StringRef {
    if (text.len < 2) return Error.InvalidString;
    const content = text[1 .. text.len - 1];
    return buildEscapedContent(pool, content);
}

/// Build a raw string value, stripping delimiters.
/// Input: `#"hello"#` or `##"world"##`
/// Output: StringRef to raw content
pub fn buildRawString(pool: *StringPool, text: []const u8) Error!StringRef {
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
        return buildMultilineRawString(pool, text, hash_count);
    }

    // Single-line raw string: #"..."#
    const start = hash_count + 1;
    const end = text.len - hash_count - 1;
    if (start > end) return Error.InvalidString;
    const content = text[start..end];

    // Single-line raw strings cannot contain newlines
    if (std.mem.indexOfAny(u8, content, "\n\r") != null) {
        return Error.InvalidString;
    }

    // Write directly to pool (no escape processing for raw strings)
    return pool.add(content) catch return Error.OutOfMemory;
}

/// Build a multiline string value, processing escapes and dedenting.
/// Input: `"""..."""` (with quotes)
///
/// Processing order (per KDL spec):
/// 1. Analyze raw content for structure (line boundaries, whitespace-only status)
/// 2. Handle line continuations (\<newline>) - joins lines, affects structure
/// 3. Validate dedent prefixes on the joined structure
/// 4. Dedent and process remaining escapes (\n, \t, etc.) - affects VALUE only
pub fn buildMultilineString(pool: *StringPool, text: []const u8) Error!StringRef {
    if (text.len < 6) return Error.InvalidString;
    const raw_content = text[3 .. text.len - 3];

    // Must contain at least one newline
    if (std.mem.indexOfAny(u8, raw_content, "\n\r") == null) {
        return Error.InvalidString;
    }

    // Analyze raw content: count lines and track whitespace-only status
    var raw_lines = LineScanner.init(raw_content);
    _ = raw_lines.next(); // Skip first line (after opening """)

    var raw_line_count: usize = 0;
    var raw_ws_only_flags = std.StaticBitSet(constants.MAX_TRACKED_LINES).initEmpty();
    var raw_last_line: []const u8 = "";

    while (raw_lines.next()) |line| {
        const is_ws_only = isWhitespaceOnly(line);
        if (raw_line_count < constants.MAX_TRACKED_LINES and is_ws_only) {
            raw_ws_only_flags.set(raw_line_count);
        }
        raw_last_line = line;
        raw_line_count += 1;
    }

    if (raw_line_count == 0) return Error.InvalidString;

    // Find the last content line (if any) to check for backslash ending
    var last_content_line: []const u8 = "";
    var content_line_count: usize = 0;
    {
        var temp_lines = LineScanner.init(raw_content);
        _ = temp_lines.next(); // Skip first line
        var temp_idx: usize = 0;
        while (temp_lines.next()) |line| : (temp_idx += 1) {
            if (temp_idx == raw_line_count - 1) break; // Don't include dedent line
            last_content_line = line;
            content_line_count = temp_idx + 1;
        }
    }

    // Process escapes on the dedent line
    var dedent_buf: std.ArrayListUnmanaged(u8) = .{};
    defer dedent_buf.deinit(pool.allocator);
    writeEscapedContentToBuf(&dedent_buf, pool.allocator, raw_last_line) catch return Error.OutOfMemory;

    // If last content line ends with backslash, it joins with the dedent line
    // The effective dedent becomes: stripped_content + processed_dedent_line
    var effective_dedent_buf: std.ArrayListUnmanaged(u8) = .{};
    defer effective_dedent_buf.deinit(pool.allocator);

    const last_content_ends_with_backslash = content_line_count > 0 and endsWithBackslash(last_content_line);

    if (last_content_ends_with_backslash) {
        // Strip backslash and trailing whitespace from last content line
        const stripped = stripTrailingBackslash(last_content_line);
        // The effective dedent is: stripped content (no escapes) + processed dedent line
        // Note: we DON'T process escapes on stripped content because the backslash
        // at the end was the escape sequence, not part of content escapes
        effective_dedent_buf.appendSlice(pool.allocator, stripped) catch return Error.OutOfMemory;
        effective_dedent_buf.appendSlice(pool.allocator, dedent_buf.items) catch return Error.OutOfMemory;
    } else {
        effective_dedent_buf.appendSlice(pool.allocator, dedent_buf.items) catch return Error.OutOfMemory;
    }

    const effective_dedent = effective_dedent_buf.items;

    // Effective dedent must be whitespace-only
    if (!isWhitespaceOnly(effective_dedent)) return Error.InvalidString;

    // The dedent prefix is the effective dedent content
    const dedent_prefix = effective_dedent;

    // Adjust content line count if last content became part of dedent
    const actual_content_count = if (last_content_ends_with_backslash and content_line_count > 0)
        content_line_count - 1
    else
        content_line_count;

    // Validate prefixes on content lines
    raw_lines = LineScanner.init(raw_content);
    _ = raw_lines.next();

    var prev_is_continuation = false;
    var raw_idx: usize = 0;

    while (raw_lines.next()) |line| : (raw_idx += 1) {
        // Skip dedent line and the line that became dedent (if any)
        if (raw_idx >= actual_content_count) break;

        if (prev_is_continuation) {
            prev_is_continuation = endsWithBackslash(line);
            continue;
        }
        prev_is_continuation = endsWithBackslash(line);

        // Whitespace-only lines don't need prefix
        if (raw_idx < constants.MAX_TRACKED_LINES and raw_ws_only_flags.isSet(raw_idx)) continue;

        // Content lines must have dedent prefix
        if (dedent_prefix.len > 0 and !std.mem.startsWith(u8, line, dedent_prefix)) {
            return Error.InvalidString;
        }
    }

    // Build output: dedent lines and process escapes
    const pool_start = pool.data.items.len;

    raw_lines = LineScanner.init(raw_content);
    _ = raw_lines.next(); // Skip first line

    raw_idx = 0;
    var first_content_line = true;
    prev_is_continuation = false;

    while (raw_lines.next()) |line| : (raw_idx += 1) {
        // Skip lines that are dedent or became part of dedent
        if (raw_idx >= actual_content_count) break;

        // Handle line continuation from previous line
        if (prev_is_continuation) {
            // This line's content (after backslash consumed whitespace) joins previous
            // Find where non-whitespace starts
            var content_start: usize = 0;
            while (content_start < line.len) {
                const decoded = unicode.decodeUtf8(line[content_start..]) orelse break;
                if (!unicode.isWhitespace(decoded.codepoint)) break;
                content_start += decoded.len;
            }
            // Append non-whitespace content with escape processing
            try writeEscapedContent(pool, line[content_start..]);
            prev_is_continuation = endsWithBackslash(line);
            continue;
        }

        // Check if this line ends with backslash (line continuation)
        const is_continuation = endsWithBackslash(line);
        prev_is_continuation = is_continuation;

        // Add newline between content lines (not after continuations)
        if (!first_content_line) {
            pool.data.append(pool.allocator, '\n') catch return Error.OutOfMemory;
        }
        first_content_line = false;

        // Check whitespace-only status from raw flags
        const is_ws_only = raw_idx < constants.MAX_TRACKED_LINES and raw_ws_only_flags.isSet(raw_idx);
        if (is_ws_only) continue; // Whitespace-only lines become empty

        // Dedent the line
        const dedented = if (std.mem.startsWith(u8, line, dedent_prefix))
            line[dedent_prefix.len..]
        else
            line;

        // For continuation lines, strip the trailing backslash and whitespace before it
        const content = if (is_continuation)
            stripTrailingBackslash(dedented)
        else
            dedented;

        // Process escapes and write to pool
        try writeEscapedContent(pool, content);
    }

    const pool_end = pool.data.items.len;
    return StringRef{
        .offset = @intCast(pool_start),
        .len = @intCast(pool_end - pool_start),
    };
}

/// Strip trailing backslash (and any whitespace before it) from a line.
fn stripTrailingBackslash(line: []const u8) []const u8 {
    var i: usize = line.len;
    while (i > 0) {
        var char_start = i - 1;
        while (char_start > 0 and (line[char_start] & 0xC0) == 0x80) {
            char_start -= 1;
        }

        const decoded = unicode.decodeUtf8(line[char_start..i]) orelse {
            if (line[char_start] == '\\') return line[0..char_start];
            return line;
        };

        if (decoded.codepoint == '\\') return line[0..char_start];
        if (!unicode.isWhitespace(decoded.codepoint)) return line;
        i = char_start;
    }
    return line;
}

/// Build a multiline raw string value, dedenting without escape processing.
fn buildMultilineRawString(pool: *StringPool, text: []const u8, hash_count: usize) Error!StringRef {
    const start = hash_count + 3;
    const end = text.len - hash_count - 3;
    if (start >= end) return Error.InvalidString;
    const content = text[start..end];

    // Must contain at least one newline
    if (std.mem.indexOfAny(u8, content, "\n\r") == null) {
        return Error.InvalidString;
    }

    // Analyze for dedent
    var lines = LineScanner.init(content);
    _ = lines.next(); // Skip first line

    var line_count: usize = 0;
    var last_line: []const u8 = "";
    while (lines.next()) |line| {
        last_line = line;
        line_count += 1;
    }

    if (line_count == 0) return Error.InvalidString;
    if (!isWhitespaceOnly(last_line)) return Error.InvalidString;
    const dedent_prefix = getWhitespacePrefix(last_line);

    // Validate prefixes
    lines = LineScanner.init(content);
    _ = lines.next();

    var idx: usize = 0;
    while (lines.next()) |line| : (idx += 1) {
        if (idx == line_count - 1) break;
        if (isWhitespaceOnly(line)) continue;
        if (dedent_prefix.len > 0 and !std.mem.startsWith(u8, line, dedent_prefix)) {
            return Error.InvalidString;
        }
    }

    // Write dedented content to pool (no escapes for raw strings)
    const pool_start = pool.data.items.len;

    lines = LineScanner.init(content);
    _ = lines.next();

    idx = 0;
    var first_content_line = true;
    while (lines.next()) |line| : (idx += 1) {
        if (idx == line_count - 1) break;

        if (!first_content_line) {
            pool.data.append(pool.allocator, '\n') catch return Error.OutOfMemory;
        }
        first_content_line = false;

        if (isWhitespaceOnly(line)) continue;

        const dedented = if (std.mem.startsWith(u8, line, dedent_prefix))
            line[dedent_prefix.len..]
        else
            line;

        pool.data.appendSlice(pool.allocator, dedented) catch return Error.OutOfMemory;
    }

    const pool_end = pool.data.items.len;
    return StringRef{
        .offset = @intCast(pool_start),
        .len = @intCast(pool_end - pool_start),
    };
}

/// Build an identifier value (copy as-is to pool).
pub fn buildIdentifier(pool: *StringPool, text: []const u8) Error!StringRef {
    return pool.add(text) catch return Error.OutOfMemory;
}

/// Build escaped content and write directly to pool.
/// Returns StringRef to the written content.
fn buildEscapedContent(pool: *StringPool, content: []const u8) Error!StringRef {
    const pool_start = pool.data.items.len;
    try writeEscapedContent(pool, content);
    const pool_end = pool.data.items.len;
    return StringRef{
        .offset = @intCast(pool_start),
        .len = @intCast(pool_end - pool_start),
    };
}

/// Generic escape writer interface for deduplicating escape processing logic.
const EscapeWriter = struct {
    appendFn: *const fn (*EscapeWriter, u8) Allocator.Error!void,
    appendSliceFn: *const fn (*EscapeWriter, []const u8) Allocator.Error!void,

    /// Write content with escape processing to any target supporting the writer interface.
    fn writeEscapedContent(self: *EscapeWriter, content: []const u8) Error!void {
        var i: usize = 0;
        while (i < content.len) {
            if (content[i] == '\\' and i + 1 < content.len) {
                i += 1;
                switch (content[i]) {
                    'n' => {
                        self.appendFn(self, '\n') catch return Error.OutOfMemory;
                        i += 1;
                    },
                    'r' => {
                        self.appendFn(self, '\r') catch return Error.OutOfMemory;
                        i += 1;
                    },
                    't' => {
                        self.appendFn(self, '\t') catch return Error.OutOfMemory;
                        i += 1;
                    },
                    '\\' => {
                        self.appendFn(self, '\\') catch return Error.OutOfMemory;
                        i += 1;
                    },
                    '"' => {
                        self.appendFn(self, '"') catch return Error.OutOfMemory;
                        i += 1;
                    },
                    'b' => {
                        self.appendFn(self, 0x08) catch return Error.OutOfMemory;
                        i += 1;
                    },
                    'f' => {
                        self.appendFn(self, 0x0C) catch return Error.OutOfMemory;
                        i += 1;
                    },
                    's' => {
                        self.appendFn(self, ' ') catch return Error.OutOfMemory;
                        i += 1;
                    },
                    'u' => {
                        // Unicode escape: \u{XXXX}
                        i += 1;
                        if (i >= content.len or content[i] != '{') {
                            return Error.InvalidEscape;
                        }
                        i += 1;

                        const esc_start = i;
                        while (i < content.len and content[i] != '}') {
                            i += 1;
                        }
                        if (i >= content.len) return Error.InvalidEscape;

                        const hex = content[esc_start..i];
                        if (hex.len == 0 or hex.len > 6) return Error.InvalidEscape;

                        const codepoint = std.fmt.parseInt(u21, hex, 16) catch return Error.InvalidEscape;
                        i += 1; // Skip }

                        // Validate: surrogates are not valid
                        if (unicode.isSurrogate(codepoint)) {
                            return Error.InvalidEscape;
                        }

                        // Encode as UTF-8
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(codepoint, &buf) catch return Error.InvalidEscape;
                        self.appendSliceFn(self, buf[0..len]) catch return Error.OutOfMemory;
                    },
                    '\n', '\r', ' ', '\t' => {
                        // Whitespace escape - skip all subsequent whitespace
                        while (i < content.len) {
                            const decoded = unicode.decodeUtf8(content[i..]) orelse break;
                            if (unicode.isWhitespace(decoded.codepoint) or unicode.isNewline(decoded.codepoint)) {
                                i += decoded.len;
                            } else {
                                break;
                            }
                        }
                    },
                    else => return Error.InvalidEscape,
                }
            } else {
                self.appendFn(self, content[i]) catch return Error.OutOfMemory;
                i += 1;
            }
        }
    }
};

/// Escape writer backed by a StringPool.
const PoolEscapeWriter = struct {
    base: EscapeWriter,
    pool: *StringPool,

    fn init(pool: *StringPool) PoolEscapeWriter {
        return .{
            .base = .{
                .appendFn = append,
                .appendSliceFn = appendSlice,
            },
            .pool = pool,
        };
    }

    fn append(base: *EscapeWriter, byte: u8) Allocator.Error!void {
        const self: *PoolEscapeWriter = @fieldParentPtr("base", base);
        try self.pool.data.append(self.pool.allocator, byte);
    }

    fn appendSlice(base: *EscapeWriter, slice: []const u8) Allocator.Error!void {
        const self: *PoolEscapeWriter = @fieldParentPtr("base", base);
        try self.pool.data.appendSlice(self.pool.allocator, slice);
    }
};

/// Escape writer backed by an ArrayListUnmanaged.
const BufEscapeWriter = struct {
    base: EscapeWriter,
    buf: *std.ArrayListUnmanaged(u8),
    allocator: Allocator,

    fn init(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator) BufEscapeWriter {
        return .{
            .base = .{
                .appendFn = append,
                .appendSliceFn = appendSlice,
            },
            .buf = buf,
            .allocator = allocator,
        };
    }

    fn append(base: *EscapeWriter, byte: u8) Allocator.Error!void {
        const self: *BufEscapeWriter = @fieldParentPtr("base", base);
        try self.buf.append(self.allocator, byte);
    }

    fn appendSlice(base: *EscapeWriter, slice: []const u8) Allocator.Error!void {
        const self: *BufEscapeWriter = @fieldParentPtr("base", base);
        try self.buf.appendSlice(self.allocator, slice);
    }
};

/// Write content with escape processing directly to pool.
fn writeEscapedContent(pool: *StringPool, content: []const u8) Error!void {
    var writer = PoolEscapeWriter.init(pool);
    try writer.base.writeEscapedContent(content);
}

/// Write content with escape processing to a buffer (for intermediate processing).
fn writeEscapedContentToBuf(buf: *std.ArrayListUnmanaged(u8), allocator: Allocator, content: []const u8) Error!void {
    var writer = BufEscapeWriter.init(buf, allocator);
    try writer.base.writeEscapedContent(content);
}

/// Zero-allocation line scanner for multiline string processing.
///
/// Iterates over lines in content without allocating memory. Lines are delimited
/// by `\n` (LF) or `\r\n` (CRLF). The newline characters are NOT included in
/// the returned line slices.
///
/// ## Trailing Newline Behavior
///
/// If the content ends with a newline, the scanner returns one additional empty
/// string after the last content line. This is intentional for multiline string
/// processing where the closing `"""` appears on its own line.
///
/// Example behavior:
/// - `"a\nb"` -> yields `"a"`, `"b"` (no trailing newline)
/// - `"a\nb\n"` -> yields `"a"`, `"b"`, `""` (trailing newline = empty final line)
/// - `"a\n"` -> yields `"a"`, `""` (content + empty line for closing delimiter)
///
/// This behavior is critical for correct dedent calculation in multiline strings,
/// where the indentation of the closing `"""` determines the common prefix to remove.
const LineScanner = struct {
    content: []const u8,
    pos: usize,
    returned_final: bool,

    pub fn init(content: []const u8) LineScanner {
        return .{ .content = content, .pos = 0, .returned_final = false };
    }

    pub fn next(self: *LineScanner) ?[]const u8 {
        if (self.pos >= self.content.len) {
            // If content ended with newline, return one more empty line
            if (!self.returned_final and self.content.len > 0) {
                const last_char = self.content[self.content.len - 1];
                if (last_char == '\n' or last_char == '\r') {
                    self.returned_final = true;
                    return "";
                }
            }
            return null;
        }

        const start = self.pos;
        while (self.pos < self.content.len) {
            if (self.content[self.pos] == '\n') {
                const line = self.content[start..self.pos];
                self.pos += 1;
                return line;
            } else if (self.content[self.pos] == '\r') {
                const line = self.content[start..self.pos];
                self.pos += 1;
                if (self.pos < self.content.len and self.content[self.pos] == '\n') {
                    self.pos += 1;
                }
                return line;
            }
            self.pos += 1;
        }
        // Return remaining content (no trailing newline)
        self.returned_final = true;
        return self.content[start..];
    }
};

/// Check if line contains only whitespace.
fn isWhitespaceOnly(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) {
        const decoded = unicode.decodeUtf8(line[i..]) orelse return false;
        if (!unicode.isWhitespace(decoded.codepoint)) return false;
        i += decoded.len;
    }
    return true;
}

/// Get whitespace prefix of a line.
fn getWhitespacePrefix(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) {
        const decoded = unicode.decodeUtf8(line[i..]) orelse break;
        if (!unicode.isWhitespace(decoded.codepoint)) break;
        i += decoded.len;
    }
    return line[0..i];
}

/// Check if line ends with backslash (for line continuations).
fn endsWithBackslash(line: []const u8) bool {
    var i: usize = line.len;
    while (i > 0) {
        var char_start = i - 1;
        while (char_start > 0 and (line[char_start] & 0xC0) == 0x80) {
            char_start -= 1;
        }

        const decoded = unicode.decodeUtf8(line[char_start..i]) orelse {
            return line[char_start] == '\\';
        };

        if (decoded.codepoint == '\\') return true;
        if (!unicode.isWhitespace(decoded.codepoint)) return false;
        i = char_start;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "buildIdentifier" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildIdentifier(&pool, "hello");
    try std.testing.expectEqualStrings("hello", pool.get(ref));
}

test "buildQuotedString simple" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildQuotedString(&pool, "\"hello\"");
    try std.testing.expectEqualStrings("hello", pool.get(ref));
}

test "buildQuotedString with escapes" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildQuotedString(&pool, "\"hello\\nworld\"");
    try std.testing.expectEqualStrings("hello\nworld", pool.get(ref));
}

test "buildQuotedString unicode escape" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildQuotedString(&pool, "\"\\u{1F600}\"");
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", pool.get(ref)); // Grinning face emoji
}

test "buildQuotedString all escapes" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildQuotedString(&pool, "\"\\n\\r\\t\\\\\\\"\\b\\f\\s\"");
    try std.testing.expectEqualStrings("\n\r\t\\\"\x08\x0C ", pool.get(ref));
}

test "buildQuotedString whitespace escape" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildQuotedString(&pool, "\"hello\\   world\"");
    try std.testing.expectEqualStrings("helloworld", pool.get(ref));
}

test "buildRawString simple" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildRawString(&pool, "#\"hello\"#");
    try std.testing.expectEqualStrings("hello", pool.get(ref));
}

test "buildRawString with hashes" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildRawString(&pool, "##\"hello\"##");
    try std.testing.expectEqualStrings("hello", pool.get(ref));
}

test "buildRawString preserves backslashes" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try buildRawString(&pool, "#\"hello\\nworld\"#");
    try std.testing.expectEqualStrings("hello\\nworld", pool.get(ref));
}

test "buildMultilineString basic" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const input =
        \\"""
        \\    hello
        \\    world
        \\    """
    ;
    const ref = try buildMultilineString(&pool, input);
    try std.testing.expectEqualStrings("hello\nworld", pool.get(ref));
}

test "buildMultilineString with escapes" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const input =
        \\"""
        \\    hello\ntest
        \\    """
    ;
    const ref = try buildMultilineString(&pool, input);
    try std.testing.expectEqualStrings("hello\ntest", pool.get(ref));
}

test "LineScanner basic" {
    var scanner = LineScanner.init("line1\nline2\nline3");
    try std.testing.expectEqualStrings("line1", scanner.next().?);
    try std.testing.expectEqualStrings("line2", scanner.next().?);
    try std.testing.expectEqualStrings("line3", scanner.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), scanner.next());
}

test "LineScanner CRLF" {
    var scanner = LineScanner.init("line1\r\nline2\r\nline3");
    try std.testing.expectEqualStrings("line1", scanner.next().?);
    try std.testing.expectEqualStrings("line2", scanner.next().?);
    try std.testing.expectEqualStrings("line3", scanner.next().?);
    try std.testing.expectEqual(@as(?[]const u8, null), scanner.next());
}

test "invalid escape returns error" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    try std.testing.expectError(Error.InvalidEscape, buildQuotedString(&pool, "\"\\x\""));
}

test "invalid unicode escape" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    // Missing closing brace
    try std.testing.expectError(Error.InvalidEscape, buildQuotedString(&pool, "\"\\u{1234\""));
    // Too many digits
    try std.testing.expectError(Error.InvalidEscape, buildQuotedString(&pool, "\"\\u{1234567}\""));
    // Surrogate
    try std.testing.expectError(Error.InvalidEscape, buildQuotedString(&pool, "\"\\u{D800}\""));
}
