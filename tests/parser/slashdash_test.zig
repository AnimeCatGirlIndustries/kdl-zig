/// KDL 2.0.0 Slashdash Component Tests
/// Unit tests for slashdash (/-) comment behavior.
const std = @import("std");
const kdl = @import("kdl");

/// Count root nodes
fn rootCount(doc: *const kdl.Document) usize {
    return doc.roots.items.len;
}

/// Get first root node handle
fn firstRoot(doc: *const kdl.Document) kdl.NodeHandle {
    var roots = doc.rootIterator();
    return roots.next().?;
}

/// Get node name
fn nodeName(doc: *const kdl.Document, handle: kdl.NodeHandle) []const u8 {
    return doc.getString(doc.nodes.getName(handle));
}

/// Get argument count for a node
fn argCount(doc: *const kdl.Document, handle: kdl.NodeHandle) usize {
    return doc.nodes.getArgRange(handle).count;
}

/// Get arguments for a node
fn args(doc: *const kdl.Document, handle: kdl.NodeHandle) []const kdl.TypedValue {
    const range = doc.nodes.getArgRange(handle);
    return doc.values.getArguments(range);
}

/// Get property count for a node
fn propCount(doc: *const kdl.Document, handle: kdl.NodeHandle) usize {
    return doc.nodes.getPropRange(handle).count;
}

/// Get properties for a node
fn props(doc: *const kdl.Document, handle: kdl.NodeHandle) []const kdl.Property {
    const range = doc.nodes.getPropRange(handle);
    return doc.values.getProperties(range);
}

/// Count children of a node
fn childCount(doc: *const kdl.Document, handle: kdl.NodeHandle) usize {
    var count: usize = 0;
    var children = doc.childIterator(handle);
    while (children.next()) |_| {
        count += 1;
    }
    return count;
}

/// Get first child of a node
fn firstChild(doc: *const kdl.Document, handle: kdl.NodeHandle) ?kdl.NodeHandle {
    var children = doc.childIterator(handle);
    return children.next();
}

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

    try std.testing.expectEqual(@as(usize, 1), rootCount(&doc));
    try std.testing.expectEqualStrings("visible", nodeName(&doc, firstRoot(&doc)));
}

test "slashdash: comment out argument" {
    const input = "node /-1 2 3";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const node = firstRoot(&doc);
    try std.testing.expectEqual(@as(usize, 2), argCount(&doc, node));
    const node_args = args(&doc, node);
    try std.testing.expectEqual(@as(i128, 2), node_args[0].value.integer);
    try std.testing.expectEqual(@as(i128, 3), node_args[1].value.integer);
}

test "slashdash: comment out property" {
    const input = "node /-key=1 other=2";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const node = firstRoot(&doc);
    try std.testing.expectEqual(@as(usize, 1), propCount(&doc, node));
    const node_props = props(&doc, node);
    try std.testing.expectEqualStrings("other", doc.getString(node_props[0].name));
}

test "slashdash: comment out children block" {
    const input =
        \\node /-{
        \\    child
        \\}
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 0), childCount(&doc, firstRoot(&doc)));
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

    const node = firstRoot(&doc);
    try std.testing.expectEqual(@as(usize, 2), argCount(&doc, node));
    const node_args = args(&doc, node);
    try std.testing.expectEqual(@as(i128, 1), node_args[0].value.integer);
    try std.testing.expectEqual(@as(i128, 3), node_args[1].value.integer);
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

    try std.testing.expectEqual(@as(usize, 1), rootCount(&doc));
    try std.testing.expectEqualStrings("node2", nodeName(&doc, firstRoot(&doc)));
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

    try std.testing.expectEqual(@as(usize, 1), rootCount(&doc));
    try std.testing.expectEqualStrings("node2", nodeName(&doc, firstRoot(&doc)));
}

test "slashdash: with single line comment before entry" {
    // /- followed by single line comment should still skip the next entry
    const input =
        \\node 1 /- // comment
        \\2 3
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const node = firstRoot(&doc);
    try std.testing.expectEqual(@as(usize, 2), argCount(&doc, node));
    const node_args = args(&doc, node);
    try std.testing.expectEqual(@as(i128, 1), node_args[0].value.integer);
    try std.testing.expectEqual(@as(i128, 3), node_args[1].value.integer);
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

    try std.testing.expectEqual(@as(usize, 0), childCount(&doc, firstRoot(&doc)));
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

    const node = firstRoot(&doc);
    try std.testing.expectEqual(@as(usize, 1), childCount(&doc, node));
    const child = firstChild(&doc, node).?;
    try std.testing.expectEqualStrings("child2", nodeName(&doc, child));
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

    try std.testing.expectEqual(@as(usize, 1), rootCount(&doc));
    try std.testing.expectEqualStrings("node", nodeName(&doc, firstRoot(&doc)));
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

test "slashdash: multiple children blocks with line continuation" {
    // Complex case: multiple slashdash'd children, one real children, slashdash'd after
    const input =
        \\node foo /-{
        \\    one
        \\} \
        \\/-{
        \\    two
        \\} {
        \\    three
        \\} /-{
        \\    four
        \\}
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const node = firstRoot(&doc);
    try std.testing.expectEqualStrings("node", nodeName(&doc, node));
    try std.testing.expectEqual(@as(usize, 1), argCount(&doc, node));

    const node_args = args(&doc, node);
    try std.testing.expectEqualStrings("foo", doc.getString(node_args[0].value.string));

    try std.testing.expectEqual(@as(usize, 1), childCount(&doc, node));
    const child = firstChild(&doc, node).?;
    try std.testing.expectEqualStrings("three", nodeName(&doc, child));
}
