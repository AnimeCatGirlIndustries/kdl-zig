/// KDL String Utilities
///
/// This module provides string manipulation functions for KDL parsing and processing.
///
/// ## Memory Ownership
///
/// Functions in this module have different ownership semantics:
///
/// **Borrowed (no allocation):**
/// - `processRawString` - Returns a slice into the original text (single-line only)
/// - `processEscapes` - Returns original if no escapes, otherwise allocates
/// - `processQuotedString` - Returns original if no escapes, otherwise allocates
///
/// **Allocated (caller must free or use arena):**
/// - `splitLines` - Returns allocated slice of slices
/// - `processMultilineString` - Always allocates the result
/// - `processMultilineRawString` - Always allocates the result
///
/// When using an arena allocator (recommended), all allocations are freed together
/// when the arena is destroyed. For non-arena allocators, callers must track
/// whether the returned slice is borrowed or allocated.
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const unicode = @import("unicode.zig");

/// Split content into lines, handling both LF and CRLF line endings.
///
/// **Ownership:** Returns an allocated slice of slices. The outer slice is allocated
/// by the provided allocator and must be freed. The inner slices are views into
/// the original `content` and should not be freed.
pub fn splitLines(allocator: Allocator, content: []const u8) Allocator.Error![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .{};
    var line_start: usize = 0;
    var i: usize = 0;

    while (i < content.len) {
        if (content[i] == '\n') {
            try lines.append(allocator, content[line_start..i]);
            line_start = i + 1;
            i += 1;
        } else if (content[i] == '\r') {
            try lines.append(allocator, content[line_start..i]);
            i += 1;
            if (i < content.len and content[i] == '\n') {
                i += 1;
            }
            line_start = i;
        } else {
            i += 1;
        }
    }

    // Append final line (may be empty)
    if (line_start <= content.len) {
        try lines.append(allocator, content[line_start..]);
    }

    return lines.toOwnedSlice(allocator);
}

/// Get the leading Unicode whitespace prefix of a line.
/// Returns a slice into the original line containing only whitespace characters.
pub fn getWhitespacePrefix(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len) {
        const decoded = unicode.decodeUtf8(line[i..]) orelse break;
        if (!unicode.isWhitespace(decoded.codepoint)) break;
        i += decoded.len;
    }
    return line[0..i];
}

/// Check if a line contains only Unicode whitespace characters.
/// Returns true for empty lines as well.
pub fn isWhitespaceOnly(line: []const u8) bool {
    var i: usize = 0;
    while (i < line.len) {
        const decoded = unicode.decodeUtf8(line[i..]) orelse return false;
        if (!unicode.isWhitespace(decoded.codepoint)) return false;
        i += decoded.len;
    }
    return true;
}

/// Check if a line ends with a backslash (possibly followed by whitespace).
/// Used for detecting line continuations in multiline strings.
pub fn endsWithBackslash(line: []const u8) bool {
    // Iterate backwards to find last non-whitespace character
    var i: usize = line.len;
    while (i > 0) {
        // Find the start of the previous UTF-8 character
        var char_start = i - 1;
        while (char_start > 0 and (line[char_start] & 0xC0) == 0x80) {
            char_start -= 1;
        }

        const decoded = unicode.decodeUtf8(line[char_start..i]) orelse {
            // Invalid UTF-8, treat as non-whitespace
            return line[char_start] == '\\';
        };

        if (decoded.codepoint == '\\') {
            return true;
        }
        if (!unicode.isWhitespace(decoded.codepoint)) {
            return false;
        }

        i = char_start;
    }
    return false;
}

/// Errors related to string processing
pub const Error = error{
    InvalidString,
    InvalidEscape,
    OutOfMemory,
};

/// Process a quoted string by removing quotes and handling escape sequences.
///
/// **Ownership:** May return borrowed or allocated memory:
/// - If no escapes present: returns a slice into `text` (borrowed)
/// - If escapes present: returns newly allocated memory
/// Use with arena allocator for automatic cleanup.
pub fn processQuotedString(allocator: Allocator, text: []const u8) Error![]const u8 {
    // Remove surrounding quotes
    if (text.len < 2) return Error.InvalidString;
    const content = text[1 .. text.len - 1];

    // Process escape sequences
    return processEscapes(allocator, content);
}

