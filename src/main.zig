const std = @import("std");
const kdl = @import("kdl");

pub fn main() void {
    const source =
        \\// Example KDL document
        \\node "arg1" key="value" {
        \\    child #true
        \\}
    ;

    std.debug.print("Tokenizing KDL document:\n{s}\n\n", .{source});
    std.debug.print("Tokens:\n", .{});

    var tokenizer = kdl.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        std.debug.print("  [{d}:{d}] {s}: \"{s}\"\n", .{
            token.line,
            token.column,
            @tagName(token.type),
            token.text,
        });
        if (token.type == .eof) break;
    }
}

test "main compiles" {
    _ = main;
}
