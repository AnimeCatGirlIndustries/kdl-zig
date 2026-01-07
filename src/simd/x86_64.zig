//! x86_64 SIMD implementations using SSE2/AVX2.
//!
//! Uses Zig's @Vector type which compiles to appropriate SIMD instructions.
//! SSE2 is baseline for x86_64, so 128-bit vectors are always available.

const std = @import("std");
const platform = @import("platform.zig");
const generic = @import("generic.zig");

// Re-export StructuralMasks for convenience
pub const StructuralMasks = generic.StructuralMasks;

/// 16-byte vector for SSE2 operations
const Vec16 = @Vector(16, u8);

/// Scan a block of up to 64 bytes using SIMD.
/// Uses AVX2 (32-byte vectors) if available, otherwise SSE2 (16-byte).
pub fn scanBlock(data: []const u8) StructuralMasks {
    // Cap length at 64 bytes
    const len = if (data.len > 64) 64 else data.len;
    const slice = data[0..len];

    // For very short blocks, use scalar fallback to avoid setup overhead
    if (slice.len < 16) {
        return generic.scanBlock(slice);
    }

    var masks = StructuralMasks{
        .quotes = 0,
        .backslashes = 0,
        .delimiters = 0,
        .slashes = 0,
        .hashes = 0,
        .newlines = 0,
        .others = 0,
    };

    // Determine vector width based on available features
    const width = if (platform.detected_isa == .x86_64_avx2) 32 else 16;
    const Vec = @Vector(width, u8);
    // Mask type is result of bitCast(Vec(bool))
    // For width=32 -> u32, width=16 -> u16
    const MaskInt = if (width == 32) u32 else u16;

    var i: usize = 0;
    while (i + width <= slice.len) {
        const v: Vec = slice[i..][0..width].*;
        const shift_amt: u6 = @intCast(i);

        // Quotes "
        {
            const m_bool = v == @as(Vec, @splat('"'));
            const m_bits: MaskInt = @bitCast(m_bool);
            masks.quotes |= @as(u64, m_bits) << shift_amt;
        }

        // Backslashes \
        {
            const m_bool = v == @as(Vec, @splat('\\'));
            const m_bits: MaskInt = @bitCast(m_bool);
            masks.backslashes |= @as(u64, m_bits) << shift_amt;
        }

        // Delimiters { } ( ) ; =
        {
            const m_bool = (v == @as(Vec, @splat('{'))) |
                           (v == @as(Vec, @splat('}'))) |
                           (v == @as(Vec, @splat('('))) |
                           (v == @as(Vec, @splat(')'))) |
                           (v == @as(Vec, @splat(';'))) |
                           (v == @as(Vec, @splat('=')));
            const m_bits: MaskInt = @bitCast(m_bool);
            masks.delimiters |= @as(u64, m_bits) << shift_amt;
        }

        // Slashes /
        {
            const m_bool = v == @as(Vec, @splat('/'));
            const m_bits: MaskInt = @bitCast(m_bool);
            masks.slashes |= @as(u64, m_bits) << shift_amt;
        }

        // Hashes #
        {
            const m_bool = v == @as(Vec, @splat('#'));
            const m_bits: MaskInt = @bitCast(m_bool);
            masks.hashes |= @as(u64, m_bits) << shift_amt;
        }

        // Newlines \n \r
        {
            const m_bool = (v == @as(Vec, @splat('\n'))) |
                           (v == @as(Vec, @splat('\r')));
            const m_bits: MaskInt = @bitCast(m_bool);
            masks.newlines |= @as(u64, m_bits) << shift_amt;
        }

        // Others * -
        {
            const m_bool = (v == @as(Vec, @splat('*'))) |
                           (v == @as(Vec, @splat('-')));
            const m_bits: MaskInt = @bitCast(m_bool);
            masks.others |= @as(u64, m_bits) << shift_amt;
        }

        i += width;
    }

    // Trailing bytes (scalar fallback)
    if (i < slice.len) {
        const remaining = generic.scanBlock(slice[i..]);
        masks.quotes |= remaining.quotes << @intCast(i);
        masks.backslashes |= remaining.backslashes << @intCast(i);
        masks.delimiters |= remaining.delimiters << @intCast(i);
        masks.slashes |= remaining.slashes << @intCast(i);
        masks.hashes |= remaining.hashes << @intCast(i);
        masks.newlines |= remaining.newlines << @intCast(i);
        masks.others |= remaining.others << @intCast(i);
    }

    return masks;
}

