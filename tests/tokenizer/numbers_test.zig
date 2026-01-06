/// KDL 2.0.0 Number Tokenization Tests
/// Tests for decimal, hex, octal, binary, and float number tokens.
const std = @import("std");
const kdl = @import("kdl");

test "tokenize integer" {
    const source = "123";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("123", tokenizer.getText(token));
}

test "tokenize negative integer" {
    const source = "-456";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("-456", tokenizer.getText(token));
}

test "tokenize positive integer with sign" {
    const source = "+789";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("+789", tokenizer.getText(token));
}

test "tokenize integer with underscores" {
    const source = "1_000_000";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token.type);
    try std.testing.expectEqualStrings("1_000_000", tokenizer.getText(token));
}

test "tokenize float" {
    const source = "3.14";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.float, token.type);
    try std.testing.expectEqualStrings("3.14", tokenizer.getText(token));
}

test "tokenize float with exponent" {
    const source = "1.5e10";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.float, token.type);
    try std.testing.expectEqualStrings("1.5e10", tokenizer.getText(token));
}

test "tokenize float with negative exponent" {
    const source = "2.5E-3";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.float, token.type);
    try std.testing.expectEqualStrings("2.5E-3", tokenizer.getText(token));
}

test "tokenize hexadecimal" {
    const source = "0xDEADBEEF";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.hex_integer, token.type);
    try std.testing.expectEqualStrings("0xDEADBEEF", tokenizer.getText(token));
}

test "tokenize hexadecimal lowercase" {
    const source = "0x1a2b3c";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.hex_integer, token.type);
}

test "tokenize octal" {
    const source = "0o755";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.octal_integer, token.type);
    try std.testing.expectEqualStrings("0o755", tokenizer.getText(token));
}

test "tokenize binary" {
    const source = "0b1010";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.binary_integer, token.type);
    try std.testing.expectEqualStrings("0b1010", tokenizer.getText(token));
}

test "tokenize binary with underscores" {
    const source = "0b1010_0101";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.binary_integer, token.type);
}
