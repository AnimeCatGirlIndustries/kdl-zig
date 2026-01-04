const std = @import("std");
const kdl = @import("kdl");

// Keyword tokenization tests - #true, #false, #null, #inf, #-inf, #nan

test "tokenize true keyword" {
    var tokenizer = kdl.Tokenizer.init("#true");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_true, token.type);
    try std.testing.expectEqualStrings("#true", token.text);
}

test "tokenize false keyword" {
    var tokenizer = kdl.Tokenizer.init("#false");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_false, token.type);
    try std.testing.expectEqualStrings("#false", token.text);
}

test "tokenize null keyword" {
    var tokenizer = kdl.Tokenizer.init("#null");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_null, token.type);
    try std.testing.expectEqualStrings("#null", token.text);
}

test "tokenize positive infinity" {
    var tokenizer = kdl.Tokenizer.init("#inf");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_inf, token.type);
    try std.testing.expectEqualStrings("#inf", token.text);
}

test "tokenize negative infinity" {
    var tokenizer = kdl.Tokenizer.init("#-inf");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_neg_inf, token.type);
    try std.testing.expectEqualStrings("#-inf", token.text);
}

test "tokenize nan" {
    var tokenizer = kdl.Tokenizer.init("#nan");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.keyword_nan, token.type);
    try std.testing.expectEqualStrings("#nan", token.text);
}

test "bare true is identifier not keyword" {
    // In KDL 2.0, bare 'true' without # is an identifier
    var tokenizer = kdl.Tokenizer.init("true");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token.type);
    try std.testing.expectEqualStrings("true", token.text);
}

test "bare false is identifier not keyword" {
    var tokenizer = kdl.Tokenizer.init("false");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token.type);
}

test "bare null is identifier not keyword" {
    var tokenizer = kdl.Tokenizer.init("null");
    const token = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token.type);
}
