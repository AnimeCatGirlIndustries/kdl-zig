/// KDL 2.0.0 Comment Tokenization Tests
/// Tests for single-line, multi-line, and slashdash comment handling.
const std = @import("std");
const kdl = @import("kdl");

test "skip single-line comment" {
    var tokenizer = kdl.Tokenizer.init("node // this is a comment\nother");

    const token1 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", token1.text);

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.newline, token2.type);

    const token3 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token3.type);
    try std.testing.expectEqualStrings("other", token3.text);
}

test "skip multi-line comment" {
    var tokenizer = kdl.Tokenizer.init("node /* comment */ arg");

    const token1 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", token1.text);

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("arg", token2.text);
}

test "skip nested multi-line comment" {
    var tokenizer = kdl.Tokenizer.init("node /* outer /* inner */ outer */ arg");

    const token1 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", token1.text);

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("arg", token2.text);
}

test "tokenize slashdash" {
    var tokenizer = kdl.Tokenizer.init("/-node");

    const token1 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.slashdash, token1.type);
    try std.testing.expectEqualStrings("/-", token1.text);

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("node", token2.text);
}

test "slashdash before argument" {
    var tokenizer = kdl.Tokenizer.init("node /-arg other");

    _ = tokenizer.next(); // node

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.slashdash, token2.type);

    const token3 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token3.type);
    try std.testing.expectEqualStrings("arg", token3.text);

    const token4 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token4.type);
    try std.testing.expectEqualStrings("other", token4.text);
}

test "multi-line comment spanning lines" {
    var tokenizer = kdl.Tokenizer.init(
        \\node /*
        \\  multi
        \\  line
        \\*/ arg
    );

    const token1 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", token1.text);

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token2.type);
    try std.testing.expectEqualStrings("arg", token2.text);
}
