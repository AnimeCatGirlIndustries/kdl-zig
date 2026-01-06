/// KDL 2.0.0 Number Processing Component Tests
/// Unit tests for number parsing and serialization.
const std = @import("std");
const kdl = @import("kdl");

/// Helper to get first argument value of first root node
fn getFirstArg(doc: *const kdl.Document) kdl.Value {
    var roots = doc.rootIterator();
    const handle = roots.next().?;
    const arg_range = doc.nodes.getArgRange(handle);
    const args = doc.values.getArguments(arg_range);
    return args[0].value;
}

// ============================================================================
// Integer Parsing Tests
// ============================================================================

test "integer: basic decimal" {
    const input = "node 42";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i128, 42), getFirstArg(&doc).integer);
}

test "integer: negative" {
    const input = "node -42";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i128, -42), getFirstArg(&doc).integer);
}

test "integer: positive sign" {
    const input = "node +42";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i128, 42), getFirstArg(&doc).integer);
}

test "integer: with underscores" {
    const input = "node 1_000_000";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i128, 1000000), getFirstArg(&doc).integer);
}

test "integer: hex" {
    const input = "node 0xFF";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i128, 255), getFirstArg(&doc).integer);
}

test "integer: octal" {
    const input = "node 0o77";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i128, 63), getFirstArg(&doc).integer);
}

test "integer: binary" {
    const input = "node 0b1010";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(i128, 10), getFirstArg(&doc).integer);
}

// ============================================================================
// Float Parsing Tests
// ============================================================================

test "float: basic decimal" {
    const input = "node 3.14";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, 3.14), getFirstArg(&doc).float.value, 0.001);
}

test "float: negative" {
    const input = "node -3.14";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectApproxEqAbs(@as(f64, -3.14), getFirstArg(&doc).float.value, 0.001);
}

test "float: scientific notation positive exponent" {
    const input = "node 1.0e10";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectApproxEqRel(@as(f64, 1.0e10), getFirstArg(&doc).float.value, 0.001);
}

test "float: scientific notation negative exponent" {
    const input = "node 1.0e-10";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectApproxEqRel(@as(f64, 1.0e-10), getFirstArg(&doc).float.value, 0.001);
}

test "float: scientific notation uppercase E" {
    const input = "node 1.5E+5";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectApproxEqRel(@as(f64, 1.5e5), getFirstArg(&doc).float.value, 0.001);
}

test "float: integer mantissa with exponent" {
    const input = "node 1e10";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectApproxEqRel(@as(f64, 1e10), getFirstArg(&doc).float.value, 0.001);
}

test "float: with underscores in exponent" {
    const input = "node 1.0e1_00";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectApproxEqRel(@as(f64, 1.0e100), getFirstArg(&doc).float.value, 0.001);
}

// ============================================================================
// Integer Serialization Tests
// ============================================================================

test "serialize: integer" {
    const input = "node 42";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node 42\n", output);
}

test "serialize: hex converts to decimal" {
    const input = "node 0xFF";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node 255\n", output);
}

test "serialize: octal converts to decimal" {
    const input = "node 0o77";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node 63\n", output);
}

test "serialize: binary converts to decimal" {
    const input = "node 0b1010";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node 10\n", output);
}

// ============================================================================
// Float Serialization Tests
// ============================================================================

test "serialize: simple float" {
    const input = "node 3.14";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node 3.14\n", output);
}

test "serialize: float 1.0 preserves decimal" {
    const input = "node 1.0";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node 1.0\n", output);
}

test "serialize: scientific notation large" {
    // 1e10 is large enough to trigger scientific notation
    const input = "node 1e10";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    // Should output in scientific notation with uppercase E and sign
    try std.testing.expect(std.mem.indexOf(u8, output, "E+") != null);
}

test "serialize: scientific notation small" {
    // Very small numbers should use scientific notation
    const input = "node 1e-10";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    // Should output in scientific notation
    try std.testing.expect(std.mem.indexOf(u8, output, "E-") != null);
}

// ============================================================================
// Special Float Values
// ============================================================================

test "parse and serialize: positive infinity" {
    const input = "node #inf";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expect(getFirstArg(&doc) == .positive_inf);

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node #inf\n", output);
}

test "parse and serialize: negative infinity" {
    const input = "node #-inf";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expect(getFirstArg(&doc) == .negative_inf);

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node #-inf\n", output);
}

test "parse and serialize: nan" {
    const input = "node #nan";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expect(getFirstArg(&doc) == .nan_value);

    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node #nan\n", output);
}
