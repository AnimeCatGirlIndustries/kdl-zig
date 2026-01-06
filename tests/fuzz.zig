/// KDL 2.0.0 Fuzz Testing
/// Property-based testing for parser robustness against arbitrary input.
const std = @import("std");
const kdl = @import("kdl");

test "fuzz stream iterator" {
    // Note: Fuzzing requires passing --fuzz to zig test
    try std.testing.fuzz({}, fuzzStreamIterator, .{});
}

fn fuzzStreamIterator(_: void, input: []const u8) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // We use an arena for the parser allocations to ensure clean sweep
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // Create stream iterator from input slice
    var stream = std.io.fixedBufferStream(input);
    var iter = kdl.StreamIterator(@TypeOf(stream).Reader).init(arena.allocator(), stream.reader()) catch |err| {
        switch (err) {
            error.OutOfMemory, error.EndOfStream, error.InputOutput => return,
            else => return,
        }
    };
    defer iter.deinit();

    while (true) {
        const event = iter.next() catch |err| {
            switch (err) {
                // These are valid parsing errors for random input
                error.UnexpectedToken,
                error.UnexpectedEof,
                error.InvalidNumber,
                error.InvalidString,
                error.InvalidEscape,
                error.NestingTooDeep,
                error.OutOfMemory,
                error.EndOfStream,
                error.InputOutput => return,
                // Any other error would crash the fuzzer (Good!)
            }
        };
        if (event == null) break;
    }
}
