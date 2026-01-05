/// KDL Number Parsing Utilities
///
/// Provides functions for parsing KDL numeric values including:
/// - Decimal integers with optional sign and underscores
/// - Radix integers (hex `0x`, octal `0o`, binary `0b`)
/// - Floating-point with exponents and underscores
///
/// All functions are thread-safe and use the provided allocator for any
/// temporary memory (cleaned up automatically when using arena allocator).
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Error type for number parsing
pub const ParseError = error{
    InvalidNumber,
    OutOfMemory,
};

/// Result of stripUnderscores - tracks whether memory was allocated
pub const StrippedString = struct {
    slice: []const u8,
    allocated: bool,

    pub fn deinit(self: StrippedString, allocator: Allocator) void {
        if (self.allocated) {
            allocator.free(@constCast(self.slice));
        }
    }
};

/// Strip underscores from a number string.
/// Thread-safe version that uses provided allocator.
/// Returns the original text if no underscores are present.
/// Caller should call deinit() on result if using non-arena allocator.
pub fn stripUnderscores(allocator: Allocator, text: []const u8) Allocator.Error!StrippedString {
    // Count underscores to see if we need to do anything
    var underscore_count: usize = 0;
    for (text) |c| {
        if (c == '_') underscore_count += 1;
    }
    if (underscore_count == 0) return .{ .slice = text, .allocated = false };

    // Allocate buffer for result
    const result = try allocator.alloc(u8, text.len - underscore_count);
    var i: usize = 0;
    for (text) |c| {
        if (c != '_') {
            result[i] = c;
            i += 1;
        }
    }
    return .{ .slice = result, .allocated = true };
}

/// Parse a signed integer with a radix prefix (0x, 0o, 0b).
/// Handles sign prefix and underscore separators.
/// Note: With arena allocator, deferred cleanup is automatic.
pub fn parseRadixInteger(allocator: Allocator, text: []const u8, prefix_len: usize, radix: u8) ParseError!i128 {
    // Handle sign
    var start: usize = 0;
    var negative = false;
    if (text.len > 0 and text[0] == '-') {
        negative = true;
        start = 1;
    } else if (text.len > 0 and text[0] == '+') {
        start = 1;
    }

    // Validate length includes prefix.
    // This check prevents slice index underflow in `text[start + prefix_len ..]` below.
    // Without this, a string like "-0" with prefix_len=2 would attempt to slice beyond bounds.
    if (text.len < start + prefix_len) return ParseError.InvalidNumber;

    // Get the number part after prefix (safe due to bounds check above)
    const number_part = text[start + prefix_len ..];
    const cleaned = stripUnderscores(allocator, number_part) catch return ParseError.OutOfMemory;
    defer cleaned.deinit(allocator);

    const value = std.fmt.parseInt(i128, cleaned.slice, radix) catch return ParseError.InvalidNumber;
    return if (negative) -value else value;
}

/// Parse a decimal integer.
/// Note: With arena allocator, deferred cleanup is automatic.
pub fn parseDecimalInteger(allocator: Allocator, text: []const u8) ParseError!i128 {
    const cleaned = stripUnderscores(allocator, text) catch return ParseError.OutOfMemory;
    defer cleaned.deinit(allocator);
    return std.fmt.parseInt(i128, cleaned.slice, 10) catch return ParseError.InvalidNumber;
}

/// Parse a floating-point number.
/// Returns the parsed value and optionally the original text for round-tripping.
pub const FloatResult = struct {
    value: f64,
    original: ?[]const u8 = null,
};

