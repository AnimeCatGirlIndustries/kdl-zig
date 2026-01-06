//! Global constants for the KDL parser library.
//!
//! This module centralizes configuration defaults and limits to ensure
//! consistency across the codebase and make tuning easier.

/// Default maximum nesting depth for nodes.
/// Protects against stack exhaustion from deeply nested documents.
pub const DEFAULT_MAX_DEPTH: u16 = 256;

/// Default buffer size for streaming tokenization (64 KiB).
/// Balance between memory usage and I/O efficiency.
pub const DEFAULT_BUFFER_SIZE: usize = 64 * 1024;

/// Maximum pool size limit (256 MiB).
/// Protects against memory exhaustion from malicious input.
pub const MAX_POOL_SIZE: usize = 256 * 1024 * 1024;

/// Maximum line tracking capacity for multiline string processing.
/// Used by StaticBitSet in value_builder for whitespace-only line tracking.
pub const MAX_TRACKED_LINES: usize = 256;

// Test that constants are sensible
test "constants are valid" {
    const std = @import("std");
    // max_depth should be reasonable
    try std.testing.expect(DEFAULT_MAX_DEPTH > 0);
    try std.testing.expect(DEFAULT_MAX_DEPTH <= 1024);

    // buffer_size should be at least 1KB
    try std.testing.expect(DEFAULT_BUFFER_SIZE >= 1024);

    // max_pool_size should be at least 1MB
    try std.testing.expect(MAX_POOL_SIZE >= 1024 * 1024);

    // max_tracked_lines should fit in StaticBitSet
    try std.testing.expect(MAX_TRACKED_LINES <= 65536);
}
