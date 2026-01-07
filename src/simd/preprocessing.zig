//! KDL Preprocessing Pass (simdjson-style Stage 1)

const std = @import("std");
const simd = @import("../simd.zig");
const structural_scanner = @import("structural_scanner.zig");
const stream_types = @import("types");

pub const BLOCK_SIZE: usize = 64;

pub const PreprocessedIndex = struct {
    indices: []u64,
    count: usize,
    source_len: usize,

    pub fn deinit(self: *const PreprocessedIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
    }

    pub fn toStructuralIndex(self: *const PreprocessedIndex) structural_scanner.StructuralIndex {
        return .{
            .indices = self.indices,
            .count = self.count,
        };
    }
};

fn resolveEscapes(backslashes: u64, carry: *bool) u64 {
    if (backslashes == 0) {
        if (carry.*) {
            carry.* = false;
            return 1;
        }
        return 0;
    }
    const prev_backslashes = (backslashes << 1) | @as(u64, @intFromBool(carry.*));
    const run_starts = backslashes & ~prev_backslashes;
    const add_result = @addWithOverflow(backslashes, run_starts);
    const sum = add_result[0];
    carry.* = add_result[1] != 0;
    const escaping = sum ^ backslashes;
    return (escaping << 1) | @as(u64, @intFromBool(carry.*));
}

fn resolveStrings(real_quotes: u64, carry: *bool) u64 {
    var in_string = prefixXor(real_quotes);
    if (carry.*) in_string = ~in_string;
    carry.* = (in_string & (@as(u64, 1) << 63)) != 0;
    return in_string;
}

fn prefixXor(x: u64) u64 {
    var result = x;
    result ^= result << 1;
    result ^= result << 2;
    result ^= result << 4;
    result ^= result << 8;
    result ^= result << 16;
    result ^= result << 32;
    return result;
}

pub fn preprocess(allocator: std.mem.Allocator, source: []const u8) !PreprocessedIndex {
    if (source.len == 0) return .{ .indices = &[_]u64{}, .count = 0, .source_len = 0 };

    const initial_cap = @max(source.len / 8, 64);
    var indices = std.ArrayListUnmanaged(u64){};
    try indices.ensureTotalCapacity(allocator, initial_cap);
    errdefer indices.deinit(allocator);

    var escape_carry = false;
    var string_carry = false;
    var in_line_comment = false;
    var block_comment_depth: usize = 0;
    
    var pos: usize = 0;
    while (pos + BLOCK_SIZE <= source.len) : (pos += BLOCK_SIZE) {
        const block = source[pos..][0..BLOCK_SIZE];
        const masks = simd.scanBlock(block);
        
        const escaped = resolveEscapes(masks.backslashes, &escape_carry);
        const real_quotes = masks.quotes & ~escaped;
        const string_mask = resolveStrings(real_quotes, &string_carry);
        
        if (in_line_comment or block_comment_depth > 0 or (masks.slashes & ~string_mask) != 0) {
            var i: usize = 0;
            while (i < BLOCK_SIZE) {
                const c = block[i];
                const char_pos = pos + i;
                if (in_line_comment) {
                    if (c == '\n' or c == '\r') {
                        in_line_comment = false;
                        try indices.append(allocator, @intCast(char_pos));
                    }
                    i += 1;
                } else if (block_comment_depth > 0) {
                    if (c == '/' and i + 1 < BLOCK_SIZE and block[i+1] == '*') { block_comment_depth += 1; i += 2; }
                    else if (c == '*' and i + 1 < BLOCK_SIZE and block[i+1] == '/') { block_comment_depth -= 1; i += 2; }
                    else i += 1;
                } else {
                    const bit = @as(u64, 1) << @as(u6, @intCast(i));
                    if ((string_mask & bit) != 0) {
                        if ((real_quotes & bit) != 0) try indices.append(allocator, @intCast(char_pos));
                        i += 1;
                    } else if (c == '/' and i + 1 < BLOCK_SIZE) {
                        if (block[i+1] == '/') { in_line_comment = true; i += 2; }
                        else if (block[i+1] == '*') { block_comment_depth = 1; i += 2; }
                        else if (block[i+1] == '-') { try indices.append(allocator, @intCast(char_pos)); try indices.append(allocator, @intCast(char_pos + 1)); i += 2; }
                        else { i += 1; }
                    } else {
                        if ((masks.delimiters & bit) != 0 or (masks.hashes & bit) != 0 or (masks.newlines & bit) != 0) {
                            try indices.append(allocator, @intCast(char_pos));
                        }
                        i += 1;
                    }
                }
            }
        } else {
            var mask = (masks.delimiters | masks.newlines | masks.hashes | real_quotes) & ~string_mask;
            while (mask != 0) {
                const bit_pos = @ctz(mask);
                try indices.append(allocator, @intCast(pos + bit_pos));
                mask &= mask - 1;
            }
        }
    }

    while (pos < source.len) : (pos += 1) {
        const c = source[pos];
        if (in_line_comment) {
            if (c == '\n' or c == '\r') { in_line_comment = false; try indices.append(allocator, @intCast(pos)); }
        } else if (block_comment_depth > 0) {
            if (pos + 1 < source.len) {
                if (c == '/' and source[pos+1] == '*') { block_comment_depth += 1; pos += 1; }
                else if (c == '*' and source[pos+1] == '/') { block_comment_depth -= 1; pos += 1; }
            }
        } else {
            const inside_str = string_carry; 
            if (inside_str) {
                if (c == '"') { string_carry = false; try indices.append(allocator, @intCast(pos)); }
            } else if (c == '/' and pos + 1 < source.len) {
                if (source[pos+1] == '/') { in_line_comment = true; pos += 1; }
                else if (source[pos+1] == '*') { block_comment_depth = 1; pos += 1; }
                else if (source[pos+1] == '-') { try indices.append(allocator, @intCast(pos)); try indices.append(allocator, @intCast(pos + 1)); pos += 1; }
            } else {
                if (c == '{' or c == '}' or c == '(' or c == ')' or c == ';' or c == '=' or c == '\n' or c == '\r' or c == '#' or c == '"') {
                    if (c == '"') string_carry = true;
                    try indices.append(allocator, @intCast(pos));
                }
            }
        }
    }

    const final_indices = try indices.toOwnedSlice(allocator);
    return .{ .indices = final_indices, .count = final_indices.len, .source_len = source.len };
}

