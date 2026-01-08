const std = @import("std");
const kdl = @import("kdl");

pub fn main() !void {
    const source =
        \\// Example KDL document
        \\node "arg1" key="value" {
        \\    child #true
        \\}
    ;

    std.debug.print("Tokenizing KDL document:\n{s}\n\n", .{source});
    std.debug.print("Tokens:\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var reader = std.Io.Reader.fixed(source);
    var tokenizer = try kdl.Tokenizer.init(allocator, &reader, 1024);
    defer tokenizer.deinit();
    while (true) {
        const token = try tokenizer.next();
        const text = tokenizer.getText(token);
        std.debug.print("  [{d}:{d}] {s}: \"{s}\"\n", .{
            token.line,
            token.column,
            @tagName(token.type),
            text,
        });
        if (token.type == .eof) break;
    }
}

test "main compiles" {
    _ = main;
}
