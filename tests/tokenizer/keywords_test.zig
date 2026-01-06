/// KDL 2.0.0 Keyword Tokenization Tests
/// Tests for #true, #false, #null, #inf, #-inf, #nan keyword tokens.
const std = @import("std");
const kdl = @import("kdl");

test "tokenize true keyword" {
    const source = "#true";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_true, token.type);
    try std.testing.expectEqualStrings("#true", tokenizer.getText(token));
}

test "tokenize false keyword" {
    const source = "#false";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_false, token.type);
    try std.testing.expectEqualStrings("#false", tokenizer.getText(token));
}

test "tokenize null keyword" {
    const source = "#null";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_null, token.type);
    try std.testing.expectEqualStrings("#null", tokenizer.getText(token));
}

test "tokenize positive infinity" {
    const source = "#inf";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_inf, token.type);
    try std.testing.expectEqualStrings("#inf", tokenizer.getText(token));
}

test "tokenize negative infinity" {
    const source = "#-inf";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_neg_inf, token.type);
    try std.testing.expectEqualStrings("#-inf", tokenizer.getText(token));
}

test "tokenize nan" {
    const source = "#nan";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_nan, token.type);
    try std.testing.expectEqualStrings("#nan", tokenizer.getText(token));
}

test "bare true is invalid in KDL 2.0" {
    // In KDL 2.0, bare 'true' without # is invalid (must use #true or "true")
    const source = "true";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.invalid, token.type);
    try std.testing.expectEqualStrings("true", tokenizer.getText(token));
}

test "bare false is invalid in KDL 2.0" {
    const source = "false";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.invalid, token.type);
}

test "bare null is invalid in KDL 2.0" {
    const source = "null";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.invalid, token.type);
}