/// Find the length of contiguous whitespace (space or tab) using SIMD.
/// Processes 16 bytes at a time, with scalar fallback for remainder.
pub inline fn findWhitespaceLength(data: []const u8) usize {
    // Quick exit: if first byte isn't whitespace, return immediately
    // This handles the common case where we're at the start of a token
    if (data.len == 0) return 0;
    const first = data[0];
    if (first != ' ' and first != '\t') return 0;

    // For very short runs, scalar is faster than SIMD setup
    if (data.len < 16) {
        var i: usize = 1; // Already checked first byte
        while (i < data.len) : (i += 1) {
            const c = data[i];
            if (c != ' ' and c != '\t') break;
        }
        return i;
    }

    var offset: usize = 0;

    // Process 16 bytes at a time
    while (offset + 16 <= data.len) {
        const chunk: Vec16 = data[offset..][0..16].*;
        const spaces: Vec16 = @splat(' ');
        const tabs: Vec16 = @splat('\t');

        // Check which bytes are whitespace (vector OR)
        const is_space = chunk == spaces;
        const is_tab = chunk == tabs;
        const is_whitespace = is_space | is_tab;

        // Convert to bitmask - bit is 1 if NOT whitespace
        const not_whitespace = ~is_whitespace;
        const mask: u16 = @bitCast(not_whitespace);

        if (mask != 0) {
            // Found non-whitespace - count trailing zeros to find position
            return offset + @ctz(mask);
        }

        offset += 16;
    }

    // Handle remainder with scalar code
    while (offset < data.len) {
        const c = data[offset];
        if (c != ' ' and c != '\t') {
            break;
        }
        offset += 1;
    }

    return offset;
}

/// Find the position of the first string-terminating character using SIMD.
/// String terminators are: " (0x22), \ (0x5C), \n (0x0A), \r (0x0D)
pub inline fn findStringTerminator(data: []const u8) usize {
    // Quick exit for empty or immediate terminator
    if (data.len == 0) return 0;
    const first = data[0];
    if (first == '"' or first == '\\' or first == '\n' or first == '\r') return 0;

    // For short strings, scalar is faster than SIMD setup
    if (data.len < 16) {
        var i: usize = 1;
        while (i < data.len) : (i += 1) {
            const c = data[i];
            if (c == '"' or c == '\\' or c == '\n' or c == '\r') return i;
        }
        return data.len;
    }

    var offset: usize = 0;

    // Process 16 bytes at a time
    while (offset + 16 <= data.len) {
        const chunk: Vec16 = data[offset..][0..16].*;

        const quotes: Vec16 = @splat('"');
        const backslashes: Vec16 = @splat('\\');
        const newlines: Vec16 = @splat('\n');
        const carriage_returns: Vec16 = @splat('\r');

        // Check for any terminator (vector OR)
        const is_quote = chunk == quotes;
        const is_backslash = chunk == backslashes;
        const is_newline = chunk == newlines;
        const is_cr = chunk == carriage_returns;

        const is_terminator = is_quote | is_backslash | is_newline | is_cr;

        const mask: u16 = @bitCast(is_terminator);

        if (mask != 0) {
            return offset + @ctz(mask);
        }

        offset += 16;
    }

    // Handle remainder with scalar code
    while (offset < data.len) {
        const c = data[offset];
        if (c == '"' or c == '\\' or c == '\n' or c == '\r') {
            return offset;
        }
        offset += 1;
    }

    return data.len;
}

