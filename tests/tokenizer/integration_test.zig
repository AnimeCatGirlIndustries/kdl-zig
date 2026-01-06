/// KDL 2.0.0 Tokenizer Integration Tests
/// Tests for tokenizing complete KDL documents.
const std = @import("std");
const kdl = @import("kdl");

test "tokenize simple node" {
    const source = "node";
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
    try std.testing.expectEqual(kdl.TokenType.eof, token2.type);
}

test "tokenize node with argument" {
    const source = "node 123";
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
    try std.testing.expectEqual(kdl.TokenType.integer, token2.type);
    try std.testing.expectEqualStrings("123", tokenizer.getText(token2));

    const token3 = try tokenizer.next();
    try std.testing.expectEqual(kdl.TokenType.eof, token3.type);
}

test "tokenize node with property" {
    const source = "node key=\"value\"";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const expected = [_]kdl.TokenType{
        .identifier, // node
        .identifier, // key
        .equals, // =
        .quoted_string, // "value"
        .eof,
    };

    for (expected) |exp| {
        const actual = try tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "tokenize node with children" {
    const source = "parent { child }";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const expected = [_]kdl.TokenType{
        .identifier, // parent
        .open_brace, // {
        .identifier, // child
        .close_brace, // }
        .eof,
    };

    for (expected) |exp| {
        const actual = try tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "tokenize node with type annotation" {
    const source = "(date)node";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const expected = [_]kdl.TokenType{
        .open_paren, // (
        .identifier, // date
        .close_paren, // )
        .identifier, // node
        .eof,
    };

    for (expected) |exp| {
        const actual = try tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "tokenize multiple nodes" {
    const source = "node1\nnode2\nnode3";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const expected = [_]kdl.TokenType{
        .identifier, // node1
        .newline,
        .identifier, // node2
        .newline,
        .identifier, // node3
        .eof,
    };

    for (expected) |exp| {
        const actual = try tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "tokenize semicolon-separated nodes" {
    const source = "node1; node2; node3";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const expected = [_]kdl.TokenType{
        .identifier, // node1
        .semicolon,
        .identifier, // node2
        .semicolon,
        .identifier, // node3
        .eof,
    };

    for (expected) |exp| {
        const actual = try tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "tokenize complex node" {
    // node (type)arg1 "arg2" key=value { child }
    const source = "node (u8)42 \"hello\" enabled=#true { child }";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

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
        const actual = try tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}

test "track line and column numbers" {
    const source = "node\nother";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

    const token1 = try tokenizer.next();
    try std.testing.expectEqual(@as(u32, 1), token1.line);
    try std.testing.expectEqual(@as(u32, 1), token1.column);

    _ = try tokenizer.next(); // newline

    const token3 = try tokenizer.next();
    try std.testing.expectEqual(@as(u32, 2), token3.line);
    try std.testing.expectEqual(@as(u32, 1), token3.column);
}

test "tokenize all value types in one node" {
    const source = "node 123 3.14 0xFF 0o77 0b11 #true #false #null #inf #-inf #nan \"str\" #\"raw\"#";
    var stream = std.io.fixedBufferStream(source);
    var tokenizer = try kdl.Tokenizer(@TypeOf(stream).Reader).init(
        std.testing.allocator,
        stream.reader(),
        1024,
    );
    defer tokenizer.deinit();

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
        const actual = try tokenizer.next();
        try std.testing.expectEqual(exp, actual.type);
    }
}
