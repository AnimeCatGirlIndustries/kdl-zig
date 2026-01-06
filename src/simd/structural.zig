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
const constants = @import("../constants.zig");
const simd = @import("../simd.zig");

const ScanState = struct {
    in_string: bool = false,
    escaped: bool = false,
    multiline_string: bool = false,
    in_raw_string: bool = false,
    raw_hash_count: usize = 0,
    raw_multiline: bool = false,
    in_line_comment: bool = false,
    block_comment_depth: usize = 0,
    pending_raw_quote_pos: ?usize = null,
    pending_raw_hash_count: usize = 0,
    pending_raw_multiline: bool = false,
    skip_until_pos: ?usize = null,
};

/// A collection of indices pointing to structural characters in the source.
pub const StructuralIndex = struct {
    /// Array of offsets into the source buffer.
    indices: []u32,
    /// Number of valid indices in the array.
    count: usize,

    pub fn deinit(self: StructuralIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
    }

    /// Returns a slice of the valid indices.
    pub fn slice(self: StructuralIndex) []const u32 {
        return self.indices[0..self.count];
    }
};

/// Options for the structural scanner.
pub const ScanOptions = struct {
    /// Initial capacity for the index array.
    initial_capacity: usize = 1024,
    /// Chunk size for streaming scans.
    chunk_size: usize = constants.DEFAULT_BUFFER_SIZE,
    /// Maximum document size for streaming scans.
    max_document_size: usize = constants.MAX_POOL_SIZE,
};

const Chunk = struct {
    data: []u8,
    len: usize,
};

/// Chunked source storage for streaming scans.
pub const ChunkedSource = struct {
    chunks: []Chunk,
    offsets: []usize,
    total_len: usize,

    pub fn deinit(self: ChunkedSource, allocator: std.mem.Allocator) void {
        for (self.chunks) |chunk| {
            allocator.free(chunk.data);
        }
        allocator.free(self.chunks);
        allocator.free(self.offsets);
    }
};

pub const ScanResult = struct {
    source: ChunkedSource,
    index: StructuralIndex,

    pub fn deinit(self: ScanResult, allocator: std.mem.Allocator) void {
        self.source.deinit(allocator);
        self.index.deinit(allocator);
    }
};

const HandleResult = enum {
    ok,
    need_more,
};

const Scanner = struct {
    allocator: std.mem.Allocator,
    indices: []u32,
    count: usize = 0,
    state: ScanState = .{},
    cursor: usize = 0,

    fn init(allocator: std.mem.Allocator, capacity: usize) !Scanner {
        const init_cap = if (capacity == 0) 1 else capacity;
        return Scanner{
            .allocator = allocator,
            .indices = try allocator.alloc(u32, init_cap),
        };
    }

    fn scanAvailable(self: *Scanner, data: []const u8, at_eof: bool, base_offset: usize) !void {
        var pos = self.cursor;
        const len = data.len;

        while (pos + 64 <= len) {
            const block = data[pos..][0..64];
            const mask = simd.scanStructuralMask(block);

            if (mask != 0) {
                var bits = mask;
                while (bits != 0) {
                    const bit_pos = @ctz(bits);
                    const char_pos = pos + bit_pos;
                    const result = try handleCandidate(
                        self.allocator,
                        data,
                        &self.state,
                        &self.indices,
                        &self.count,
                        char_pos,
                        at_eof,
                        base_offset,
                    );
                    if (result == .need_more) {
                        self.cursor = char_pos;
                        return;
                    }
                    bits &= bits - 1;
                }
            }
            pos += 64;
        }

        while (pos < len) {
            const c = data[pos];
            if (!isStructuralCandidate(c)) {
                pos += 1;
                continue;
            }
            const result = try handleCandidate(
                self.allocator,
                data,
                &self.state,
                &self.indices,
                &self.count,
                pos,
                at_eof,
                base_offset,
            );
            if (result == .need_more) {
                self.cursor = pos;
                return;
            }
            pos += 1;
        }

        self.cursor = pos;
    }

    fn finish(self: *Scanner) StructuralIndex {
        return StructuralIndex{
            .indices = self.indices,
            .count = self.count,
        };
    }
};