/// Find the position of the first non-identifier character using SIMD.
pub inline fn findIdentifierEnd(data: []const u8) usize {
    // Quick exit: if first byte is a terminator, return 0
    if (data.len == 0) return 0;
    if (data[0] >= 0x80 or @import("util").grammar.isTokenTerminator(data[0])) return 0;

    // For short identifiers, scalar is faster
    if (data.len < 16) {
        return @import("generic.zig").findIdentifierEnd(data);
    }

    var offset: usize = 0;
    const Vec = @Vector(16, u8);

    while (offset + 16 <= data.len) {
        const chunk: Vec = data[offset..][0..16].*;

        // Identification mask: characters that are terminators or non-ASCII
        const is_non_ascii = chunk >= @as(Vec, @splat(0x80));
        
        // Terminating characters: space, tab, newline, cr, (, ), {, }, [, ], /, \, ", #, ;, =
        const is_term = (chunk == @as(Vec, @splat(' '))) |
                        (chunk == @as(Vec, @splat('\t'))) |
                        (chunk == @as(Vec, @splat('\n'))) |
                        (chunk == @as(Vec, @splat('\r'))) |
                        (chunk == @as(Vec, @splat('('))) |
                        (chunk == @as(Vec, @splat(')'))) |
                        (chunk == @as(Vec, @splat('{'))) |
                        (chunk == @as(Vec, @splat('}'))) |
                        (chunk == @as(Vec, @splat('['))) |
                        (chunk == @as(Vec, @splat(']'))) |
                        (chunk == @as(Vec, @splat('/'))) |
                        (chunk == @as(Vec, @splat('\\'))) |
                        (chunk == @as(Vec, @splat('"'))) |
                        (chunk == @as(Vec, @splat('#'))) |
                        (chunk == @as(Vec, @splat(';'))) |
                        (chunk == @as(Vec, @splat('=')));

        const mask: u16 = @bitCast(is_non_ascii | is_term);

        if (mask != 0) {
            return offset + @ctz(mask);
        }

        offset += 16;
    }

    // Handle remainder
    while (offset < data.len) {
        const c = data[offset];
        if (c >= 0x80 or @import("util").grammar.isTokenTerminator(c)) break;
        offset += 1;
    }

    return offset;
}

/// Find the position of the first backslash using SIMD.
pub inline fn findBackslash(data: []const u8) usize {
    var offset: usize = 0;

    // Process 16 bytes at a time
    while (offset + 16 <= data.len) {
        const chunk: Vec16 = data[offset..][0..16].*;
        const backslashes: Vec16 = @splat('\\');

        const is_backslash = chunk == backslashes;
        const mask: u16 = @bitCast(is_backslash);

        if (mask != 0) {
            return offset + @ctz(mask);
        }

        offset += 16;
    }

    // Handle remainder with scalar code
    while (offset < data.len) {
        if (data[offset] == '\\') {
            return offset;
        }
        offset += 1;
    }

    return data.len;
}

/// Generate a 64-bit mask of interesting characters in a 64-byte block.
pub inline fn scanStructuralMask(data: []const u8) u64 {
    if (data.len < 64) {
        return @import("generic.zig").scanStructuralMask(data);
    }

    var result: u64 = 0;
    const Vec = @Vector(16, u8);

    inline for (0..4) |i| {
        const offset = i * 16;
        const chunk: Vec = data[offset..][0..16].*;

        const m = (chunk == @as(Vec, @splat('{'))) |
            (chunk == @as(Vec, @splat('}'))) |
            (chunk == @as(Vec, @splat('('))) |
            (chunk == @as(Vec, @splat(')'))) |
            (chunk == @as(Vec, @splat('"'))) |
            (chunk == @as(Vec, @splat('\\'))) |
            (chunk == @as(Vec, @splat('/'))) |
            (chunk == @as(Vec, @splat(';'))) |
            (chunk == @as(Vec, @splat('='))) |
            (chunk == @as(Vec, @splat('#'))) |
            (chunk == @as(Vec, @splat('\n'))) |
            (chunk == @as(Vec, @splat('\r')));

        const mask: u16 = @bitCast(m);
        result |= (@as(u64, mask) << (i * 16));
    }

    return result;
}

