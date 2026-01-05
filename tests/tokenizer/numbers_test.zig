/// KDL 2.0.0 Number Tokenization Tests
/// Tests for decimal, hex, octal, binary, and float number tokens.
const std = @import("std");
const kdl = @import("kdl");

test "tokenize integer" {
    var tokenizer = kdl.Tokenizer.init("123");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("123", token.text);
}

test "tokenize negative integer" {
    var tokenizer = kdl.Tokenizer.init("-456");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("-456", token.text);
}

test "tokenize positive integer with sign" {
    var tokenizer = kdl.Tokenizer.init("+789");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("+789", token.text);
}

test "tokenize integer with underscores" {
    var tokenizer = kdl.Tokenizer.init("1_000_000");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("1_000_000", token.text);
}

test "tokenize float" {
    var tokenizer = kdl.Tokenizer.init("3.14");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.float, token.type);
    try std.testing.expectEqualStrings("3.14", token.text);
}

test "tokenize float with exponent" {
    var tokenizer = kdl.Tokenizer.init("1.5e10");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.float, token.type);
    try std.testing.expectEqualStrings("1.5e10", token.text);
}

test "tokenize float with negative exponent" {
    var tokenizer = kdl.Tokenizer.init("2.5E-3");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.float, token.type);
    try std.testing.expectEqualStrings("2.5E-3", token.text);
}

test "tokenize hexadecimal" {
    var tokenizer = kdl.Tokenizer.init("0xDEADBEEF");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.hex_integer, token.type);
    try std.testing.expectEqualStrings("0xDEADBEEF", token.text);
}

test "tokenize hexadecimal lowercase" {
    var tokenizer = kdl.Tokenizer.init("0x1a2b3c");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.hex_integer, token.type);
}

test "tokenize octal" {
    var tokenizer = kdl.Tokenizer.init("0o755");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.octal_integer, token.type);
    try std.testing.expectEqualStrings("0o755", token.text);
}

test "tokenize binary" {
    var tokenizer = kdl.Tokenizer.init("0b1010");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.binary_integer, token.type);
    try std.testing.expectEqualStrings("0b1010", token.text);
}

test "tokenize binary with underscores" {
    var tokenizer = kdl.Tokenizer.init("0b1010_0101");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.binary_integer, token.type);
}
