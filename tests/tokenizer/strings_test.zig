/// KDL 2.0.0 String Tokenization Tests
/// Tests for identifier, quoted, raw, and multiline string tokens.
const std = @import("std");
const kdl = @import("kdl");

test "tokenize identifier string" {
    var tokenizer = kdl.Tokenizer.init("node-name");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token.type);
    try std.testing.expectEqualStrings("node-name", token.text);
}

test "tokenize quoted string" {
    var tokenizer = kdl.Tokenizer.init("\"hello world\"");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.quoted_string, token.type);
    try std.testing.expectEqualStrings("\"hello world\"", token.text);
}

test "tokenize quoted string with escapes" {
    var tokenizer = kdl.Tokenizer.init("\"hello\\nworld\"");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.quoted_string, token.type);
    try std.testing.expectEqualStrings("\"hello\\nworld\"", token.text);
}

test "tokenize raw string" {
    var tokenizer = kdl.Tokenizer.init("#\"raw \\n content\"#");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.raw_string, token.type);
    try std.testing.expectEqualStrings("#\"raw \\n content\"#", token.text);
}

test "tokenize raw string with multiple hashes" {
    var tokenizer = kdl.Tokenizer.init("##\"contains \"# inside\"##");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.raw_string, token.type);
}

test "tokenize multiline string" {
    const source =
        \\"""
        \\  hello
        \\  world
        \\  """
    ;
    var tokenizer = kdl.Tokenizer.init(source);
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.multiline_string, token.type);
}

test "identifier cannot start with digit" {
    var tokenizer = kdl.Tokenizer.init("123abc");
    const token = tokenizer.next();
    // Should be parsed as number, not identifier
    try std.testing.expect(token.type != kdl.TokenType.identifier);
}

test "identifier with hyphens and underscores" {
    var tokenizer = kdl.Tokenizer.init("my-node_name");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token.type);
    try std.testing.expectEqualStrings("my-node_name", token.text);
}
