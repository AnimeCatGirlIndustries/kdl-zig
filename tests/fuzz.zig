/// KDL 2.0.0 Fuzz Testing
/// Property-based testing for parser robustness against arbitrary input.
const std = @import("std");
const kdl = @import("kdl");

test "fuzz pull parser" {
    // Note: Fuzzing requires passing --fuzz to zig test
    // For normal test runs, this just runs once with empty input?
    // Actually std.testing.fuzz docs say it runs the function.
    try std.testing.fuzz({}, fuzzPullParser, .{});
}

fn fuzzPullParser(_: void, input: []const u8) !void {
    // We use a GPA that doesn't leak check because we might panic/error out
    // and cleanup might not happen fully, or we just want speed.
    // Actually, for fuzzing, we WANT to detect memory leaks if we exit normally.
    // But if we hit an error, we might not care.
    // std.heap.GeneralPurposeAllocator is fine.
    
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    
    // We use an arena for the parser allocations to ensure clean sweep
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    
    var parser = kdl.PullParser.init(arena.allocator(), input);
    
    while (true) {
        const event = parser.next() catch |err| {
            switch (err) {
                // These are valid parsing errors for random input
                error.UnexpectedToken,
                error.UnexpectedEof,
                error.InvalidNumber,
                error.InvalidString,
                error.InvalidEscape,
                error.OutOfMemory => return,
                // Any other error (like Unreachable) would crash the fuzzer (Good!)
            }
        };
        if (event == null) break;
    }
}
