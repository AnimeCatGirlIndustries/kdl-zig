/// KDL 2.0.0 Validation Tests
/// TDD tests for input validation - things that should fail.
const std = @import("std");
const kdl = @import("kdl");

test "bare 'false' as property key should fail" {
    const input = "node false=1";
    const result = kdl.parse(std.testing.allocator, input);
    // Bare 'false' without # is illegal in KDL 2.0
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "bare 'true' as property key should fail" {
    const input = "node true=1";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "bare 'null' as property key should fail" {
    const input = "node null=1";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "quoted 'false' as property key should succeed" {
    const input =
        \\node "false"=1
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.nodes[0].properties.len);
    try std.testing.expectEqualStrings("false", doc.nodes[0].properties[0].name);
}

test "number-like identifier should fail" {
    // 0n looks like a number but isn't valid - rejected by tokenizer
    const input = "node 0n";
    const result = kdl.parse(std.testing.allocator, input);
    try std.testing.expectError(error.UnexpectedToken, result);
}

test "valid identifier starting with letter after digit should work" {
    // Regular identifiers are fine
    const input = "node value";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();
    try std.testing.expectEqualStrings("value", doc.nodes[0].arguments[0].value.string.raw);
}