pub fn parseFloat(allocator: Allocator, text: []const u8) ParseError!FloatResult {
    const cleaned = stripUnderscores(allocator, text) catch return ParseError.OutOfMemory;
    defer cleaned.deinit(allocator);

    const f = std.fmt.parseFloat(f64, cleaned.slice) catch return ParseError.InvalidNumber;

    // Check for overflow/underflow - preserve original text for round-tripping
    if (std.math.isInf(f) or (f == 0.0 and containsNonZeroDigit(cleaned.slice))) {
        // Overflow (inf) or underflow (0.0 from non-zero value) - keep original
        const original = allocator.dupe(u8, text) catch return ParseError.OutOfMemory;
        return .{ .value = f, .original = original };
    }

    // Check if has exponent - preserve original for correct formatting
    if (std.mem.indexOfAny(u8, cleaned.slice, "eE") != null) {
        const original = allocator.dupe(u8, text) catch return ParseError.OutOfMemory;
        return .{ .value = f, .original = original };
    }

    return .{ .value = f };
}

/// Check if a string contains any non-zero digit (1-9).
pub fn containsNonZeroDigit(s: []const u8) bool {
    for (s) |c| {
        if (c >= '1' and c <= '9') return true;
    }
    return false;
}

// ============================================================================
// Tests
// ============================================================================

test "stripUnderscores no underscores" {
    const result = try stripUnderscores(std.testing.allocator, "12345");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("12345", result.slice);
    try std.testing.expect(!result.allocated);
}

test "stripUnderscores with underscores" {
    const result = try stripUnderscores(std.testing.allocator, "1_234_567");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("1234567", result.slice);
    try std.testing.expect(result.allocated);
}

test "stripUnderscores hex with underscores" {
    const result = try stripUnderscores(std.testing.allocator, "dead_beef");
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("deadbeef", result.slice);
}

test "parseRadixInteger hex" {
    const result = try parseRadixInteger(std.testing.allocator, "0xff", 2, 16);
    try std.testing.expectEqual(@as(i128, 255), result);
}

test "parseRadixInteger hex negative" {
    const result = try parseRadixInteger(std.testing.allocator, "-0xff", 2, 16);
    try std.testing.expectEqual(@as(i128, -255), result);
}

test "parseRadixInteger hex with underscores" {
    const result = try parseRadixInteger(std.testing.allocator, "0xdead_beef", 2, 16);
    try std.testing.expectEqual(@as(i128, 0xdeadbeef), result);
}

test "parseRadixInteger octal" {
    const result = try parseRadixInteger(std.testing.allocator, "0o777", 2, 8);
    try std.testing.expectEqual(@as(i128, 511), result);
}

test "parseRadixInteger binary" {
    const result = try parseRadixInteger(std.testing.allocator, "0b1010", 2, 2);
    try std.testing.expectEqual(@as(i128, 10), result);
}

test "parseDecimalInteger basic" {
    const result = try parseDecimalInteger(std.testing.allocator, "42");
    try std.testing.expectEqual(@as(i128, 42), result);
}

test "parseDecimalInteger with underscores" {
    const result = try parseDecimalInteger(std.testing.allocator, "1_000_000");
    try std.testing.expectEqual(@as(i128, 1000000), result);
}

test "parseDecimalInteger negative" {
    const result = try parseDecimalInteger(std.testing.allocator, "-123");
    try std.testing.expectEqual(@as(i128, -123), result);
}

test "parseFloat basic" {
    const result = try parseFloat(std.testing.allocator, "3.14");
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.value, 0.001);
    try std.testing.expectEqual(@as(?[]const u8, null), result.original);
}

test "parseFloat with exponent" {
    const result = try parseFloat(std.testing.allocator, "1.5e10");
    defer if (result.original) |orig| std.testing.allocator.free(orig);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5e10), result.value, 1e6);
    try std.testing.expect(result.original != null);
}

test "parseFloat with underscores" {
    const result = try parseFloat(std.testing.allocator, "1_000.5");
    try std.testing.expectApproxEqAbs(@as(f64, 1000.5), result.value, 0.001);
}

test "containsNonZeroDigit" {
    try std.testing.expect(containsNonZeroDigit("123"));
    try std.testing.expect(containsNonZeroDigit("0.5"));
    try std.testing.expect(!containsNonZeroDigit("0.0"));
    try std.testing.expect(!containsNonZeroDigit("000"));
}
