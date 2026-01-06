/// Shared grammar helpers for KDL parsing.

/// ASCII token terminators for identifiers and tokens.
pub fn isTokenTerminator(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r' => true,
        '(', ')', '{', '}', '[', ']', '/', '\\', '"', '#', ';', '=' => true,
        0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F, 0x7F => true,
        else => false,
    };
}

/// Bare keyword identifiers disallowed by the KDL grammar.
pub fn isBareKeyword(text: []const u8) bool {
    return std.mem.eql(u8, text, "true") or
        std.mem.eql(u8, text, "false") or
        std.mem.eql(u8, text, "null") or
        std.mem.eql(u8, text, "inf") or
        std.mem.eql(u8, text, "nan");
}

/// ASCII newline characters recognized by the tokenizer.
pub fn isAsciiNewline(c: u8) bool {
    return switch (c) {
        '\n', '\r', 0x0B, 0x0C => true,
        else => false,
    };
}

const std = @import("std");