/// Generate a mask for string content: " \ newline
pub inline fn scanStringMask(data: []const u8) u64 {
    if (data.len < 64) {
        return @import("generic.zig").scanStringMask(data);
    }

    var result: u64 = 0;
    const Vec = @Vector(16, u8);

    inline for (0..4) |i| {
        const offset = i * 16;
        const chunk: Vec = data[offset..][0..16].*;

        const m = (chunk == @as(Vec, @splat('"'))) |
            (chunk == @as(Vec, @splat('\\'))) |
            (chunk == @as(Vec, @splat('\n'))) |
            (chunk == @as(Vec, @splat('\r')));

        const mask: u16 = @bitCast(m);
        result |= (@as(u64, mask) << (i * 16));
    }

    return result;
}

/// Generate a mask for raw string content: "
pub inline fn scanRawStringMask(data: []const u8) u64 {
    if (data.len < 64) {
        return @import("generic.zig").scanRawStringMask(data);
    }

    var result: u64 = 0;
    const Vec = @Vector(16, u8);

    inline for (0..4) |i| {
        const offset = i * 16;
        const chunk: Vec = data[offset..][0..16].*;

        const m = (chunk == @as(Vec, @splat('"')));

        const mask: u16 = @bitCast(m);
        result |= (@as(u64, mask) << (i * 16));
    }

    return result;
}

/// Generate a mask for line comments: newline
pub inline fn scanCommentMask(data: []const u8) u64 {
    if (data.len < 64) {
        return @import("generic.zig").scanCommentMask(data);
    }

    var result: u64 = 0;
    const Vec = @Vector(16, u8);

    inline for (0..4) |i| {
        const offset = i * 16;
        const chunk: Vec = data[offset..][0..16].*;

        const m = (chunk == @as(Vec, @splat('\n'))) |
            (chunk == @as(Vec, @splat('\r')));

        const mask: u16 = @bitCast(m);
        result |= (@as(u64, mask) << (i * 16));
    }

    return result;
}

/// Generate a mask for block comments: * /
pub inline fn scanBlockCommentMask(data: []const u8) u64 {
    if (data.len < 64) {
        return @import("generic.zig").scanBlockCommentMask(data);
    }

    var result: u64 = 0;
    const Vec = @Vector(16, u8);

    inline for (0..4) |i| {
        const offset = i * 16;
        const chunk: Vec = data[offset..][0..16].*;

        const m = (chunk == @as(Vec, @splat('*'))) |
            (chunk == @as(Vec, @splat('/')));

        const mask: u16 = @bitCast(m);
        result |= (@as(u64, mask) << (i * 16));
    }

    return result;
}

/// Generate a mask for all token terminators in KDL.
pub inline fn scanTerminatorsMask(data: []const u8) u64 {
    if (data.len < 64) {
        return @import("generic.zig").scanTerminatorsMask(data);
    }

    var result: u64 = 0;
    const Vec = @Vector(16, u8);

    inline for (0..4) |i| {
        const offset = i * 16;
        const chunk: Vec = data[offset..][0..16].*;

        const m = (chunk == @as(Vec, @splat(' '))) |
            (chunk == @as(Vec, @splat('\t'))) |
            (chunk == @as(Vec, @splat('\n'))) |
            (chunk == @as(Vec, @splat('\r'))) |
            (chunk == @as(Vec, @splat('('))) |
            (chunk == @as(Vec, @splat(')'))) |
            (chunk == @as(Vec, @splat('{'))) |
            (chunk == @as(Vec, @splat('}'))) |
            (chunk == @as(Vec, @splat('['))) |
            (chunk == @as(Vec, @splat(']'))) |
            (chunk == @as(Vec, @splat('/'))) |
            (chunk == @as(Vec, @splat('\\'))) |
            (chunk == @as(Vec, @splat('"'))) |
            (chunk == @as(Vec, @splat('#'))) |
            (chunk == @as(Vec, @splat(';'))) |
            (chunk == @as(Vec, @splat('=')));

        const mask: u16 = @bitCast(m);
        result |= (@as(u64, mask) << (i * 16));
    }

    return result;
}

// ============================================================================
// Tests - These should produce identical results to generic.zig
// ============================================================================

