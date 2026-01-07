//! KDL Node Boundary Detection for Parallel Parsing

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Find boundaries in source for parallel parsing.
/// Returns offsets where top-level nodes begin.
/// Each partition can be parsed independently and merged.
pub fn findNodeBoundaries(allocator: Allocator, source: []const u8, max_partitions: usize) ![]usize {
    if (source.len == 0 or max_partitions <= 1) {
        return &[_]usize{};
    }

    var boundaries = std.ArrayListUnmanaged(usize){};
    defer boundaries.deinit(allocator);

    // Target partition size
    const target_size = source.len / max_partitions;

    var pos: usize = 0;
    var last_boundary: usize = 0;
    var brace_depth: usize = 0;
    var in_string = false;
    var in_raw_string = false;
    var in_line_comment = false;
    var in_block_comment: usize = 0;

    while (pos < source.len) {
        const c = source[pos];

        // Handle line comments
        if (in_line_comment) {
            if (c == '\n') {
                in_line_comment = false;
            }
            pos += 1;
            continue;
        }

        // Handle block comments
        if (in_block_comment > 0) {
            if (pos + 1 < source.len and c == '/' and source[pos + 1] == '*') {
                in_block_comment += 1;
                pos += 2;
                continue;
            }
            if (pos + 1 < source.len and c == '*' and source[pos + 1] == '/') {
                in_block_comment -= 1;
                pos += 2;
                continue;
            }
            pos += 1;
            continue;
        }

        // Handle raw strings
        if (in_raw_string) {
            if (c == '"') {
                in_raw_string = false;
            }
            pos += 1;
            continue;
        }

        // Handle regular strings
        if (in_string) {
            if (c == '\\' and pos + 1 < source.len) {
                pos += 2; // Skip escape sequence
                continue;
            }
            if (c == '"') {
                in_string = false;
            }
            pos += 1;
            continue;
        }

        // Check for comment start
        if (c == '/' and pos + 1 < source.len) {
            const next = source[pos + 1];
            if (next == '/') {
                in_line_comment = true;
                pos += 2;
                continue;
            }
            if (next == '*') {
                in_block_comment = 1;
                pos += 2;
                continue;
            }
        }

        // Check for string start
        if (c == '"') {
            in_string = true;
            pos += 1;
            continue;
        }

        // Check for raw string start
        if (c == '#') {
            var hash_count: usize = 0;
            var scan = pos;
            while (scan < source.len and source[scan] == '#') {
                hash_count += 1;
                scan += 1;
            }
            if (scan < source.len and source[scan] == '"') {
                in_raw_string = true;
                pos = scan + 1;
                continue;
            }
        }

        // Track brace depth
        if (c == '{') {
            brace_depth += 1;
        } else if (c == '}') {
            if (brace_depth > 0) brace_depth -= 1;
        }

        // At top level, check for node boundaries (newlines or semicolons)
        if (brace_depth == 0 and (c == '\n' or c == ';')) {
            const boundary_end = pos + 1;

            // Skip whitespace/newlines after boundary
            var next_start = boundary_end;
            while (next_start < source.len and
                (source[next_start] == ' ' or source[next_start] == '\t' or
                source[next_start] == '\n' or source[next_start] == '\r'))
            {
                next_start += 1;
            }

            // Check if we've passed the target partition size
            if (next_start >= last_boundary + target_size and
                boundaries.items.len < max_partitions - 1 and
                next_start < source.len)
            {
                try boundaries.append(allocator, next_start);
                last_boundary = next_start;
            }
        }

        pos += 1;
    }

    return try boundaries.toOwnedSlice(allocator);
}
