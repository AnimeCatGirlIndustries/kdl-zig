/// KDL 2.0.0 Comment Tokenization Tests
/// Tests for single-line, multi-line, and slashdash comment handling.
const std = @import("std");
const kdl = @import("kdl");

test "skip single-line comment" {
    const source = "node // this is a comment\nother";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token1 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", tokenizer.getText(token1));

    const token2 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.newline, token2.type);

    const token3 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token3.type);
    try std.testing.expectEqualStrings("other", tokenizer.getText(token3));
}

test "skip multi-line comment" {
    const source = "node /* comment */ arg";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token1 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", tokenizer.getText(token1));

    const token2 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("arg", tokenizer.getText(token2));
}

test "skip nested multi-line comment" {
    const source = "node /* outer /* inner */ outer */ arg";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token1 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", tokenizer.getText(token1));

    const token2 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("arg", tokenizer.getText(token2));
}

test "tokenize slashdash" {
    const source = "/-node";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token1 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.slashdash, token1.type);
    try std.testing.expectEqualStrings("/-", tokenizer.getText(token1));

    const token2 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("node", tokenizer.getText(token2));
}

test "slashdash before argument" {
    const source = "node /-arg other";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    _ = try tokenizer.next(); // node

    const token2 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.slashdash, token2.type);

    const token3 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token3.type);
    try std.testing.expectEqualStrings("arg", tokenizer.getText(token3));

    const token4 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token4.type);
    try std.testing.expectEqualStrings("other", tokenizer.getText(token4));
}

test "multi-line comment spanning lines" {
    const source =
        \\node /*
        \\  multi
        \\  line
        \\*/ arg
    ;
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token1 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", tokenizer.getText(token1));

    const token2 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("arg", tokenizer.getText(token2));
}