test "findWhitespaceLength matches generic behavior" {
    const test_cases = [_][]const u8{
        "hello",
        "",
        "x",
        " x",
        "   x",
        "     ",
        "\tx",
        "\t\tx",
        " \t \tx",
        "\t \t",
        "  \n",
        " \r",
        // Test boundary conditions
        "               x", // 15 spaces + x
        "                x", // 16 spaces + x
        "                 x", // 17 spaces + x
        // 32 spaces to test multiple chunks
        "                                x",
    };

    for (test_cases) |data| {
        const simd_result = findWhitespaceLength(data);
        const generic_result = generic.findWhitespaceLength(data);
        try std.testing.expectEqual(generic_result, simd_result);
    }
}

test "findStringTerminator matches generic behavior" {
    const test_cases = [_][]const u8{
        "hello",
        "",
        "hello\"world",
        "\"",
        "hello\\n",
        "\\",
        "hello\nworld",
        "hello\rworld",
        "abc\"\\n",
        "abc\n\"",
        // Test boundary conditions
        "0123456789abcde\"", // 15 chars + quote
        "0123456789abcdef\"", // 16 chars + quote
        "0123456789abcdefg\"", // 17 chars + quote
    };

    for (test_cases) |data| {
        const simd_result = findStringTerminator(data);
        const generic_result = generic.findStringTerminator(data);
        try std.testing.expectEqual(generic_result, simd_result);
    }
}

test "findBackslash matches generic behavior" {
    const test_cases = [_][]const u8{
        "hello",
        "",
        "hello\\world",
        "\\",
        "\\n",
        // Test boundary conditions
        "0123456789abcde\\", // 15 chars + backslash
        "0123456789abcdef\\", // 16 chars + backslash
        "0123456789abcdefg\\", // 17 chars + backslash
    };

    for (test_cases) |data| {
        const simd_result = findBackslash(data);
        const generic_result = generic.findBackslash(data);
        try std.testing.expectEqual(generic_result, simd_result);
    }
}

test "findWhitespaceLength handles large inputs" {
    // Create a large buffer of spaces followed by a non-space
    var buffer: [1024]u8 = undefined;
    @memset(&buffer, ' ');
    buffer[1000] = 'x';

    const result = findWhitespaceLength(&buffer);
    try std.testing.expectEqual(@as(usize, 1000), result);
}

test "findStringTerminator handles large inputs" {
    // Create a large buffer of 'a' followed by a quote
    var buffer: [1024]u8 = undefined;
    @memset(&buffer, 'a');
    buffer[1000] = '"';

    const result = findStringTerminator(&buffer);
    try std.testing.expectEqual(@as(usize, 1000), result);
}

// ============================================================================
// AVX2 Path Tests (32-byte vector operations)
// These tests cover scenarios where AVX2 would use 32-byte vectors vs SSE2's 16-byte.
// The code uses platform.detected_isa to select vector width at comptime.
// ============================================================================

test "scanBlock matches generic for 32-byte boundary inputs" {
    // Test inputs that exercise the 32-byte vector path when AVX2 is available
    const test_cases = [_][]const u8{
        // Exactly 32 bytes (one AVX2 vector or two SSE2 vectors)
        "12345678901234567890123456789012",
        // 33 bytes (AVX2: 1 full + 1 partial, SSE2: 2 full + 1 partial)
        "123456789012345678901234567890123",
        // 48 bytes (AVX2: 1 full + 16 remainder, SSE2: 3 full)
        "123456789012345678901234567890123456789012345678",
        // Full 64 bytes (AVX2: 2 full, SSE2: 4 full)
        "1234567890123456789012345678901234567890123456789012345678901234",
        // With structural chars at various positions
        "{23456789012345678901234567890{2",
        "1234567890123456{8901234567890123",
        "12345678901234567890123456789012{4567890123456789012345678901234",
    };

    for (test_cases) |data| {
        const simd_result = scanBlock(data);
        const generic_result = generic.scanBlock(data);
        try std.testing.expectEqual(generic_result.quotes, simd_result.quotes);
        try std.testing.expectEqual(generic_result.backslashes, simd_result.backslashes);
        try std.testing.expectEqual(generic_result.delimiters, simd_result.delimiters);
        try std.testing.expectEqual(generic_result.slashes, simd_result.slashes);
        try std.testing.expectEqual(generic_result.hashes, simd_result.hashes);
        try std.testing.expectEqual(generic_result.newlines, simd_result.newlines);
        try std.testing.expectEqual(generic_result.others, simd_result.others);
    }
}

