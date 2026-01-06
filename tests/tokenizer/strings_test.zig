/// KDL 2.0.0 String Tokenization Tests
/// Tests for identifier, quoted, raw, and multiline string tokens.
const std = @import("std");
const kdl = @import("kdl");

test "tokenize identifier string" {
    const source = "node-name";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token.type);
    try std.testing.expectEqualStrings("node-name", tokenizer.getText(token));
}

test "tokenize quoted string" {
    const source = "\"hello world\"";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.quoted_string, token.type);
    try std.testing.expectEqualStrings("\"hello world\"", tokenizer.getText(token));
}

test "tokenize quoted string with escapes" {
    const source = "\"hello\\nworld\"";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.quoted_string, token.type);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", tokenizer.getText(token));
}

test "tokenize raw string" {
    const source = "#\"raw \\n content\"#";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.raw_string, token.type);
    try std.testing.expectEqualStrings("#\"raw \\n content\"#", tokenizer.getText(token));
}

test "tokenize raw string with multiple hashes" {
    const source = "##\"contains \"# inside\"##";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.raw_string, token.type);
}

test "tokenize multiline string" {
    const source =
        \\"""
        \\  hello
        \\  world
        \\  """
    ;
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.multiline_string, token.type);
}

test "identifier cannot start with digit" {
    const source = "123abc";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    // Should be parsed as number, not identifier
    try std.testing.expect(token.type != kdl.TokenType.identifier);
}

test "identifier with hyphens and underscores" {
    const source = "my-node_name";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token.type);
    try std.testing.expectEqualStrings("my-node_name", tokenizer.getText(token));
}
