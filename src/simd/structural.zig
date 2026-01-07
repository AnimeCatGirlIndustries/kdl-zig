//! KDL Structural Scanner (Stage 1 of Two-Stage Parsing)
//!
//! This module implements the first stage of a high-performance SIMD parser.
//! It scans the input buffer to identify structural characters while correctly
//! handling string boundaries and escape sequences.
//!
//! The output is a "Structural Index" - an array of offsets to all characters
//! that define the document's structure. Stage 2 (the parser) can then
//! quickly jump between these points, skipping over long identifiers and
//! string content.

const std = @import("std");
const util = @import("util");
const constants = util.constants;
const structural_scanner = @import("structural_scanner.zig");
const stream_types = @import("types");

pub const StructuralIndex = structural_scanner.StructuralIndex;

/// Options for the structural scanner.
pub const ScanOptions = struct {
    /// Initial capacity for the index array.
    initial_capacity: usize = 1024,
    /// Chunk size for streaming scans.
    chunk_size: usize = constants.DEFAULT_BUFFER_SIZE,
    /// Maximum document size for streaming scans.
    max_document_size: usize = constants.MAX_POOL_SIZE,
};

const Chunk = stream_types.Chunk;
pub const ChunkedSource = stream_types.ChunkedSource;

pub const ScanResult = struct {
    source: ChunkedSource,
    index: StructuralIndex,

    pub fn deinit(self: ScanResult, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        self.index.deinit(allocator);
    }
};

/// Scan the input data and generate a structural index.
pub fn scan(allocator: std.mem.Allocator, data: []const u8, options: ScanOptions) !StructuralIndex {
    const capacity = @max(options.initial_capacity, data.len / 8);
    var scanner = try structural_scanner.Scanner.init(allocator, capacity);
    errdefer allocator.free(scanner.indices);

    scanner.setCursor(0);
    try scanner.scanAvailable(data, true, 0);
    return scanner.finish();
}

pub fn scanReader(allocator: std.mem.Allocator, reader: anytype, options: ScanOptions) !ScanResult {
    var chunks = std.ArrayList(Chunk).empty;
    errdefer {
        for (chunks.items) |chunk| allocator.free(chunk.data);
        chunks.deinit(allocator);
    }

    var offsets = std.ArrayList(usize).empty;
    errdefer offsets.deinit(allocator);

    var scanner = try structural_scanner.Scanner.init(allocator, options.initial_capacity);
    errdefer allocator.free(scanner.indices);

    const chunk_size = if (options.chunk_size == 0) 1 else options.chunk_size;
    var pending = std.ArrayList(u8).empty;
    defer pending.deinit(allocator);

    var total_len: usize = 0;
    var pending_offset: usize = 0;

    while (true) {
        var storage = try allocator.alloc(u8, chunk_size);
        const read_len = try reader.read(storage);
        if (read_len == 0) {
            allocator.free(storage);
            break;
        }

        if (total_len + read_len > options.max_document_size) {
            allocator.free(storage);
            return error.StreamTooLong;
        }

        const owned = Chunk{ .data = storage, .len = read_len };
        try offsets.append(allocator, total_len);
        try chunks.append(allocator, owned);

        scanner.setCursor(0);
        if (pending.items.len == 0) {
            try scanner.scanAvailable(storage[0..read_len], false, total_len);
            const cursor = scanner.cursor();
            if (cursor < read_len) {
                scanner.dropPending(cursor);
                pending.clearRetainingCapacity();
                try pending.appendSlice(allocator, storage[cursor..read_len]);
                pending_offset = total_len + cursor;
            } else {
                scanner.state.skip_until_pos = null;
                scanner.state.pending_raw_quote_pos = null;
            }
        } else {
            try pending.appendSlice(allocator, storage[0..read_len]);
            try scanner.scanAvailable(pending.items, false, pending_offset);
            const cursor = scanner.cursor();
            if (cursor < pending.items.len) {
                const drop = cursor;
                scanner.dropPending(drop);
                const remaining = pending.items.len - drop;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[drop..]);
                }
                pending.items.len = remaining;
                pending_offset += drop;
            } else {
                pending.items.len = 0;
                scanner.state.skip_until_pos = null;
                scanner.state.pending_raw_quote_pos = null;
            }
        }

        total_len += read_len;
    }

    if (pending.items.len > 0) {
        scanner.setCursor(0);
        try scanner.scanAvailable(pending.items, true, pending_offset);
    }

    return ScanResult{
        .source = ChunkedSource{
            .chunks = try chunks.toOwnedSlice(allocator),
            .offsets = try offsets.toOwnedSlice(allocator),
            .total_len = total_len,
        },
        .index = scanner.finish(),
    };
}


