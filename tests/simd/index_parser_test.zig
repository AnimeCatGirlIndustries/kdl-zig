const std = @import("std");
const index_parser = @import("kdl").index_parser;

test "IndexParser basic" {
    const allocator = std.testing.allocator;
    const source = "node key=\"value\" { child 123; }";
    var doc = try index_parser.parse(allocator, source);
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 2), doc.nodes.count());
}

test "IndexParser bench sample" {
    const allocator = std.testing.allocator;
    const source =
        "node_0 index=0 active=#true score=1.2345e2 { \n    child key=\"value_0\"\n}\n" ++
        "node_1 index=1 active=#true score=1.2345e2 { \n    child key=\"value_1\"\n}\n";

    const structural = @import("kdl").simd.structural;
    const index = try structural.scan(allocator, source, .{});
    defer index.deinit(allocator);

    var doc = try @import("kdl").Document.init(allocator);
    errdefer doc.deinit();

    var parser = index_parser.IndexParser.init(allocator, source, index, &doc, .{});
    try parser.parse();

    try std.testing.expectEqual(@as(usize, 4), doc.nodes.count());
    doc.deinit();
}
