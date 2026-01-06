//! Structural scan core for SIMD stage 1.

const std = @import("std");
const simd = @import("../simd.zig");

pub const ScanState = struct {
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

const HandleResult = enum {
    ok,
    need_more,
};

pub const Scanner = struct {
    allocator: std.mem.Allocator,
    indices: []u32,
    count: usize = 0,
    state: ScanState = .{},
    cursor_pos: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Scanner {
        const init_cap = if (capacity == 0) 1 else capacity;
        return Scanner{
            .allocator = allocator,
            .indices = try allocator.alloc(u32, init_cap),
        };
    }

    pub fn setCursor(self: *Scanner, pos: usize) void {
        self.cursor_pos = pos;
    }

    pub fn cursor(self: *const Scanner) usize {
        return self.cursor_pos;
    }

    pub fn dropPending(self: *Scanner, drop: usize) void {
        if (drop == 0) return;
        if (self.state.skip_until_pos) |skip| {
            if (drop > skip) {
                self.state.skip_until_pos = null;
            } else {
                self.state.skip_until_pos = skip - drop;
            }
        }
        if (self.state.pending_raw_quote_pos) |pos| {
            if (drop > pos) {
                self.state.pending_raw_quote_pos = null;
            } else {
                self.state.pending_raw_quote_pos = pos - drop;
            }
        }
    }

    pub fn scanAvailable(self: *Scanner, data: []const u8, at_eof: bool, base_offset: usize) !void {
        var pos = self.cursor_pos;
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
                        self.cursor_pos = char_pos;
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
                self.cursor_pos = pos;
                return;
            }
            pos += 1;
        }

        self.cursor_pos = pos;
    }

    pub fn finish(self: *Scanner) StructuralIndex {
        return StructuralIndex{
            .indices = self.indices,
            .count = self.count,
        };
    }
};

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