test "scanBlock structural chars at 32-byte boundaries" {
    // Test structural characters positioned at AVX2 vector boundaries
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 'a');

    // Test char at position 31 (end of first AVX2 vector)
    buffer[31] = '{';
    var result = scanBlock(&buffer);
    try std.testing.expect((result.delimiters & (@as(u64, 1) << 31)) != 0);
    buffer[31] = 'a';

    // Test char at position 32 (start of second AVX2 vector)
    buffer[32] = '{';
    result = scanBlock(&buffer);
    try std.testing.expect((result.delimiters & (@as(u64, 1) << 32)) != 0);
    buffer[32] = 'a';

    // Test char at position 63 (last position)
    buffer[63] = '}';
    result = scanBlock(&buffer);
    try std.testing.expect((result.delimiters & (@as(u64, 1) << 63)) != 0);
}

test "scanStructuralMask with 64-byte input" {
    // Full 64-byte block with structural chars at various positions
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 'x');

    // Place structural chars at key positions
    buffer[0] = '{';
    buffer[15] = '}';
    buffer[16] = '(';
    buffer[31] = ')';
    buffer[32] = '/';
    buffer[47] = '#';
    buffer[48] = '"';
    buffer[63] = ';';

    const simd_result = scanStructuralMask(&buffer);
    const generic_result = generic.scanStructuralMask(&buffer);

    try std.testing.expectEqual(generic_result, simd_result);

    // Verify specific positions
    try std.testing.expect((simd_result & (@as(u64, 1) << 0)) != 0);
    try std.testing.expect((simd_result & (@as(u64, 1) << 15)) != 0);
    try std.testing.expect((simd_result & (@as(u64, 1) << 16)) != 0);
    try std.testing.expect((simd_result & (@as(u64, 1) << 31)) != 0);
    try std.testing.expect((simd_result & (@as(u64, 1) << 32)) != 0);
    try std.testing.expect((simd_result & (@as(u64, 1) << 47)) != 0);
    try std.testing.expect((simd_result & (@as(u64, 1) << 48)) != 0);
    try std.testing.expect((simd_result & (@as(u64, 1) << 63)) != 0);
}

test "scanStringMask and scanRawStringMask match generic for 64-byte blocks" {
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 'x');

    // Place quotes and backslashes at key positions
    buffer[15] = '"';
    buffer[31] = '\\';
    buffer[32] = '"';
    buffer[47] = '\n';
    buffer[48] = '\r';
    buffer[63] = '"';

    // Test scanStringMask
    const string_simd = scanStringMask(&buffer);
    const string_generic = generic.scanStringMask(&buffer);
    try std.testing.expectEqual(string_generic, string_simd);

    // Test scanRawStringMask (only quotes)
    const raw_simd = scanRawStringMask(&buffer);
    const raw_generic = generic.scanRawStringMask(&buffer);
    try std.testing.expectEqual(raw_generic, raw_simd);
}

test "scanCommentMask and scanBlockCommentMask match generic for 64-byte blocks" {
    var buffer: [64]u8 = undefined;
    @memset(&buffer, 'x');

    // For comment mask: newlines
    buffer[15] = '\n';
    buffer[31] = '\r';
    buffer[32] = '\n';
    buffer[63] = '\r';

    const comment_simd = scanCommentMask(&buffer);
    const comment_generic = generic.scanCommentMask(&buffer);
    try std.testing.expectEqual(comment_generic, comment_simd);

    // For block comment mask: * and /
    @memset(&buffer, 'x');
    buffer[15] = '*';
    buffer[31] = '/';
    buffer[32] = '*';
    buffer[63] = '/';

    const block_simd = scanBlockCommentMask(&buffer);
    const block_generic = generic.scanBlockCommentMask(&buffer);
    try std.testing.expectEqual(block_generic, block_simd);
}