/// Process a raw string by removing hash delimiters and quotes.
///
/// **Ownership:** For single-line raw strings, returns a borrowed slice into `text`.
/// For multiline raw strings, delegates to `processMultilineRawString` which allocates.
pub fn processRawString(allocator: Allocator, text: []const u8) Error![]const u8 {
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
        return processMultilineRawString(allocator, text, hash_count);
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

/// Validate multiline string structure and extract dedent prefix.
/// Returns the dedent prefix if valid, or error if malformed.
/// Common validation for both raw and escaped multiline strings.
fn validateMultilineStructure(lines: []const []const u8) Error![]const u8 {
    // Must have at least 2 lines (first line after """ and last line before """)
    if (lines.len < 2) return Error.InvalidString;

    // Get dedent prefix from the final line (must be whitespace-only)
    const last_line = lines[lines.len - 1];

    // CRITICAL: Final line must be whitespace-only (it defines the dedent prefix).
    // If escape processing consumed the dedent line (e.g., `bar\` at end of content
    // consumes the following whitespace), the structure is invalid.
    if (!isWhitespaceOnly(last_line)) {
        return Error.InvalidString;
    }

    const dedent = getWhitespacePrefix(last_line);

    // Validate that all content lines have the required prefix
    for (lines[1 .. lines.len - 1]) |line| {
        // Whitespace-only lines are always valid (become empty in output)
        if (isWhitespaceOnly(line)) continue;

        // Content lines must start with the dedent prefix
        if (dedent.len > 0 and !std.mem.startsWith(u8, line, dedent)) {
            return Error.InvalidString;
        }
    }

    return dedent;
}

/// Build dedented output from lines, using raw whitespace-only flags.
/// If raw_ws_only is null, uses runtime whitespace detection.
fn buildDedentedOutput(
    allocator: Allocator,
    lines: []const []const u8,
    dedent: []const u8,
    raw_ws_only: ?[]const bool,
) Error![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};

    // Process content lines (skip first line after """ and last line before """)
    for (lines[1 .. lines.len - 1], 0..) |line, idx| {
        if (idx > 0) result.append(allocator, '\n') catch return Error.OutOfMemory;

        // Check whitespace-only status (from raw flags or current detection)
        const is_ws_only = if (raw_ws_only) |flags|
            (idx + 1 < flags.len and flags[idx + 1])
        else
            isWhitespaceOnly(line);

        // Whitespace-only lines become empty
        if (is_ws_only) continue;

        // Dedent the line
        const output = if (std.mem.startsWith(u8, line, dedent)) line[dedent.len..] else line;
        result.appendSlice(allocator, output) catch return Error.OutOfMemory;
    }

    return result.toOwnedSlice(allocator) catch return Error.OutOfMemory;
}

/// Process a multiline raw string by removing delimiters and dedenting.
///
/// **Ownership:** Always allocates the result. Caller must free or use arena.
pub fn processMultilineRawString(allocator: Allocator, text: []const u8, hash_count: usize) Error![]const u8 {
    // Skip opening #...#""" and closing """#...#
    const start = hash_count + 3;
    const end = text.len - hash_count - 3;

    if (start >= end) return Error.InvalidString;
    const content = text[start..end];

    // Must contain at least one newline
    if (std.mem.indexOfAny(u8, content, "\n\r") == null) {
        return Error.InvalidString;
    }

    // Split into lines
    const lines = splitLines(allocator, content) catch return Error.OutOfMemory;
    defer allocator.free(lines);

    // Validate structure and get dedent prefix
    const dedent = try validateMultilineStructure(lines);

    // Build output (no raw whitespace tracking needed for raw strings)
    return buildDedentedOutput(allocator, lines, dedent, null);
}

