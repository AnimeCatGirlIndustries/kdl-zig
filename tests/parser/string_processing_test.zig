/// KDL 2.0.0 String Processing Component Tests
/// Unit tests for escape sequences, multiline dedent, raw strings.
const std = @import("std");
const kdl = @import("kdl");

// ============================================================================
// Escape Sequence Tests
// ============================================================================

test "escape sequence: basic escapes" {
    const input =
        \\node "hello\nworld\ttab\rcarriage\\backslash\"quote"
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("hello\nworld\ttab\rcarriage\\backslash\"quote", val.string.raw);
}

test "escape sequence: unicode escape" {
    const input =
        \\node "hello\u{1F600}world"
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    // 😀 in UTF-8 is 0xF0 0x9F 0x98 0x80
    try std.testing.expectEqualStrings("hello\xF0\x9F\x98\x80world", val.string.raw);
}

test "escape sequence: whitespace escape" {
    // Backslash followed by whitespace and newline should be discarded
    const input =
        \\node "hello\
        \\world"
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("helloworld", val.string.raw);
}

test "escape sequence: backspace and form feed" {
    const input =
        \\node "\b\f"
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("\x08\x0C", val.string.raw);
}

test "escape sequence: space escape \\s" {
    const input =
        \\node "hello\sworld"
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("hello world", val.string.raw);
}

// ============================================================================
// Raw String Tests
// ============================================================================

test "raw string: basic" {
    const input =
        \\node #"hello world"#
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("hello world", val.string.raw);
}

test "raw string: with escape sequences (not processed)" {
    const input =
        \\node #"hello\nworld"#
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("hello\\nworld", val.string.raw);
}

test "raw string: with embedded quotes" {
    const input =
        \\node #"hello "world""#
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("hello \"world\"", val.string.raw);
}

test "raw string: with double hashes" {
    const input =
        \\node ##"hello #"world"#"##
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("hello #\"world\"#", val.string.raw);
}

// ============================================================================
// Multiline String Tests
// ============================================================================

test "multiline string: basic dedent" {
    const input =
        \\node """
        \\    line one
        \\    line two
        \\    """
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("line one\nline two", val.string.raw);
}

test "multiline string: whitespace-only lines become empty" {
    // Whitespace-only content lines should become empty strings
    const input =
        \\node """
        \\
        \\    """
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("", val.string.raw);
}

test "multiline string: escape sequences are processed" {
    const input =
        \\node """
        \\    hello\tworld
        \\    """
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("hello\tworld", val.string.raw);
}

// ============================================================================
// Multiline Raw String Tests
// ============================================================================

test "multiline raw string: basic" {
    const input =
        \\node #"""
        \\    line one
        \\    line two
        \\    """#
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("line one\nline two", val.string.raw);
}

test "multiline raw string: containing triple quotes" {
    // A ##""" string can contain """ inside it
    const input =
        \\node ##"""
        \\"""hello"""
        \\"""##
    ;
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = doc.nodes[0].arguments[0].value;
    try std.testing.expectEqualStrings("\"\"\"hello\"\"\"", val.string.raw);
}

// ============================================================================
// Serialization Tests
// ============================================================================

test "serialize: string with newlines uses escapes" {
    const input = "node \"hello\\nworld\"";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node \"hello\\nworld\"\n", output);
}

test "serialize: bare identifier for simple strings" {
    const input = "node identifier";
    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const output = try kdl.serializeToString(std.testing.allocator, doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node identifier\n", output);
}
