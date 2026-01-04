const std = @import("std");
const kdl = @import("kdl");

// Integration tests - tokenize complete KDL documents

test "tokenize simple node" {
    var tokenizer = kdl.Tokenizer.init("node");

    const token1 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", token1.text);

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.eof, token2.type);
}

test "tokenize node with argument" {
    var tokenizer = kdl.Tokenizer.init("node 123");

    const token1 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.identifier, token1.type);
    try std.testing.expectEqualStrings("node", token1.text);

    const token2 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.integer, token2.type);
    try std.testing.expectEqualStrings("123", token2.text);

    const token3 = tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.eof, token3.type);
}

test "tokenize node with property" {
    var tokenizer = kdl.Tokenizer.init("node key=\"value\"");

    const tokens = [_]struct { type: kdl.TokenType, text: []const u8 }{
        .{ .type = .identifier, .text = "node" },
        .{ .type = .identifier, .text = "key" },
        .{ .type = .equals, .text = "=" },
        .{ .type = .quoted_string, .text = "\"value\"" },
        .{ .type = .eof, .text = "" },
    };

    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected.type, actual.type);
        if (expected.text.len > 0) {
            try std.testing.expectEqualStrings(expected.text, actual.text);
        }
    }
}

test "tokenize node with children" {
    var tokenizer = kdl.Tokenizer.init("parent { child }");

    const tokens = [_]kdl.TokenType{
        .identifier, // parent
        .open_brace, // {
        .identifier, // child
        .close_brace, // }
        .eof,
    };

    for (tokens) |expected_type| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected_type, actual.type);
    }
}

test "tokenize node with type annotation" {
    var tokenizer = kdl.Tokenizer.init("(date)node");

    const tokens = [_]struct { type: kdl.TokenType, text: []const u8 }{
        .{ .type = .open_paren, .text = "(" },
        .{ .type = .identifier, .text = "date" },
        .{ .type = .close_paren, .text = ")" },
        .{ .type = .identifier, .text = "node" },
        .{ .type = .eof, .text = "" },
    };

    for (tokens) |expected| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(expected.type, actual.type);
    }
}

test "tokenize multiple nodes" {
    var tokenizer = kdl.Tokenizer.init("node1\nnode2\nnode3");

    const expected = [_]kdl.TokenType{
        .identifier, // node1
        .newline,
        .identifier, // node2
        .newline,
        .identifier, // node3
        .eof,
    };

    for (expected) |exp| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "tokenize semicolon-separated nodes" {
    var tokenizer = kdl.Tokenizer.init("node1; node2; node3");

    const expected = [_]kdl.TokenType{
        .identifier, // node1
        .semicolon,
        .identifier, // node2
        .semicolon,
        .identifier, // node3
        .eof,
    };

    for (expected) |exp| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "tokenize complex node" {
    // node (type)arg1 "arg2" key=value { child }
    var tokenizer = kdl.Tokenizer.init("node (u8)42 \"hello\" enabled=#true { child }");

    const expected = [_]kdl.TokenType{
        .identifier, // node
        .open_paren, // (
        .identifier, // u8
        .close_paren, // )
        .integer, // 42
        .quoted_string, // "hello"
        .identifier, // enabled
        .equals, // =
        .keyword_true, // #true
        .open_brace, // {
        .identifier, // child
        .close_brace, // }
        .eof,
    };

    for (expected) |exp| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "track line and column numbers" {
    var tokenizer = kdl.Tokenizer.init("node\nother");

    const token1 = tokenizer.next();
    try std.testing.expectEqual(@as(u32, 1), token1.line);
    try std.testing.expectEqual(@as(u32, 1), token1.column);

    _ = tokenizer.next(); // newline

    const token3 = tokenizer.next();
    try std.testing.expectEqual(@as(u32, 2), token3.line);
    try std.testing.expectEqual(@as(u32, 1), token3.column);
}

test "tokenize all value types in one node" {
    var tokenizer = kdl.Tokenizer.init("node 123 3.14 0xFF 0o77 0b11 #true #false #null #inf #-inf #nan \"str\" #\"raw\"#");

    const expected = [_]kdl.TokenType{
        .identifier, // node
        .integer, // 123
        .float, // 3.14
        .hex_integer, // 0xFF
        .octal_integer, // 0o77
        .binary_integer, // 0b11
        .keyword_true,
        .keyword_false,
        .keyword_null,
        .keyword_inf,
        .keyword_neg_inf,
        .keyword_nan,
        .quoted_string, // "str"
        .raw_string, // #"raw"#
        .eof,
    };

    for (expected) |exp| {
        const actual = tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}
