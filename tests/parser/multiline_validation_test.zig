/// KDL 2.0.0 Multiline String Validation Tests
/// TDD tests for multiline string validation rules that should cause parse errors.
const std = @import("std");
const testing = std.testing;
const kdl = @import("kdl");

/// Helper to test that parsing should fail with a specific error.
/// Properly cleans up if parsing unexpectedly succeeds.
fn expectParseError(comptime expected: anyerror, input: []const u8) !void {
    if (kdl.parse(testing.allocator, testing.io, input)) |*doc| {
        var d = doc.*;
        d.deinit();
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqual(expected, err);
    }
}

// =============================================================================
// Single-line multiline strings should fail
// =============================================================================

test "multiline string on single line should fail" {
    // Multiline strings MUST span multiple lines
    try expectParseError(error.InvalidString, "node \"\"\"one line\"\"\"");
}

test "multiline raw string on single line should fail" {
    try expectParseError(error.InvalidString, "node #\"\"\"one line\"\"\"#");
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
    try expectParseError(error.InvalidString, input);
}

test "multiline raw string with insufficient prefix whitespace should fail" {
    const input =
        \\node #"""
        \\    hey
        \\ everyone
        \\     how goes?
        \\  """#
    ;
    try expectParseError(error.InvalidString, input);
}

// =============================================================================
// Prefix character mismatch should fail (tabs vs spaces)
// =============================================================================

test "multiline string with mixed tabs and spaces in prefix should fail" {
    // Closing delimiter has 2 spaces prefix
    // But one content line starts with tab - character mismatch
    try expectParseError(error.InvalidString, "node \"\"\"\n    hey\n   everyone\n\t   how goes?\n  \"\"\"");
}

test "multiline raw string with mixed tabs and spaces in prefix should fail" {
    try expectParseError(error.InvalidString, "node #\"\"\"\n    hey\n   everyone\n\t   how goes?\n  \"\"\"#");
}

// =============================================================================
// Legacy raw string syntax should fail (KDL 1.x style)
// =============================================================================

test "legacy raw string r-quote should fail" {
    // KDL 1.x used r"..." syntax which is invalid in KDL 2.0
    try expectParseError(error.UnexpectedToken, "node r\"foo\"");
}

test "legacy raw string r-hash-quote should fail" {
    // KDL 1.x used r#"..."# syntax which is invalid in KDL 2.0
    try expectParseError(error.UnexpectedToken, "node r#\"foo\"#");
}

// =============================================================================
// Whitespace-required validation (node-space must exist between elements)
// =============================================================================

test "no space between node name and first argument should fail" {
    // KDL requires whitespace between node name and arguments
    try expectParseError(error.UnexpectedToken, "node\"string\"");
}

test "no space between properties should fail" {
    // KDL requires whitespace between properties
    try expectParseError(error.UnexpectedToken, "node foo=\"value\"bar=5");
}

test "no space between arguments should fail" {
    // KDL requires whitespace between arguments
    try expectParseError(error.UnexpectedToken, "node \"string\"1");
}

// =============================================================================
// Scientific notation preservation tests (overflow/underflow)
// =============================================================================

test "scientific notation with large exponent should round-trip" {
    // 1.23E+1000 overflows f64, should preserve original text
    const input = "node prop=1.23E+1000";
    var doc = try kdl.parse(testing.allocator, testing.io, input);
    defer doc.deinit();

    // Serialize and check it preserves the original value
    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node prop=1.23E+1000\n", output);
}

test "scientific notation with small exponent should round-trip" {
    // 1.23E-1000 underflows f64, should preserve original text
    const input = "node prop=1.23E-1000";
    var doc = try kdl.parse(testing.allocator, testing.io, input);
    defer doc.deinit();

    // Serialize and check it preserves the original value
    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node prop=1.23E-1000\n", output);
}