/// Scan the input data and generate a structural index.
pub fn scan(allocator: std.mem.Allocator, data: []const u8, options: ScanOptions) !StructuralIndex {
    const capacity = @max(options.initial_capacity, data.len / 8);
    var scanner = try Scanner.init(allocator, capacity);
    errdefer allocator.free(scanner.indices);

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

    var scanner = try Scanner.init(allocator, options.initial_capacity);
    errdefer allocator.free(scanner.indices);

    const chunk_size = if (options.chunk_size == 0) 1 else options.chunk_size;
    var pending = std.ArrayList(u8).empty;
    errdefer pending.deinit(allocator);

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

        scanner.cursor = 0;
        if (pending.items.len == 0) {
            try scanner.scanAvailable(storage[0..read_len], false, total_len);
            if (scanner.cursor < read_len) {
                pending.clearRetainingCapacity();
                try pending.appendSlice(allocator, storage[scanner.cursor..read_len]);
                pending_offset = total_len + scanner.cursor;
            }
        } else {
            try pending.appendSlice(allocator, storage[0..read_len]);
            try scanner.scanAvailable(pending.items, false, pending_offset);
            if (scanner.cursor < pending.items.len) {
                const drop = scanner.cursor;
                const remaining = pending.items.len - drop;
                if (remaining > 0) {
                    std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[drop..]);
                }
                pending.items.len = remaining;
                pending_offset += drop;
            } else {
                pending.items.len = 0;
            }
        }

        total_len += read_len;
    }

    if (pending.items.len > 0) {
        scanner.cursor = 0;
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

inline fn isStructural(c: u8) bool {
    return switch (c) {
        '{', '}', '(', ')', '"', '\\', '/', ';', '=', '#' => true,
        else => false,
    };
}

inline fn isStructuralCandidate(c: u8) bool {
    return switch (c) {
        '{', '}', '(', ')', '"', '\\', '/', ';', '=', '#', '*', '\n', '\r' => true,
        else => false,
    };
}

fn matchesHashes(data: []const u8, start: usize, count: usize) bool {
    if (start + count > data.len) return false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (data[start + i] != '#') return false;
    }
    return true;
}

