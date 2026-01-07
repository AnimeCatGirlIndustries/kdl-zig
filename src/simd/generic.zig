//! Generic scalar fallback implementations for SIMD operations.
//!
//! These implementations work on all platforms but process one byte at a time.
//! They serve as the baseline and fallback when SIMD is unavailable.

const std = @import("std");
const util = @import("util");
const grammar = util.grammar;

/// Find the length of contiguous whitespace (space or tab) at the start of the buffer.
/// Returns the number of whitespace bytes found.
pub fn findWhitespaceLength(data: []const u8) usize {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c != ' ' and c != '\t') {
            break;
        }
    }
    return i;
}

/// Find the position of the first string-terminating character.
/// String terminators are: " (0x22), \ (0x5C), \n (0x0A), \r (0x0D)
/// Returns the position of the first terminator, or data.len if none found.
pub fn findStringTerminator(data: []const u8) usize {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c == '"' or c == '\\' or c == '\n' or c == '\r') {
            return i;
        }
    }
    return data.len;
}

/// Find the position of the first non-identifier character.
/// Identifier chars are ASCII alphanumeric, underscore, hyphen, and non-special printable.
/// Returns the position of the first non-identifier char, or data.len if all valid.
pub fn findIdentifierEnd(data: []const u8) usize {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        // Fast path: only handle ASCII here
        if (c >= 0x80) {
            // Non-ASCII - let caller handle UTF-8
            return i;
        }
        // Check for identifier-terminating characters
        if (grammar.isTokenTerminator(c)) {
            return i;
        }
    }
    return data.len;
}

/// Check if a character terminates an identifier
/// Find the position of the first backslash (escape sequence marker).
/// Returns the position of the first backslash, or data.len if none found.
pub fn findBackslash(data: []const u8) usize {
    var i: usize = 0;
    while (i < data.len) : (i += 1) {
        if (data[i] == '\\') {
            return i;
        }
    }
    return data.len;
}

/// Bitmasks identifying the locations of interesting characters within a block.
pub const StructuralMasks = struct {
    /// Positions of double quotes (")
    quotes: u64,
    /// Positions of backslashes (\)
    backslashes: u64,
    /// Positions of structural/comment characters: { } ( ) ; = / # *
    structural: u64,
    /// Positions of whitespace: space, tab, newline, cr
    whitespace: u64,
};

/// Scan a block of up to 64 bytes and identify interesting characters.
/// Returns bitmasks where the Nth bit is set if the Nth byte matches.
pub fn scanBlock(data: []const u8) StructuralMasks {
    var masks = StructuralMasks{
        .quotes = 0,
        .backslashes = 0,
        .structural = 0,
        .whitespace = 0,
    };

    const len = @min(data.len, 64);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const c = data[i];
        const bit = @as(u64, 1) << @intCast(i);
        switch (c) {
            '"' => masks.quotes |= bit,
            '\\' => masks.backslashes |= bit,
            '{', '}', '(', ')', ';', '=', '/', '#', '*' => masks.structural |= bit,
            ' ', '\t', '\n', '\r' => masks.whitespace |= bit,
            else => {},
        }
    }
    return masks;
}

/// Generate a 64-bit mask of interesting characters in a block.
/// Includes quotes, backslashes, newlines, and structural/comment characters.
pub fn scanStructuralMask(data: []const u8) u64 {
    var mask: u64 = 0;
    const len = @min(data.len, 64);
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const c = data[i];
        switch (c) {
            '"', '\\', '{', '}', '(', ')', ';', '=', '/', '#', '*', '\n', '\r' => {
                mask |= @as(u64, 1) << @intCast(i);
            },
            else => {},
        }
    }
    return mask;
}

// ============================================================================
// Tests
// ============================================================================

test "findWhitespaceLength with no whitespace" {
    try std.testing.expectEqual(@as(usize, 0), findWhitespaceLength("hello"));
    try std.testing.expectEqual(@as(usize, 0), findWhitespaceLength(""));
    try std.testing.expectEqual(@as(usize, 0), findWhitespaceLength("x"));
}

test "findWhitespaceLength with spaces" {
    try std.testing.expectEqual(@as(usize, 1), findWhitespaceLength(" x"));
    try std.testing.expectEqual(@as(usize, 3), findWhitespaceLength("   x"));
    try std.testing.expectEqual(@as(usize, 5), findWhitespaceLength("     "));
}

test "findWhitespaceLength with tabs" {
    try std.testing.expectEqual(@as(usize, 1), findWhitespaceLength("\tx"));
    try std.testing.expectEqual(@as(usize, 2), findWhitespaceLength("\t\tx"));
}

test "findWhitespaceLength with mixed whitespace" {
    try std.testing.expectEqual(@as(usize, 4), findWhitespaceLength(" \t \tx"));
    try std.testing.expectEqual(@as(usize, 3), findWhitespaceLength("\t \t"));
}

test "findWhitespaceLength stops at newline" {
    try std.testing.expectEqual(@as(usize, 2), findWhitespaceLength("  \n"));
    try std.testing.expectEqual(@as(usize, 1), findWhitespaceLength(" \r"));
}

test "findStringTerminator with no terminators" {
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello"));
    try std.testing.expectEqual(@as(usize, 0), findStringTerminator(""));
}

test "findStringTerminator finds quote" {
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello\"world"));
    try std.testing.expectEqual(@as(usize, 0), findStringTerminator("\""));
}

test "findStringTerminator finds backslash" {
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello\\n"));
    try std.testing.expectEqual(@as(usize, 0), findStringTerminator("\\"));
}

test "findStringTerminator finds newline" {
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello\nworld"));
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello\rworld"));
}

test "findStringTerminator finds first terminator" {
    try std.testing.expectEqual(@as(usize, 3), findStringTerminator("abc\"\\n"));
    try std.testing.expectEqual(@as(usize, 3), findStringTerminator("abc\n\""));
}

test "findIdentifierEnd with valid identifier" {
    try std.testing.expectEqual(@as(usize, 5), findIdentifierEnd("hello"));
    try std.testing.expectEqual(@as(usize, 5), findIdentifierEnd("hello world"));
    try std.testing.expectEqual(@as(usize, 8), findIdentifierEnd("my-ident"));
    try std.testing.expectEqual(@as(usize, 8), findIdentifierEnd("my_ident"));
}

test "findIdentifierEnd stops at special chars" {
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("node{"));
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("node("));
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("node="));
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("node;"));
}

test "findIdentifierEnd stops at non-ASCII" {
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("test\xC0\x80"));
}

test "findIdentifierEnd stops at DEL" {
    try std.testing.expectEqual(@as(usize, 0), findIdentifierEnd("\x7F"));
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("test\x7F"));
}

test "findBackslash with no backslash" {
    try std.testing.expectEqual(@as(usize, 5), findBackslash("hello"));
    try std.testing.expectEqual(@as(usize, 0), findBackslash(""));
}

test "findBackslash finds backslash" {
    try std.testing.expectEqual(@as(usize, 5), findBackslash("hello\\world"));
    try std.testing.expectEqual(@as(usize, 0), findBackslash("\\"));
    try std.testing.expectEqual(@as(usize, 0), findBackslash("\\n"));
}