pub fn preprocessParallel(allocator: std.mem.Allocator, source: []const u8, thread_count: usize) !PreprocessedIndex {
    if (source.len < 1024 * 128 or thread_count <= 1) {
        return preprocess(allocator, source);
    }

    const boundaries = try @import("util").boundaries.findNodeBoundaries(allocator, source, thread_count);
    defer allocator.free(boundaries);

    if (boundaries.len == 0) {
        return preprocess(allocator, source);
    }

    var partial_indices = try allocator.alloc([]u64, boundaries.len + 1);
    var partial_counts = try allocator.alloc(usize, boundaries.len + 1);
    
    var wg = std.Thread.WaitGroup{};
    var pool: std.Thread.Pool = undefined;
    try pool.init(.{ .allocator = allocator });
    defer pool.deinit();

    var start_pos: usize = 0;
    for (0..boundaries.len + 1) |i| {
        const end = if (i < boundaries.len) boundaries[i] else source.len;
        const segment = source[start_pos..end];
        
        wg.start();
        try pool.spawn(struct {
            fn run(w: *std.Thread.WaitGroup, alloc: std.mem.Allocator, src: []const u8, idx_ptr: *[]u64, count_ptr: *usize) void {
                defer w.finish();
                const res = preprocess(alloc, src) catch return;
                idx_ptr.* = res.indices;
                count_ptr.* = res.count;
            }
        }.run, .{ &wg, allocator, segment, &partial_indices[i], &partial_counts[i] });
        
        start_pos = end;
    }

    wg.wait();

    var total_count: usize = 0;
    for (partial_counts) |c| total_count += c;

    var final_indices = try allocator.alloc(u64, total_count);
    var offset: usize = 0;
    start_pos = 0;
    for (0..partial_indices.len) |i| {
        const indices = partial_indices[i];
        for (indices) |idx| {
            final_indices[offset] = idx + @as(u64, @intCast(start_pos));
            offset += 1;
        }
        allocator.free(indices);
        start_pos = if (i < boundaries.len) boundaries[i] else source.len;
    }

    allocator.free(partial_indices);
    allocator.free(partial_counts);

    return .{ .indices = final_indices, .count = total_count, .source_len = source.len };
}



