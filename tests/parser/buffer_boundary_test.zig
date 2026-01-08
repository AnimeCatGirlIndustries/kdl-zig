/// Buffer Boundary Regression Tests
///
/// Tests for the buffer boundary bug in StreamingTokenizer.ensureDataFor()
/// where partial reads from the underlying reader cause UnexpectedToken errors.
///
/// The bug: ensureDataFor() only attempts a single read. When that read returns
/// fewer bytes than needed (partial read - allowed by Zig's reader interface),
/// subsequent peek/peekAhead calls return null unexpectedly.
const std = @import("std");
const kdl = @import("kdl");

/// Mock reader that returns at most `max_bytes_per_read` bytes per read call.
/// This simulates partial reads that trigger the buffer boundary bug.
///
/// Uses the `std.Io.Reader` stream interface and only returns `EndOfStream`
/// once the in-memory slice is exhausted.
fn PartialReader(comptime max_bytes_per_read: usize) type {
    return struct {
        const Self = @This();

        data: []const u8,
        pos: usize = 0,
        interface: std.Io.Reader,

        pub fn init(data: []const u8, buffer: []u8) Self {
            return .{
                .data = data,
                .interface = .{
                    .vtable = &.{ .stream = stream },
                    .buffer = buffer,
                    .seek = 0,
                    .end = 0,
                },
            };
        }

        pub fn reader(self: *Self) *std.Io.Reader {
            return &self.interface;
        }

        fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
            const self: *Self = @alignCast(@fieldParentPtr("interface", r));
            if (self.pos >= self.data.len) return error.EndOfStream;

            const remaining = self.data.len - self.pos;
            const request = limit.minInt(remaining);
            if (request == 0) return error.EndOfStream;

            const to_read = @min(request, max_bytes_per_read);
            const slice = self.data[self.pos..][0..to_read];
            const n = try w.write(slice);
            self.pos += n;
            return n;
        }
    };
}

test "buffer boundary: partial reads with small chunks" {
    const allocator = std.testing.allocator;

    // Generate dataset larger than default buffer size (64KB)
    // Each node is ~40 bytes, so 2000 nodes = ~80KB
    var builder = std.Io.Writer.Allocating.init(allocator);
    defer builder.deinit();

    var i: usize = 0;
    while (i < 2000) : (i += 1) {
        try builder.writer.print("node_{d} value=\"test_{d}\"\n", .{ i, i });
    }

    const source = try builder.toOwnedSlice();
    defer allocator.free(source);

    // Use a partial reader that returns only 100 bytes per read.
    // This guarantees many partial reads and will trigger the bug.
    var buffer: [256]u8 = undefined;
    var partial_reader = PartialReader(100).init(source, &buffer);

    // This should succeed but will fail with the bug
    var tokenizer = try kdl.Tokenizer.init(allocator, partial_reader.reader(), 1024);
    defer tokenizer.deinit();

    // Count tokens to verify complete parsing
    var token_count: usize = 0;
    while (true) {
        const token = try tokenizer.next();
        if (token.type == .eof) break;
        token_count += 1;
    }

    // Each node has: identifier, identifier, equals, quoted_string, newline = 5 tokens
    // 2000 nodes * 5 tokens = 10000 tokens
    try std.testing.expect(token_count >= 10000);
}

test "buffer boundary: parsing large dataset with partial reads" {
    const allocator = std.testing.allocator;

    // Generate a dataset that definitely exceeds the buffer
    var builder = std.Io.Writer.Allocating.init(allocator);
    defer builder.deinit();

    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        try builder.writer.print("node_{d} index={d} active=#true score=1.2345e2 {{\n", .{ i, i });
        try builder.writer.print("    child key=\"value_{d}\"\n", .{i});
        try builder.writer.writeAll("}\n");
    }

    const source = try builder.toOwnedSlice();
    defer allocator.free(source);

    // Use partial reader with very small chunks (50 bytes)
    var buffer: [256]u8 = undefined;
    var partial_reader = PartialReader(50).init(source, &buffer);

    // Parse using the streaming parser
    var doc = try kdl.Document.init(allocator);
    defer doc.deinit();

    var parser = try kdl.Parser.init(allocator, &doc, partial_reader.reader(), .{
        .buffer_size = 1024, // Small buffer to force many refills
    });
    defer parser.deinit();

    try parser.parse();

    // Verify we got all nodes
    var count: usize = 0;
    var roots = doc.rootIterator();
    while (roots.next()) |_| count += 1;

    try std.testing.expectEqual(@as(usize, 3000), count);
}

