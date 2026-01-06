//! Platform detection and SIMD feature flags for KDL parser.
//!
//! This module provides comptime detection of CPU features to enable
//! appropriate SIMD implementations. The architecture is designed to be
//! expandable to additional ISAs (ARM NEON, etc.) in the future.

const std = @import("std");
const builtin = @import("builtin");

/// Supported SIMD instruction set architectures
pub const Isa = enum {
    /// No SIMD support - use scalar fallback
    scalar,
    /// x86_64 SSE2 (128-bit vectors, baseline for x86_64)
    x86_64_sse2,
    /// x86_64 AVX2 (256-bit vectors)
    x86_64_avx2,
    /// ARM NEON (128-bit vectors) - future support
    aarch64_neon,
};

/// Vector width in bytes for the detected ISA
pub fn vectorWidth(isa: Isa) comptime_int {
    return switch (isa) {
        .scalar => 1,
        .x86_64_sse2, .aarch64_neon => 16,
        .x86_64_avx2 => 32,
    };
}

/// Detect the best available SIMD ISA at comptime
pub fn detectIsa() Isa {
    const cpu = builtin.cpu;

    if (cpu.arch == .x86_64) {
        // Check for AVX2 support
        if (std.Target.x86.featureSetHas(cpu.features, .avx2)) {
            return .x86_64_avx2;
        }
        // SSE2 is baseline for x86_64
        return .x86_64_sse2;
    }

    if (cpu.arch == .aarch64) {
        // NEON is baseline for AArch64
        return .aarch64_neon;
    }

    return .scalar;
}

/// The detected ISA for this compilation target
pub const detected_isa: Isa = detectIsa();

/// The vector width for this compilation target
pub const vector_width: comptime_int = vectorWidth(detected_isa);

/// Whether SIMD is available on this platform
pub const has_simd: bool = detected_isa != .scalar;

// ============================================================================
// Tests
// ============================================================================

test "detected_isa is a valid ISA" {
    // Verify detected_isa is one of the valid enum values (comptime check)
    comptime {
        _ = vectorWidth(detected_isa);
    }
}

test "vectorWidth returns expected values" {
    try std.testing.expectEqual(@as(comptime_int, 1), vectorWidth(.scalar));
    try std.testing.expectEqual(@as(comptime_int, 16), vectorWidth(.x86_64_sse2));
    try std.testing.expectEqual(@as(comptime_int, 32), vectorWidth(.x86_64_avx2));
    try std.testing.expectEqual(@as(comptime_int, 16), vectorWidth(.aarch64_neon));
}

test "detected_isa is consistent with detectIsa" {
    try std.testing.expectEqual(detectIsa(), detected_isa);
}

test "vector_width matches detected_isa" {
    try std.testing.expectEqual(vectorWidth(detected_isa), vector_width);
}

test "has_simd is true for x86_64" {
    if (builtin.cpu.arch == .x86_64) {
        try std.testing.expect(has_simd);
    }
}
