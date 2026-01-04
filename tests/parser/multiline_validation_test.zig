/// KDL 2.0.0 Multiline String Validation Tests
/// TDD tests for multiline string validation rules that should cause parse errors.
const std = @import("std");
const kdl = @import("kdl");

// =============================================================================
// Single-line multiline strings should fail
// =============================================================================

test "multiline string on single line should fail" {
    // Multiline strings MUST span multiple lines
    const input = "node \"\"\"one line\"\"\"";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.InvalidString, result);
}

test "multiline raw string on single line should fail" {
    const input = "node #\"\"\"one line\"\"\"#";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.InvalidString, result);
}

// =============================================================================
// Prefix count mismatch should fail
// =============================================================================

test "multiline string with insufficient prefix whitespace should fail" {
    // The closing delimiter has 2 spaces prefix
    // But line 2 (" everyone") has only 1 space - should fail
    const input =
        \\node """
        \\    hey
        \\ everyone
        \\     how goes?
        \\  """
    ;
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.InvalidString, result);
}

test "multiline raw string with insufficient prefix whitespace should fail" {
    const input =
        \\node #"""
        \\    hey
        \\ everyone
        \\     how goes?
        \\  """#
    ;
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.InvalidString, result);
}

// =============================================================================
// Prefix character mismatch should fail (tabs vs spaces)
// =============================================================================

test "multiline string with mixed tabs and spaces in prefix should fail" {
    // Closing delimiter has 2 spaces prefix
    // But one content line starts with tab - character mismatch
    const input = "node \"\"\"\n    hey\n   everyone\n\t   how goes?\n  \"\"\"";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.InvalidString, result);
}

test "multiline raw string with mixed tabs and spaces in prefix should fail" {
    const input = "node #\"\"\"\n    hey\n   everyone\n\t   how goes?\n  \"\"\"#";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.InvalidString, result);
}

// =============================================================================
// Legacy raw string syntax should fail (KDL 1.x style)
// =============================================================================

test "legacy raw string r-quote should fail" {
    // KDL 1.x used r"..." syntax which is invalid in KDL 2.0
    const input = "node r\"foo\"";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "legacy raw string r-hash-quote should fail" {
    // KDL 1.x used r#"..."# syntax which is invalid in KDL 2.0
    const input = "node r#\"foo\"#";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

// =============================================================================
// Whitespace-required validation (node-space must exist between elements)
// =============================================================================

test "no space between node name and first argument should fail" {
    // KDL requires whitespace between node name and arguments
    const input = "node\"string\"";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "no space between properties should fail" {
    // KDL requires whitespace between properties
    const input = "node foo=\"value\"bar=5";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "no space between arguments should fail" {
    // KDL requires whitespace between arguments
    const input = "node \"string\"1";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

// =============================================================================
// Scientific notation preservation tests (overflow/underflow)
// =============================================================================

test "scientific notation with large exponent should round-trip" {
    // 1.23E+1000 overflows f64, should preserve original text
    const input = "node prop=1.23E+1000";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    // Serialize and check it preserves the original value
    const output = try kdl.serializeToString(std.testing.allocator, doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node prop=1.23E+1000\n", output);
}

test "scientific notation with small exponent should round-trip" {
    // 1.23E-1000 underflows f64, should preserve original text
    const input = "node prop=1.23E-1000";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    // Serialize and check it preserves the original value
    const output = try kdl.serializeToString(std.testing.allocator, doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node prop=1.23E-1000\n", output);
}