test "buffer boundary: token spanning exact buffer boundary" {
    const allocator = std.testing.allocator;

    // Create input where a token is likely to span the buffer boundary
    // Use a small buffer (256 bytes) and create identifiers near the boundary
    var builder = std.Io.Writer.Allocating.init(allocator);
    defer builder.deinit();

    // Fill with padding to get close to buffer boundary
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        try builder.writer.writeAll("a ");
    }
    // Now add a long identifier that will span the boundary
    try builder.writer.writeAll("this_is_a_very_long_identifier_that_should_span_buffer_boundary ");
    try builder.writer.writeAll("value=123\n");

    // Add more content to ensure we're past the boundary
    i = 0;
    while (i < 50) : (i += 1) {
        try builder.writer.writeAll("b ");
    }

    // Use partial reader returning only 10 bytes at a time
    const source = try builder.toOwnedSlice();
    defer allocator.free(source);
    var buffer: [256]u8 = undefined;
    var partial_reader = PartialReader(10).init(source, &buffer);

    var tokenizer = try kdl.Tokenizer.init(allocator, partial_reader.reader(), 256);
    defer tokenizer.deinit();

    // Should be able to tokenize without error
    var found_long_ident = false;
    while (true) {
        const token = try tokenizer.next();
        if (token.type == .eof) break;
        if (token.type == .identifier) {
            const text = tokenizer.getText(token);
            if (std.mem.eql(u8, text, "this_is_a_very_long_identifier_that_should_span_buffer_boundary")) {
                found_long_ident = true;
            }
        }
    }

    try std.testing.expect(found_long_ident);
}

test "buffer boundary: token ending exactly at buffer boundary" {
    const allocator = std.testing.allocator;

    // This test exercises the edge case where a token ends exactly at the buffer
    // boundary, leaving zero remaining bytes after the shift. The next read must
    // fill from position 0.
    const buffer_size: usize = 64;

    // Create content that fills exactly buffer_size bytes, ending with a complete token
    // "node" (4 bytes) + " " (1 byte) + "x" * 58 (58 bytes) + "\n" (1 byte) = 64 bytes
    var builder = std.Io.Writer.Allocating.init(allocator);
    defer builder.deinit();

    try builder.writer.writeAll("node ");
    var i: usize = 0;
    while (i < 58) : (i += 1) {
        try builder.writer.writeByte('x');
    }
    try builder.writer.writeByte('\n');

    // Add more content after the boundary
    try builder.writer.writeAll("second_node value=42\n");

    // Use a partial reader that returns exactly buffer_size bytes on first read,
    // then continues with remaining data
    const source = try builder.toOwnedSlice();
    defer allocator.free(source);
    var buffer: [128]u8 = undefined;
    var partial_reader = PartialReader(buffer_size).init(source, &buffer);

    var tokenizer = try kdl.Tokenizer.init(allocator, partial_reader.reader(), buffer_size);
    defer tokenizer.deinit();

    // Should be able to tokenize all content including across the exact boundary
    var token_count: usize = 0;
    var found_second_node = false;
    while (true) {
        const token = try tokenizer.next();
        if (token.type == .eof) break;
        token_count += 1;
        if (token.type == .identifier) {
            const text = tokenizer.getText(token);
            if (std.mem.eql(u8, text, "second_node")) {
                found_second_node = true;
            }
        }
    }

    try std.testing.expect(token_count > 0);
    try std.testing.expect(found_second_node);
}