/// Process a multiline string by removing delimiters, processing escapes, and dedenting.
///
/// For escaped strings, whitespace-only status is determined from RAW content
/// (before escape processing) to correctly handle `\s` escapes.
///
/// **Ownership:** Always allocates the result. Caller must free or use arena.
pub fn processMultilineString(allocator: Allocator, text: []const u8) Error![]const u8 {
    // Remove surrounding """
    if (text.len < 6) return Error.InvalidString;
    const raw_content = text[3 .. text.len - 3];

    // Must contain at least one newline
    if (std.mem.indexOfAny(u8, raw_content, "\n\r") == null) {
        return Error.InvalidString;
    }

    // Split RAW content for prefix validation and whitespace tracking
    const raw_lines = splitLines(allocator, raw_content) catch return Error.OutOfMemory;
    defer allocator.free(raw_lines);
    if (raw_lines.len < 2) return Error.InvalidString;

    // Track which lines are whitespace-only in RAW form (before escape processing)
    // This is critical: \s becomes whitespace after processing, but the line
    // should NOT be treated as whitespace-only since it has explicit content.
    var raw_ws_only: std.ArrayListUnmanaged(bool) = .{};
    raw_ws_only.append(allocator, true) catch return Error.OutOfMemory; // Placeholder for line 0
    defer raw_ws_only.deinit(allocator);

    // Validate RAW prefixes (accounting for line continuations)
    const raw_dedent = getWhitespacePrefix(raw_lines[raw_lines.len - 1]);
    var prev_is_continuation = false;
    for (raw_lines[1 .. raw_lines.len - 1]) |line| {
        const is_ws_only = isWhitespaceOnly(line);
        raw_ws_only.append(allocator, is_ws_only) catch return Error.OutOfMemory;

        // Skip validation for continuation lines (following a line ending with \)
        if (prev_is_continuation) {
            prev_is_continuation = endsWithBackslash(line);
            continue;
        }
        prev_is_continuation = endsWithBackslash(line);

        // Whitespace-only lines are always valid
        if (is_ws_only) continue;

        // Content lines must start with the dedent prefix
        if (raw_dedent.len > 0 and !std.mem.startsWith(u8, line, raw_dedent)) {
            return Error.InvalidString;
        }
    }

    // Process escape sequences
    const processed_content = try processEscapes(allocator, raw_content);

    // Re-split processed content for dedenting
    const processed_lines = splitLines(allocator, processed_content) catch return Error.OutOfMemory;
    defer allocator.free(processed_lines);
    if (processed_lines.len < 2) {
        if (processed_lines.len == 0) return "";
        return processed_content;
    }

    // Validate processed structure and get dedent prefix
    const dedent = try validateMultilineStructure(processed_lines);

    // Build output using raw whitespace-only flags
    return buildDedentedOutput(allocator, processed_lines, dedent, raw_ws_only.items);
}

/// Process escape sequences in a string.
///
/// Handles: `\n`, `\r`, `\t`, `\\`, `\"`, `\b`, `\f`, `\s`, `\u{XXXX}`,
/// and whitespace escapes (backslash followed by whitespace/newline).
///
/// **Ownership:** May return borrowed or allocated memory:
/// - If no escapes present: returns `text` unchanged (borrowed)
/// - If escapes present: returns newly allocated memory
pub fn processEscapes(allocator: Allocator, text: []const u8) Error![]const u8 {
    // Quick check: if no backslashes, return original (borrowed)
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
                    try result.append(allocator, '\n');
                    i += 1;
                },
                'r' => {
                    try result.append(allocator, '\r');
                    i += 1;
                },
                't' => {
                    try result.append(allocator, '\t');
                    i += 1;
                },
                '\\' => {
                    try result.append(allocator, '\\');
                    i += 1;
                },
                '"' => {
                    try result.append(allocator, '"');
                    i += 1;
                },
                'b' => {
                    try result.append(allocator, 0x08);
                    i += 1;
                },
                'f' => {
                    try result.append(allocator, 0x0C);
                    i += 1;
                },
                's' => {
                    try result.append(allocator, ' ');
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

                    // Validate codepoint before encoding
                    // Surrogates (U+D800-U+DFFF) are not valid Unicode scalar values
                    if (unicode.isSurrogate(codepoint)) {
                        return Error.InvalidEscape;
                    }

                    // Encode as UTF-8
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(codepoint, &buf) catch return Error.InvalidEscape;
                    try result.appendSlice(allocator, buf[0..len]);
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
            try result.append(allocator, text[i]);
            i += 1;
        }
    }

    return try result.toOwnedSlice(allocator);
}