// ============================================================================ 
// Tests
// ============================================================================ 

test "StructuralIndex basic scan" {
    const allocator = std.testing.allocator;
    const source = "node (type)key=\"value\" { child; }";
    const index = try scan(allocator, source, .{});
    defer index.deinit(allocator);

    // Verify some structural chars were found
    // expected structural indices:
    // node (type)key="value" { child; }
    //      ^    ^   ^      ^ ^      ^ ^
    //      5    10  14     21 23     30 32
    // Quotes and structural chars should be indexed; whitespace is not.

    const structural_chars = index.slice();
    try std.testing.expect(structural_chars.len > 0);

    // Verify that "value" content (a, l, u, e) is NOT structural
    for (structural_chars) |idx| {
        const char = source[idx];
        if (idx > 16 and idx < 20) {
            // characters inside "value"
            try std.testing.expect(char != 'a' and char != 'l' and char != 'u' and char != 'e');
        }
    }
}

fn containsIndex(indices: []const u64, pos: usize) bool {
    for (indices) |idx| {
        if (idx == pos) return true;
    }
    return false;
}

test "StructuralIndex skips line comments" {
    const allocator = std.testing.allocator;
    const source = "node // comment\nnext { child }";
    const index = try scan(allocator, source, .{});
    defer index.deinit(allocator);

    const structural_chars = index.slice();
    const comment_start = std.mem.indexOf(u8, source, "//") orelse return error.TestUnexpectedResult;
    const comment_end = std.mem.indexOfScalarPos(u8, source, comment_start, '\n') orelse return error.TestUnexpectedResult;
    var pos: usize = comment_start;
    while (pos < comment_end) : (pos += 1) {
        try std.testing.expect(!containsIndex(structural_chars, pos));
    }
    const brace_pos = std.mem.indexOfScalar(u8, source, '{') orelse return error.TestUnexpectedResult;
    try std.testing.expect(containsIndex(structural_chars, brace_pos));
}

test "StructuralIndex skips raw string content" {
    const allocator = std.testing.allocator;
    const source = "node #\"{x}\"# next";
    const index = try scan(allocator, source, .{});
    defer index.deinit(allocator);

    const structural_chars = index.slice();
    // raw string content spans indices 7..9
    try std.testing.expect(!containsIndex(structural_chars, 7));
    try std.testing.expect(!containsIndex(structural_chars, 9));
}

test "StructuralIndex skips multiline string content" {
    const allocator = std.testing.allocator;
    const source = "node \"\"\"{x}\"\"\" end";
    const index = try scan(allocator, source, .{});
    defer index.deinit(allocator);

    const structural_chars = index.slice();
    const brace_pos = std.mem.indexOfScalar(u8, source, '{') orelse return error.TestUnexpectedResult;
    try std.testing.expect(!containsIndex(structural_chars, brace_pos));
}

test "StructuralIndex scanReader matches scan" {
    const allocator = std.testing.allocator;
    const source = "node // comment\nnext #\"raw\"# \"\"\"multi\"\"\" { child }";

    var stream = std.io.fixedBufferStream(source);
    const streamed = try scanReader(allocator, stream.reader(), .{
        .chunk_size = 1,
        .max_document_size = source.len,
    });
    defer streamed.deinit(allocator);

    const direct = try scan(allocator, source, .{});
    defer direct.deinit(allocator);

    var rebuilt = std.ArrayList(u8).empty;
    for (streamed.source.chunks) |chunk| {
        try rebuilt.appendSlice(allocator, chunk.data[0..chunk.len]);
    }
    const rebuilt_slice = try rebuilt.toOwnedSlice(allocator);
    defer allocator.free(rebuilt_slice);

    try std.testing.expectEqualStrings(source, rebuilt_slice);
    try std.testing.expectEqualSlices(u64, direct.slice(), streamed.index.slice());
}
