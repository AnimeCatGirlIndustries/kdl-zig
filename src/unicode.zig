/// Unicode Utilities for KDL 2.0.0
///
/// Implements character classification per the KDL specification.
/// All functions operate on Unicode codepoints (u21).
///
/// ## Character Classes
///
/// - **Whitespace**: Non-newline spacing characters (Tab, Space, NBSP, etc.)
/// - **Newline**: Line terminator characters (LF, CR, NEL, etc.)
/// - **Disallowed**: Control characters, surrogates, direction control, BOM
/// - **Identifier**: Valid characters for bare identifiers
///
/// ## UTF-8 Decoding
///
/// The `decodeUtf8` function decodes a UTF-8 byte sequence to a codepoint,
/// validating the encoding and rejecting overlong sequences.
const std = @import("std");

/// Check if a codepoint is a KDL whitespace character (non-newline).
/// Per spec: U+0009, U+0020, U+00A0, U+1680, U+2000-200A, U+202F, U+205F, U+3000
pub fn isWhitespace(c: u21) bool {
    return switch (c) {
        0x0009, // Tab
        0x0020, // Space
        0x00A0, // No-Break Space
        0x1680, // Ogham Space Mark
        0x2000...0x200A, // Various Unicode spaces (En Quad through Hair Space)
        0x202F, // Narrow No-Break Space
        0x205F, // Medium Mathematical Space
        0x3000, // Ideographic Space
        => true,
        else => false,
    };
}

/// Check if a codepoint is a KDL newline character or sequence start.
/// Per spec: CR, LF, NEL (U+0085), VT (U+000B), FF (U+000C), LS (U+2028), PS (U+2029)
/// Note: CRLF is treated as a single newline and should be handled at a higher level.
pub fn isNewline(c: u21) bool {
    return switch (c) {
        0x000A, // LF (Line Feed)
        0x000D, // CR (Carriage Return)
        0x000B, // VT (Vertical Tab)
        0x000C, // FF (Form Feed)
        0x0085, // NEL (Next Line)
        0x2028, // LS (Line Separator)
        0x2029, // PS (Paragraph Separator)
        => true,
        else => false,
    };
}

/// Check if a codepoint is disallowed in KDL documents.
/// Per spec: U+0000-0008, U+000E-001F, U+007F, surrogates, direction control, BOM (except at start)
pub fn isDisallowed(c: u21) bool {
    return switch (c) {
        // Control characters (except allowed whitespace/newlines)
        0x0000...0x0008, // NUL through BS (excluding Tab at 0x09)
        0x000E...0x001F, // SO through US (excluding VT, FF at 0x0B, 0x0C)
        0x007F, // DEL

        // Surrogates (not valid Unicode Scalar Values, but check anyway)
        0xD800...0xDFFF,

        // Direction control characters
        0x200E, 0x200F, // LRM, RLM
        0x202A...0x202E, // LRE, RLE, PDF, LRO, RLO
        0x2066...0x2069, // LRI, RLI, FSI, PDI

        // BOM (Byte Order Mark) - disallowed except at document start
        0xFEFF,
        => true,
        else => false,
    };
}

/// Check if a codepoint is BOM (for special handling at document start)
pub fn isBom(c: u21) bool {
    return c == 0xFEFF;
}

/// Check if a codepoint is a Unicode surrogate (U+D800-U+DFFF).
/// Surrogates are not valid Unicode scalar values and must be rejected in unicode escapes.
pub fn isSurrogate(c: u21) bool {
    return c >= 0xD800 and c <= 0xDFFF;
}

/// Check if a codepoint can start an identifier.
/// Identifiers cannot start with digits.
pub fn isIdentifierStart(c: u21) bool {
    if (isDisallowed(c)) return false;
    if (isWhitespace(c)) return false;
    if (isNewline(c)) return false;

    // Cannot start with digit
    if (c >= '0' and c <= '9') return false;

    // Cannot be special punctuation
    return switch (c) {
        '(', ')', '{', '}', '[', ']', '/', '\\', '"', '#', ';', '=' => false,
        else => true,
    };
}

/// Check if a codepoint can continue an identifier.
pub fn isIdentifierChar(c: u21) bool {
    if (isDisallowed(c)) return false;
    if (isWhitespace(c)) return false;
    if (isNewline(c)) return false;

    // Cannot be special punctuation
    return switch (c) {
        '(', ')', '{', '}', '[', ']', '/', '\\', '"', '#', ';', '=' => false,
        else => true,
    };
}

/// Check if a codepoint is a decimal digit.
pub fn isDigit(c: u21) bool {
    return c >= '0' and c <= '9';
}

/// Check if a codepoint is a hexadecimal digit.
pub fn isHexDigit(c: u21) bool {
    return (c >= '0' and c <= '9') or
        (c >= 'a' and c <= 'f') or
        (c >= 'A' and c <= 'F');
}

/// Check if a codepoint is an octal digit.
pub fn isOctalDigit(c: u21) bool {
    return c >= '0' and c <= '7';
}

/// Check if a codepoint is a binary digit.
pub fn isBinaryDigit(c: u21) bool {
    return c == '0' or c == '1';
}

