const std = @import("std");
const kdl = @import("kdl");

test "slashdash_multiple_child_blocks debug" {
    const input = 
        \\node foo /-{
        \\    one
        \\} \
        \\/-{
        \\    two
        \\} {
        \\    three
        \\} /-{
        \\    four
        \\}
    ;
    
    std.debug.print("\nInput:\n{s}\n\n", .{input});
    
    var doc = kdl.parse(std.testing.allocator, input) catch |err| {
        std.debug.print("Parse error: {any}\n", .{err});
        return err;
    };
    defer doc.deinit();
    
    std.debug.print("Parse succeeded!\n", .{});
    const output = try kdl.serializeToString(std.testing.allocator, &doc, .{});
    defer std.testing.allocator.free(output);
    std.debug.print("Output:\n{s}\n", .{output});
}
