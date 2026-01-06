//! SIMD-accelerated scanning primitives for KDL tokenization.
//!
//! This module provides vectorized implementations of common scanning operations
//! used during tokenization. It automatically selects the best implementation
//! based on the target platform:
//!
//! - x86_64: SSE2/AVX2 vectorized implementations
//! - aarch64: ARM NEON implementations (future)
//! - other: Scalar fallback
//!
//! All functions have identical semantics regardless of platform.

const std = @import("std");
pub const platform = @import("simd/platform.zig");
pub const generic = @import("simd/generic.zig");
pub const structural = @import("simd/structural.zig");

// Platform-specific implementations - select at comptime
const impl = switch (platform.detected_isa) {
    .x86_64_sse2, .x86_64_avx2 => @import("simd/x86_64.zig"),
    .aarch64_neon => generic, // Future: @import("simd/aarch64.zig")
    .scalar => generic,
};

/// Find the length of contiguous whitespace (space or tab) at the start of the buffer.
/// Returns the number of whitespace bytes found.
///
/// This is the primary hot path for tokenization - called on every token.
pub const findWhitespaceLength = impl.findWhitespaceLength;

/// Find the position of the first string-terminating character.
/// String terminators are: " (0x22), \ (0x5C), \n (0x0A), \r (0x0D)
/// Returns the position of the first terminator, or data.len if none found.
///
/// Used when scanning string content to find where special handling is needed.
pub const findStringTerminator = impl.findStringTerminator;

/// Find the position of the first non-identifier character.
/// Returns the position of the first non-identifier char, or data.len if all valid.
///
/// Note: This only handles ASCII characters. Non-ASCII bytes will cause an early return
/// so the caller can handle UTF-8 decoding.
pub const findIdentifierEnd = generic.findIdentifierEnd;

/// Find the position of the first backslash (escape sequence marker).
/// Returns the position of the first backslash, or data.len if none found.
///
/// Used during escape sequence processing to find the next escape to handle.
pub const findBackslash = impl.findBackslash;

/// Bitmasks identifying the locations of interesting characters within a block.
pub const StructuralMasks = generic.StructuralMasks;

/// Scan a block of up to 64 bytes and identify interesting characters.
/// Returns bitmasks where the Nth bit is set if the Nth byte matches.
pub const scanBlock = impl.scanBlock;

/// Generate a 64-bit mask of interesting characters in a block.
pub const scanStructuralMask = impl.scanStructuralMask;

// Re-export platform info for introspection
pub const detected_isa = platform.detected_isa;
pub const vector_width = platform.vector_width;
pub const has_simd = platform.has_simd;

// ============================================================================
// Tests
// ============================================================================

test "scanBlock works correctly" {
    // Indices:
    // 012345678901234567890123456
    // node (type)# { key="val"; }
    const data = "node (type)# { key=\"val\"; }";
    const masks = scanBlock(data);

    // Structural: (5), ) (10), # (11), { (13), = (18), ; (24), } (26)
    const expected_structural =
        (@as(u64, 1) << 5) |
        (@as(u64, 1) << 10) |
        (@as(u64, 1) << 11) |
        (@as(u64, 1) << 13) |
        (@as(u64, 1) << 18) |
        (@as(u64, 1) << 24) |
        (@as(u64, 1) << 26);
    try std.testing.expectEqual(expected_structural, masks.structural);

    // Quotes: " (19), " (23)
    const expected_quotes =
        (@as(u64, 1) << 19) |
        (@as(u64, 1) << 23);
    try std.testing.expectEqual(expected_quotes, masks.quotes);

    // Whitespace: space at 4, 12, 14, 25
    const expected_whitespace =
        (@as(u64, 1) << 4) |
        (@as(u64, 1) << 12) |
        (@as(u64, 1) << 14) |
        (@as(u64, 1) << 25);
    try std.testing.expectEqual(expected_whitespace, masks.whitespace);
}

test "simd module uses correct implementation" {
    // Verify we're using SIMD on x86_64
    if (@import("builtin").cpu.arch == .x86_64) {
        try std.testing.expect(has_simd);
        try std.testing.expect(detected_isa == .x86_64_sse2 or detected_isa == .x86_64_avx2);
    }
}

test "findWhitespaceLength works correctly" {
    try std.testing.expectEqual(@as(usize, 0), findWhitespaceLength("hello"));
    try std.testing.expectEqual(@as(usize, 3), findWhitespaceLength("   x"));
    try std.testing.expectEqual(@as(usize, 4), findWhitespaceLength(" \t \t"));
}

test "findStringTerminator works correctly" {
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello"));
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello\""));
    try std.testing.expectEqual(@as(usize, 5), findStringTerminator("hello\\n"));
}

test "findIdentifierEnd works correctly" {
    try std.testing.expectEqual(@as(usize, 5), findIdentifierEnd("hello world"));
    try std.testing.expectEqual(@as(usize, 4), findIdentifierEnd("node{"));
}

test "findBackslash works correctly" {
    try std.testing.expectEqual(@as(usize, 5), findBackslash("hello"));
    try std.testing.expectEqual(@as(usize, 5), findBackslash("hello\\world"));
}

// Include tests from submodules
test {
    _ = platform;
    _ = generic;
    _ = @import("simd/x86_64.zig");
}