/// Decode a UTF-8 sequence and return the codepoint and byte length.
/// Returns null if the sequence is invalid.
pub fn decodeUtf8(bytes: []const u8) ?struct { codepoint: u21, len: u3 } {
    if (bytes.len == 0) return null;

    const byte0 = bytes[0];

    // Single byte (ASCII)
    if (byte0 & 0x80 == 0) {
        return .{ .codepoint = byte0, .len = 1 };
    }

    // Multi-byte sequences
    if (byte0 & 0xE0 == 0xC0) {
        // 2-byte sequence
        if (bytes.len < 2) return null;
        if (bytes[1] & 0xC0 != 0x80) return null;
        const cp = (@as(u21, byte0 & 0x1F) << 6) | (bytes[1] & 0x3F);
        if (cp < 0x80) return null; // Overlong
        return .{ .codepoint = cp, .len = 2 };
    }

    if (byte0 & 0xF0 == 0xE0) {
        // 3-byte sequence
        if (bytes.len < 3) return null;
        if (bytes[1] & 0xC0 != 0x80) return null;
        if (bytes[2] & 0xC0 != 0x80) return null;
        const cp = (@as(u21, byte0 & 0x0F) << 12) |
            (@as(u21, bytes[1] & 0x3F) << 6) |
            (bytes[2] & 0x3F);
        if (cp < 0x800) return null; // Overlong
        return .{ .codepoint = cp, .len = 3 };
    }

    if (byte0 & 0xF8 == 0xF0) {
        // 4-byte sequence
        if (bytes.len < 4) return null;
        if (bytes[1] & 0xC0 != 0x80) return null;
        if (bytes[2] & 0xC0 != 0x80) return null;
        if (bytes[3] & 0xC0 != 0x80) return null;
        const cp = (@as(u21, byte0 & 0x07) << 18) |
            (@as(u21, bytes[1] & 0x3F) << 12) |
            (@as(u21, bytes[2] & 0x3F) << 6) |
            (bytes[3] & 0x3F);
        if (cp < 0x10000) return null; // Overlong
        if (cp > 0x10FFFF) return null; // Out of range
        return .{ .codepoint = cp, .len = 4 };
    }

    return null;
}

// Tests

test "whitespace detection" {
    try std.testing.expect(isWhitespace(' '));
    try std.testing.expect(isWhitespace('\t'));
    try std.testing.expect(isWhitespace(0x00A0)); // No-Break Space
    try std.testing.expect(isWhitespace(0x3000)); // Ideographic Space

    try std.testing.expect(!isWhitespace('\n'));
    try std.testing.expect(!isWhitespace('a'));
    try std.testing.expect(!isWhitespace('0'));
}

test "newline detection" {
    try std.testing.expect(isNewline('\n'));
    try std.testing.expect(isNewline('\r'));
    try std.testing.expect(isNewline(0x0085)); // NEL
    try std.testing.expect(isNewline(0x2028)); // LS
    try std.testing.expect(isNewline(0x2029)); // PS

    try std.testing.expect(!isNewline(' '));
    try std.testing.expect(!isNewline('a'));
}

test "disallowed codepoint detection" {
    try std.testing.expect(isDisallowed(0x0000)); // NUL
    try std.testing.expect(isDisallowed(0x007F)); // DEL
    try std.testing.expect(isDisallowed(0x200E)); // LRM
    try std.testing.expect(isDisallowed(0xFEFF)); // BOM

    try std.testing.expect(!isDisallowed(' '));
    try std.testing.expect(!isDisallowed('a'));
    try std.testing.expect(!isDisallowed('\n'));
}

test "identifier start detection" {
    try std.testing.expect(isIdentifierStart('a'));
    try std.testing.expect(isIdentifierStart('_'));
    try std.testing.expect(isIdentifierStart('-'));

    try std.testing.expect(!isIdentifierStart('0'));
    try std.testing.expect(!isIdentifierStart('"'));
    try std.testing.expect(!isIdentifierStart('('));
}

test "UTF-8 decoding" {
    // ASCII
    const ascii = decodeUtf8("a");
    try std.testing.expect(ascii != null);
    try std.testing.expectEqual(@as(u21, 'a'), ascii.?.codepoint);
    try std.testing.expectEqual(@as(u3, 1), ascii.?.len);

    // 2-byte (e.g., é = U+00E9)
    const two_byte = decodeUtf8("\xC3\xA9");
    try std.testing.expect(two_byte != null);
    try std.testing.expectEqual(@as(u21, 0x00E9), two_byte.?.codepoint);
    try std.testing.expectEqual(@as(u3, 2), two_byte.?.len);

    // 3-byte (e.g., € = U+20AC)
    const three_byte = decodeUtf8("\xE2\x82\xAC");
    try std.testing.expect(three_byte != null);
    try std.testing.expectEqual(@as(u21, 0x20AC), three_byte.?.codepoint);
    try std.testing.expectEqual(@as(u3, 3), three_byte.?.len);

    // 4-byte (e.g., 😀 = U+1F600)
    const four_byte = decodeUtf8("\xF0\x9F\x98\x80");
    try std.testing.expect(four_byte != null);
    try std.testing.expectEqual(@as(u21, 0x1F600), four_byte.?.codepoint);
    try std.testing.expectEqual(@as(u3, 4), four_byte.?.len);
}