fn handleCandidate(
    allocator: std.mem.Allocator,
    data: []const u8,
    state: *ScanState,
    indices: *[]u32,
    count: *usize,
    char_pos: usize,
    at_eof: bool,
    base_offset: usize,
) !HandleResult {
    const c = data[char_pos];

    if (state.skip_until_pos) |skip| {
        if (char_pos <= skip) return .ok;
        state.skip_until_pos = null;
    }

    if (state.in_line_comment) {
        if (c == '\n' or c == '\r') {
            state.in_line_comment = false;
        }
        return .ok;
    }

    if (state.block_comment_depth > 0) {
        if ((c == '/' or c == '*') and char_pos + 1 >= data.len) {
            if (!at_eof) return .need_more;
        }
        if (c == '/' and char_pos + 1 < data.len and data[char_pos + 1] == '*') {
            state.block_comment_depth += 1;
        } else if (c == '*' and char_pos + 1 < data.len and data[char_pos + 1] == '/') {
            state.block_comment_depth -= 1;
        }
        return .ok;
    }

    if (state.in_raw_string) {
        if (c == '"') {
            if (state.raw_multiline) {
                if (char_pos + 2 >= data.len) {
                    if (!at_eof) return .need_more;
                    return .ok;
                }
                if (char_pos + 2 < data.len and data[char_pos + 1] == '"' and data[char_pos + 2] == '"') {
                    if (char_pos + 3 + state.raw_hash_count > data.len) {
                        if (!at_eof) return .need_more;
                        return .ok;
                    }
                    if (matchesHashes(data, char_pos + 3, state.raw_hash_count)) {
                        state.in_raw_string = false;
                        state.raw_multiline = false;
                        state.raw_hash_count = 0;
                        try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
                        try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 1));
                        try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 2));
                        state.skip_until_pos = char_pos + 2;
                    }
                }
            } else {
                if (char_pos + 1 + state.raw_hash_count > data.len) {
                    if (!at_eof) return .need_more;
                    return .ok;
                }
                if (matchesHashes(data, char_pos + 1, state.raw_hash_count)) {
                    state.in_raw_string = false;
                    state.raw_hash_count = 0;
                    try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
                }
            }
        }
        return .ok;
    }

    if (state.in_string) {
        if (state.multiline_string) {
            if (state.escaped) {
                state.escaped = false;
                return .ok;
            }
            if (c == '\\') {
                state.escaped = true;
                return .ok;
            }
            if (c == '"' and
                char_pos + 2 < data.len and
                data[char_pos + 1] == '"' and
                data[char_pos + 2] == '"')
            {
                state.in_string = false;
                state.multiline_string = false;
                try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
                try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 1));
                try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 2));
                state.skip_until_pos = char_pos + 2;
            }
            if (c == '"' and char_pos + 2 >= data.len and !at_eof) {
                return .need_more;
            }
            return .ok;
        }

        if (state.escaped) {
            state.escaped = false;
            return .ok;
        }
        if (c == '\\') {
            state.escaped = true;
            return .ok;
        }
        if (c == '"') {
            state.in_string = false;
            state.multiline_string = false;
            try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
        }
        return .ok;
    }

    if (state.pending_raw_quote_pos != null and char_pos == state.pending_raw_quote_pos.?) {
        state.in_raw_string = true;
        state.raw_hash_count = state.pending_raw_hash_count;
        state.raw_multiline = state.pending_raw_multiline;
        state.pending_raw_quote_pos = null;
        try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
        if (state.raw_multiline) {
            if (char_pos + 2 >= data.len and !at_eof) {
                return .need_more;
            }
            if (char_pos + 1 < data.len) {
                try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 1));
            }
            if (char_pos + 2 < data.len) {
                try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 2));
                state.skip_until_pos = char_pos + 2;
            }
        }
        return .ok;
    }

    if (c == '/' and char_pos + 1 < data.len) {
        const next = data[char_pos + 1];
        if (next == '/') {
            state.in_line_comment = true;
            return .ok;
        }
        if (next == '*') {
            state.block_comment_depth = 1;
            return .ok;
        }
    } else if (c == '/' and char_pos + 1 >= data.len) {
        if (!at_eof) return .need_more;
    }

    if (c == '"') {
        if (char_pos + 2 >= data.len and !at_eof) {
            return .need_more;
        }
        if (char_pos + 2 < data.len and
            data[char_pos + 1] == '"' and
            data[char_pos + 2] == '"')
        {
            state.in_string = true;
            state.multiline_string = true;
            state.escaped = false;
            try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
            try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 1));
            try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos + 2));
            state.skip_until_pos = char_pos + 2;
            return .ok;
        }

        state.in_string = true;
        state.multiline_string = false;
        state.escaped = false;
        try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
        return .ok;
    }

    if (c == '#') {
        if (char_pos == 0 or data[char_pos - 1] != '#') {
            var hash_count: usize = 1;
            var scan_pos = char_pos + 1;
            while (scan_pos < data.len and data[scan_pos] == '#') : (scan_pos += 1) {
                hash_count += 1;
            }
            if (scan_pos >= data.len) {
                if (!at_eof) return .need_more;
            } else if (data[scan_pos] == '"') {
                if (scan_pos + 2 >= data.len and !at_eof) {
                    return .need_more;
                }
                state.pending_raw_quote_pos = scan_pos;
                state.pending_raw_hash_count = hash_count;
                state.pending_raw_multiline = scan_pos + 2 < data.len and
                    data[scan_pos + 1] == '"' and
                    data[scan_pos + 2] == '"';
            }
        }
    }

    if (isStructural(c)) {
        try appendIndex(allocator, indices, count, @intCast(base_offset + char_pos));
    }

    return .ok;
}

fn appendIndex(allocator: std.mem.Allocator, indices: *[]u32, count: *usize, value: u32) !void {
    if (count.* >= indices.len) {
        const new_cap = if (indices.len == 0) 1 else indices.len * 2;
        indices.* = try allocator.realloc(indices.*, new_cap);
    }
    indices.*[count.*] = value;
    count.* += 1;
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

fn containsIndex(indices: []const u32, pos: usize) bool {
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
    try std.testing.expectEqualSlices(u32, direct.slice(), streamed.index.slice());
}