// ============================================================================
// Tests
// ============================================================================

test "splitLines basic LF" {
    const content = "line1\nline2\nline3";
    const lines = try splitLines(std.testing.allocator, content);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
}

test "splitLines CRLF" {
    const content = "line1\r\nline2\r\nline3";
    const lines = try splitLines(std.testing.allocator, content);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
}

test "splitLines mixed line endings" {
    const content = "line1\nline2\r\nline3\rline4";
    const lines = try splitLines(std.testing.allocator, content);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
    try std.testing.expectEqualStrings("line4", lines[3]);
}

test "splitLines empty lines" {
    const content = "line1\n\nline3";
    const lines = try splitLines(std.testing.allocator, content);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("", lines[1]);
    try std.testing.expectEqualStrings("line3", lines[2]);
}

test "splitLines trailing newline" {
    const content = "line1\nline2\n";
    const lines = try splitLines(std.testing.allocator, content);
    defer std.testing.allocator.free(lines);

    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("line1", lines[0]);
    try std.testing.expectEqualStrings("line2", lines[1]);
    try std.testing.expectEqualStrings("", lines[2]);
}

test "getWhitespacePrefix basic" {
    try std.testing.expectEqualStrings("  ", getWhitespacePrefix("  hello"));
    try std.testing.expectEqualStrings("\t", getWhitespacePrefix("\tworld"));
    try std.testing.expectEqualStrings("", getWhitespacePrefix("no prefix"));
    try std.testing.expectEqualStrings("   ", getWhitespacePrefix("   "));
}

test "getWhitespacePrefix unicode" {
    // U+00A0 NO-BREAK SPACE = C2 A0
    const nbsp_line = "\xc2\xa0hello";
    try std.testing.expectEqualStrings("\xc2\xa0", getWhitespacePrefix(nbsp_line));

    // U+205F MEDIUM MATHEMATICAL SPACE = E2 81 9F
    const mmsp_line = "\xe2\x81\x9f\x20test";
    try std.testing.expectEqualStrings("\xe2\x81\x9f\x20", getWhitespacePrefix(mmsp_line));
}

test "isWhitespaceOnly basic" {
    try std.testing.expect(isWhitespaceOnly(""));
    try std.testing.expect(isWhitespaceOnly("   "));
    try std.testing.expect(isWhitespaceOnly("\t\t"));
    try std.testing.expect(isWhitespaceOnly("  \t  "));
    try std.testing.expect(!isWhitespaceOnly("  x  "));
    try std.testing.expect(!isWhitespaceOnly("hello"));
}

test "isWhitespaceOnly unicode" {
    // U+00A0 NO-BREAK SPACE
    try std.testing.expect(isWhitespaceOnly("\xc2\xa0"));
    try std.testing.expect(isWhitespaceOnly("\xc2\xa0 \t"));
    // U+205F MEDIUM MATHEMATICAL SPACE
    try std.testing.expect(isWhitespaceOnly("\xe2\x81\x9f"));
    // Mixed
    try std.testing.expect(isWhitespaceOnly("\xc2\xa0\xe2\x81\x9f "));
}

test "endsWithBackslash basic" {
    try std.testing.expect(endsWithBackslash("hello\\"));
    try std.testing.expect(endsWithBackslash("test\\  "));
    try std.testing.expect(endsWithBackslash("test\\\t"));
    try std.testing.expect(!endsWithBackslash("hello"));
    try std.testing.expect(!endsWithBackslash("hello\\n"));
    try std.testing.expect(!endsWithBackslash(""));
}

test "endsWithBackslash unicode whitespace" {
    // Backslash followed by Unicode whitespace (U+00A0)
    try std.testing.expect(endsWithBackslash("test\\\xc2\xa0"));
    // Backslash followed by U+205F
    try std.testing.expect(endsWithBackslash("test\\\xe2\x81\x9f"));
}
