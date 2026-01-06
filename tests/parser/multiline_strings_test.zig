/// KDL 2.0.0 Multiline String Tests
/// TDD tests for multiline string parsing and serialization.
const std = @import("std");
const kdl = @import("kdl");

/// Helper to get first argument string value of first root node
fn getFirstArgString(doc: *const kdl.Document) []const u8 {
    var roots = doc.rootIterator();
    const handle = roots.next().?;
    const arg_range = doc.nodes.getArgRange(handle);
    const args = doc.values.getArguments(arg_range);
    return doc.getString(args[0].value.string);
}

/// Helper to get first argument float value of first root node
fn getFirstArgFloat(doc: *const kdl.Document) f64 {
    var roots = doc.rootIterator();
    const handle = roots.next().?;
    const arg_range = doc.nodes.getArgRange(handle);
    const args = doc.values.getArguments(arg_range);
    return args[0].value.float.value;
}

test "basic multiline string" {
    const input =
        \\node """
        \\hey
        \\everyone
        \\how goes?
        \\"""
    ;

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.roots.items.len);

    var roots = doc.rootIterator();
    const handle = roots.next().?;
    try std.testing.expectEqualStrings("node", doc.getString(doc.nodes.getName(handle)));

    const arg_range = doc.nodes.getArgRange(handle);
    try std.testing.expectEqual(@as(u32, 1), arg_range.count);

    const val = getFirstArgString(&doc);
    try std.testing.expectEqualStrings("hey\neveryone\nhow goes?", val);

    // Serialize and check output
    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node \"hey\\neveryone\\nhow goes?\"\n", output);
}

test "multiline string with indentation" {
    const input =
        \\node """
        \\    hey
        \\   everyone
        \\     how goes?
        \\  """
    ;

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    // Dedent should be based on closing delimiter (2 spaces)
    const val = getFirstArgString(&doc);
    try std.testing.expectEqualStrings("  hey\n everyone\n   how goes?", val);
}

test "multiline string empty" {
    const input =
        \\node """
        \\"""
    ;

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = getFirstArgString(&doc);
    try std.testing.expectEqualStrings("", val);
}

test "multiline raw string" {
    const input =
        \\node #"""
        \\hey
        \\everyone
        \\how goes?
        \\"""#
    ;

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = getFirstArgString(&doc);
    try std.testing.expectEqualStrings("hey\neveryone\nhow goes?", val);
}

test "multiline string with unicode whitespace" {
    // Unicode whitespace should be treated as whitespace for dedenting
    // Using NO-BREAK SPACE (U+00A0 = C2 A0 in UTF-8)
    const input = "node \"\"\"\n\xc2\xa0hello\n\xc2\xa0\"\"\"";

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = getFirstArgString(&doc);
    // After dedenting by U+00A0, should be just "hello"
    try std.testing.expectEqualStrings("hello", val);
}

test "multiline string with escaped delimiter" {
    // node """
    // \"""
    // """
    // The \""" becomes """ (escaped quote followed by two more quotes)
    const input = "node \"\"\"\n\\\"\"\"\n\"\"\"";

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = getFirstArgString(&doc);
    try std.testing.expectEqualStrings("\"\"\"", val);
}

test "multiline string whitespace-only lines with unicode" {
    // Whitespace-only lines should become empty after dedenting, even if they
    // have more whitespace than the dedent prefix.
    // Structure:
    //   - Line 1: [space][U+00A0][U+205F][space][space][space][space] (whitespace-only, has prefix + extra)
    //   - Line 2: 7 ASCII spaces (whitespace-only, doesn't match prefix)
    //   - Line 3: prefix + "  \s " (has content after escape processing = 4 spaces)
    //   - Closing: [space][U+00A0][U+205F][space] (dedent prefix = 7 bytes)
    //
    // Expected result: "\n\n    " (two empty lines become newlines, line 3 = 4 spaces)
    const input = "node \"\"\"\n" ++ // opening
        "\x20\xc2\xa0\xe2\x81\x9f\x20\x20\x20\x20\n" ++ // line 1: prefix + 3 extra spaces
        "\x20\x20\x20\x20\x20\x20\x20\n" ++ // line 2: 7 ASCII spaces
        "\x20\xc2\xa0\xe2\x81\x9f\x20\x20\x20\\s \n" ++ // line 3: prefix + "  \s "
        "\x20\xc2\xa0\xe2\x81\x9f\x20\"\"\""; // closing with prefix

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = getFirstArgString(&doc);
    // Whitespace-only lines become empty, line 3 has 4 spaces after \s escape
    try std.testing.expectEqualStrings("\n\n    ", val);
}

test "scientific notation with decimal point" {
    // Float values should serialize with decimal point for clarity
    const input = "node 1.0e10";

    var doc = try kdl.parse(std.testing.allocator, input);
    defer doc.deinit();

    const val = getFirstArgFloat(&doc);
    try std.testing.expectEqual(@as(f64, 1e10), val);

    // Serialize and check output - always includes .0 for consistency
    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("node 1.0E+10\n", output);
}
