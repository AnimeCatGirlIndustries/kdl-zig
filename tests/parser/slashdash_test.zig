/// KDL 2.0.0 Slashdash Component Tests
/// Unit tests for slashdash (/-) comment behavior.
const std = @import("std");
const kdl = @import("kdl");

// ============================================================================
// Basic Slashdash Tests
// ============================================================================

test "slashdash: comment out node" {
    const input =
        \\/-commented
        \\visible
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqualStrings("visible", doc.nodes[0].name);
}

test "slashdash: comment out argument" {
    const input = "node /-1 2 3";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.nodes[0].arguments.len);
    try std.testing.expectEqual(@as(i128, 2), doc.nodes[0].arguments[0].value.integer);
    try std.testing.expectEqual(@as(i128, 3), doc.nodes[0].arguments[1].value.integer);
}

test "slashdash: comment out property" {
    const input = "node /-key=1 other=2";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes[0].properties.len);
    try std.testing.expectEqualStrings("other", doc.nodes[0].properties[0].name);
}

test "slashdash: comment out children block" {
    const input =
        \\node /-{
        \\    child
        \\}
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.nodes[0].children.len);
}

// ============================================================================
// Slashdash with Newlines - THESE ARE THE FAILING TESTS
// ============================================================================

test "slashdash: newline before entry" {
    // /- followed by newline should skip the entry after the newline
    const input =
        \\node 1 /-
        \\2 3
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.nodes[0].arguments.len);
    try std.testing.expectEqual(@as(i128, 1), doc.nodes[0].arguments[0].value.integer);
    try std.testing.expectEqual(@as(i128, 3), doc.nodes[0].arguments[1].value.integer);
}

test "slashdash: newline before node" {
    // /- followed by newline should skip the node after the newline
    const input =
        \\/-
        \\node1
        \\node2
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqualStrings("node2", doc.nodes[0].name);
}

test "slashdash: with single line comment before node" {
    // /- followed by single line comment should still skip the next node
    const input =
        \\/- // this is a comment
        \\node1
        \\node2
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqualStrings("node2", doc.nodes[0].name);
}

test "slashdash: with single line comment before entry" {
    // /- followed by single line comment should still skip the next entry
    const input =
        \\node 1 /- // comment
        \\2 3
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.nodes[0].arguments.len);
    try std.testing.expectEqual(@as(i128, 1), doc.nodes[0].arguments[0].value.integer);
    try std.testing.expectEqual(@as(i128, 3), doc.nodes[0].arguments[1].value.integer);
}

test "slashdash: newline before children block" {
    // /- followed by newline then children block should skip the block
    const input =
        \\node /-
        \\{
        \\    child
        \\}
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), doc.nodes[0].children.len);
}

test "slashdash: multiple children blocks (skip first)" {
    // /- before first children block, keep second
    const input =
        \\node /-{
        \\    child1
        \\} {
        \\    child2
        \\}
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes[0].children.len);
    try std.testing.expectEqualStrings("child2", doc.nodes[0].children[0].name);
}

test "slashdash: with line continuation" {
    // escline (\) followed by /- should work
    const input =
        \\node
        \\\
        \\/-
        \\node
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.nodes.len);
    try std.testing.expectEqualStrings("node", doc.nodes[0].name);
}

// ============================================================================
// Slashdash Validation Tests (should fail)
// ============================================================================

test "slashdash: child block before entry is error" {
    // /- cannot skip a children block when entries follow
    // After any children block (even slashdashed), no more entries allowed
    const input =
        \\node /-{
        \\    child
        \\} foo {
        \\    bar
        \\}
    ;
    const result = kdl.parse(std.testing.allocator, input);
    // Should fail because children block (even slashdashed) ends the node
    try std.testing.expectError(error.UnexpectedToken, result);
}
