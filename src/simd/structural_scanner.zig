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
            
            // Select mask based on state
            // Priority: comments > strings > normal
            // Note: state transitions happen in handleCandidate, so mask selection is valid for the START of the block.
            // If state changes within the block, we rely on handleCandidate to return .ok and we continue
            // processing subsequent bits. However, the mask is computed ONCE per block.
            // This means if we start in Normal mode, encounter a quote at byte 0, we still use Normal mask for the whole 64 bytes.
            // The Normal mask includes quotes, so we find it. But it also includes { } etc.
            // If we enter string mode at byte 0, bytes 1-63 will be scanned with Normal mask.
            // This is safe because Normal mask is a SUPERSET of String mask (except maybe for * in block comments?).
            // Let's verify supersets.
            // Normal: { } ( ) " \ / ; = # \n \r
            // String: " \ \n \r
            // Normal includes String. So if we transition Normal -> String, we are fine (we might over-scan, but handleCandidate filters).
            // String -> Normal: " ends string. String mask includes ". We find it. Transition to Normal. Next block uses Normal.
            // 
            // Comment -> Normal: \n ends comment. Comment mask includes \n. We find it. Transition.
            // BlockComment -> Normal: */ ends it. Block mask includes * /. We find it.
            
            var mask: u64 = 0;
            if (self.state.in_line_comment) {
                mask = simd.scanCommentMask(block);
            } else if (self.state.block_comment_depth > 0) {
                mask = simd.scanBlockCommentMask(block);
            } else if (self.state.in_raw_string) {
                mask = simd.scanRawStringMask(block);
            } else if (self.state.in_string) {
                mask = simd.scanStringMask(block);
            } else {
                mask = simd.scanStructuralMask(block);
            }

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
                    
                    // If state changed, we should technically switch masks.
                    // But recalculating mask for remainder of block is expensive?
                    // Or maybe we just accept over-scanning for the rest of this block?
                    // Re-calculating mask is cheap compared to scalar fallback.
                    // Let's check if state implies a narrower mask than what we started with.
                    // E.g. Normal -> String. Normal mask > String mask. We are fine.
                    // String -> Normal. String mask < Normal mask. We might MISS structural chars in the rest of the block!
                    // CRITICAL: If we switch from a narrower mask to a wider mask, we MUST re-scan the block remainder!
                    
                    // Transitions:
                    // Normal -> String (Wide -> Narrow): Safe.
                    // Normal -> Comment (Wide -> Narrow): Safe.
                    // String -> Normal (Narrow -> Wide): UNSAFE.
                    // Comment -> Normal (Narrow -> Wide): UNSAFE.
                    
                    // Optimization: check if we need to re-scan.
                    // Ideally, we just break and let the loop restart?
                    // But pos += 64 happens at end.
                    // We can update pos and `continue` outer loop?
                    // We need to advance pos to char_pos + 1.
                    
                    // Let's verify strict subsets:
                    // String ( " \ \n \r ) vs Normal ( ... " \ \n \r ) -> String is subset.
                    // Comment ( \n \r ) vs Normal -> Subset.
                    // BlockComment ( * / ) vs Normal ( / ... ) -> * is NOT in Normal mask anymore!
                    // Wait, I removed * from Normal mask.
                    // So Normal -> BlockComment (via / and *) requires * scan.
                    // Normal mask finds /. We handle /. State becomes block_depth=1.
                    // If subsequent bytes have *, Normal mask won't find them!
                    // So Normal -> BlockComment is Narrow -> Wide (effectively, for *)?
                    // Actually Normal mask has / but not *. Block mask has * and /.
                    // So if we find /, we enter block comment mode. We MUST rescan for *.
                    
                    // Conclusion: On ANY state change that affects mask type, we should probably re-eval.
                    // Or simpler: just continue outer loop from char_pos + 1.
                    
                    // However, detecting "state change" efficiently?
                    // We can just check if we are exiting a state?
                    // Or just always advance bit by bit? No, that defeats SIMD.
                    
                    // Conservative approach: If we hit a candidate that *might* change state, abort block scan and restart from next char.
                    // Candidates that change state: " (Normal<->String), / (Normal->Comment), \n (Comment->Normal), * (Block->Normal logic).
                    // Almost all candidates can change state.
                    // So... if we process a candidate, we should probably restart scan?
                    // This means "SIMD find next candidate", process, then "SIMD find next from there".
                    // That is effectively `pos = char_pos + 1; continue;`
                    // But `scanStructuralMask` is 64 bytes aligned?
                    // `scanStructuralMask` takes a slice. It handles < 64 bytes.
                    // So we can do:
                    // pos = char_pos + 1;
                    // continue;
                    
                    // But we want to process 64-byte aligned blocks for speed.
                    // `scanAvailable` loop increments by 64.
                    // If we break, we fall into the "trailing bytes" loop or need logic to realign.
                    
                    // Let's try to just process. If we miss something, it's bad.
                    // If we use the "Union of all masks" always, it's correct but slow.
                    // We want speed.
                    
                    // Let's implement the restart logic. It is robust.
                    // If we find a match:
                    // 1. Handle it.
                    // 2. Advance pos to char_pos + 1.
                    // 3. Continue outer loop (re-calculating mask at new pos).
                    
                    // Performance impact:
                    // If matches are sparse (every 100 bytes), we scan 64, find nothing. Fast.
                    // If matches are dense (every 5 bytes), we scan 64, find at 5. Handle. Re-scan from 6.
                    // Re-scanning unaligned from 6 might be slightly slower than aligned?
                    // But correctness is paramount.
                    
                    // Wait, `scanStructuralMask` handles unaligned fine.
                    // So "restart loop" is the way to go for correctness with mode switching.
                    
                    bits = 0; // Clear bits to break inner loop
                    pos = char_pos + 1; // Advance
                    // We need to 'continue' the outer loop, but we are inside `while(bits!=0)`.
                    // And we modified `pos`.
                    // We need to jump to start of outer loop.
                }
                
                // If we finished bits without restarting (e.g. no state change check?),
                // we would normally pos += 64.
                // But with the restart logic, we only reach here if mask was 0.
                if (mask == 0) {
                    pos += 64;
                }
            } else {
                pos += 64;
            }
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
