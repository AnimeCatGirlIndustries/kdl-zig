/// KDL 2.0.0 Fuzz Testing
/// Property-based testing for parser robustness against arbitrary input.
const std = @import("std");
const kdl = @import("kdl");

const ChunkedSliceReader = struct {
    data: []const u8,
    control: []const u8,
    pos: usize = 0,
    control_pos: usize = 0,
    min_chunk: usize,
    max_chunk: usize,

    pub fn init(data: []const u8, control: []const u8, min_chunk: usize, max_chunk: usize) ChunkedSliceReader {
        const min = if (min_chunk == 0) 1 else min_chunk;
        const max = if (max_chunk < min) min else max_chunk;
        return .{
            .data = data,
            .control = control,
            .min_chunk = min,
            .max_chunk = max,
        };
    }

    fn nextChunkSize(self: *ChunkedSliceReader, request: usize) usize {
        if (request == 0) return 0;
        const capped_max = @min(request, self.max_chunk);
        if (capped_max <= self.min_chunk) return capped_max;
        if (self.control.len == 0) return self.min_chunk;

        const span = capped_max - self.min_chunk + 1;
        const idx = self.control_pos % self.control.len;
        self.control_pos += 1;
        const delta = @as(usize, self.control[idx]) % span;
        return self.min_chunk + delta;
    }

    pub fn read(self: *ChunkedSliceReader, dest: []u8) !usize {
        if (self.pos >= self.data.len) return 0;
        if (dest.len == 0) return 0;

        const chunk = self.nextChunkSize(dest.len);
        const available = self.data.len - self.pos;
        const to_copy = @min(chunk, available);
        std.mem.copyForwards(u8, dest[0..to_copy], self.data[self.pos..][0..to_copy]);
        self.pos += to_copy;
        return to_copy;
    }
};

const ConsumeResult = union(enum) {
    ok: u64,
    err: anyerror,
};

test "fuzz stream iterator" {
    // Note: Fuzzing requires passing --fuzz to zig test
    try std.testing.fuzz({}, fuzzStreamIterator, .{});
}

test "fuzz structural scan chunked" {
    try std.testing.fuzz({}, fuzzStructuralScan, .{});
}

fn fuzzStreamIterator(_: void, input: []const u8) !void {
    const control = input[0..@min(input.len, 16)];
    const max_chunk = deriveChunkMax(control);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var arena_direct = std.heap.ArenaAllocator.init(allocator);
    defer arena_direct.deinit();
    var stream = std.io.fixedBufferStream(input);
    const direct_result = consumeStreamIterator(arena_direct.allocator(), stream.reader());

    var arena_chunked = std.heap.ArenaAllocator.init(allocator);
    defer arena_chunked.deinit();
    var chunked_reader = ChunkedSliceReader.init(input, control, 1, max_chunk);
    const chunked_result = consumeStreamIterator(arena_chunked.allocator(), &chunked_reader);

    try compareConsumeResults(direct_result, chunked_result);
}

fn fuzzStructuralScan(_: void, input: []const u8) !void {
    if (input.len == 0) return;
    const control = input[0..@min(input.len, 16)];
    const max_chunk = deriveChunkMax(control);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const structural = kdl.simd.structural;
    const direct = structural.scan(allocator, input, .{}) catch |err| {
        if (err == error.OutOfMemory) return;
        return;
    };
    defer direct.deinit(allocator);

    var reader = ChunkedSliceReader.init(input, control, 1, max_chunk);
    const scan_result = structural.scanReader(allocator, &reader, .{
        .chunk_size = @max(1, max_chunk),
        .max_document_size = @max(input.len, 1),
    }) catch |err| {
        switch (err) {
            error.OutOfMemory, error.StreamTooLong => return,
            else => return,
        }
    };
    defer scan_result.deinit(allocator);

    var rebuilt = std.ArrayList(u8).empty;
    defer rebuilt.deinit(allocator);
    for (scan_result.source.chunks) |chunk| {
        try rebuilt.appendSlice(allocator, chunk.data[0..chunk.len]);
    }

    try std.testing.expectEqualSlices(u8, input, rebuilt.items);
    try std.testing.expectEqualSlices(u64, direct.slice(), scan_result.index.slice());
}

test "fuzz index parser" {
    try std.testing.fuzz({}, fuzzIndexParser, .{});
}

/// Fuzz test for the IndexParser two-stage parsing path.
/// Compares the index parser output against the streaming parser for consistency.
fn fuzzIndexParser(_: void, input: []const u8) !void {
    if (input.len == 0) return;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse with streaming parser (reference implementation)
    var arena_streaming = std.heap.ArenaAllocator.init(allocator);
    defer arena_streaming.deinit();
    const streaming_result = consumeParser(arena_streaming.allocator(), input, .streaming);

    // Parse with structural index parser
    var arena_index = std.heap.ArenaAllocator.init(allocator);
    defer arena_index.deinit();
    const index_result = consumeParser(arena_index.allocator(), input, .structural_index);

    // Both should produce the same result (either both succeed with same hash, or both fail)
    try compareConsumeResults(streaming_result, index_result);
}

fn consumeParser(allocator: std.mem.Allocator, input: []const u8, strategy: kdl.ParseStrategy) ConsumeResult {
    var stream = std.io.fixedBufferStream(input);
    var doc = kdl.parseReaderWithOptions(allocator, stream.reader(), .{ .strategy = strategy }) catch |err| {
        return .{ .err = err };
    };
    defer doc.deinit();

    // Hash all nodes, arguments, properties to verify content matches
    var hasher = std.hash.Wyhash.init(0);
    hashDocument(&hasher, &doc);
    return .{ .ok = hasher.final() };
}

fn hashDocument(hasher: *std.hash.Wyhash, doc: *const kdl.Document) void {
    var root_iter = doc.rootIterator();
    while (root_iter.next()) |node_handle| {
        hashNode(hasher, doc, node_handle);
    }
}

fn hashNode(hasher: *std.hash.Wyhash, doc: *const kdl.Document, handle: kdl.NodeHandle) void {
    // Hash node name
    hashTag(hasher, 100);
    const name_ref = doc.nodes.getName(handle);
    hashDocStringRef(hasher, doc, name_ref);

    // Hash type annotation if present
    const type_ref = doc.nodes.getTypeAnnotation(handle);
    if (!type_ref.eql(kdl.StringRef.empty)) {
        hashTag(hasher, 101);
        hashDocStringRef(hasher, doc, type_ref);
    }

    // Hash all arguments
    const arg_range = doc.nodes.getArgRange(handle);
    const args = doc.values.getArguments(arg_range);
    for (args) |arg| {
        hashTag(hasher, 102);
        hashDocValue(hasher, doc, arg.value);
        if (!arg.type_annotation.eql(kdl.StringRef.empty)) {
            hashDocStringRef(hasher, doc, arg.type_annotation);
        }
    }

    // Hash all properties
    const prop_range = doc.nodes.getPropRange(handle);
    const props = doc.values.getProperties(prop_range);
    for (props) |prop| {
        hashTag(hasher, 103);
        hashDocStringRef(hasher, doc, prop.name);
        hashDocValue(hasher, doc, prop.value);
        if (!prop.type_annotation.eql(kdl.StringRef.empty)) {
            hashDocStringRef(hasher, doc, prop.type_annotation);
        }
    }

    // Hash children recursively
    var child_iter = doc.childIterator(handle);
    while (child_iter.next()) |child_handle| {
        hashTag(hasher, 104);
        hashNode(hasher, doc, child_handle);
    }
}

fn hashDocValue(hasher: *std.hash.Wyhash, doc: *const kdl.Document, value: kdl.Value) void {
    switch (value) {
        .string => |ref| {
            hashTag(hasher, 110);
            hashDocStringRef(hasher, doc, ref);
        },
        .integer => |val| {
            hashTag(hasher, 111);
            hashBytes(hasher, std.mem.asBytes(&val));
        },
        .float => |val| {
            hashTag(hasher, 112);
            hashBytes(hasher, std.mem.asBytes(&val.value));
            hashDocStringRef(hasher, doc, val.original);
        },
        .boolean => |val| {
            hashTag(hasher, 113);
            const byte: u8 = if (val) 1 else 0;
            hashBytes(hasher, &[_]u8{byte});
        },
        .null_value => hashTag(hasher, 114),
        .positive_inf => hashTag(hasher, 115),
        .negative_inf => hashTag(hasher, 116),
        .nan_value => hashTag(hasher, 117),
    }
}

fn hashDocStringRef(hasher: *std.hash.Wyhash, doc: *const kdl.Document, ref: kdl.StringRef) void {
    const slice = doc.strings.get(ref);
    hashBytes(hasher, slice);
}

fn consumeStreamIterator(allocator: std.mem.Allocator, reader: anytype) ConsumeResult {
    var iter = kdl.StreamIterator(@TypeOf(reader)).init(allocator, reader) catch |err| {
        return .{ .err = err };
    };
    defer iter.deinit();

    var hasher = std.hash.Wyhash.init(0);
    while (true) {
        const event = iter.next() catch |err| {
            return .{ .err = err };
        };
        if (event == null) break;
        hashEvent(&hasher, &iter.strings, event.?);
    }

    return .{ .ok = hasher.final() };
}

fn compareConsumeResults(direct: ConsumeResult, chunked: ConsumeResult) !void {
    switch (direct) {
        .ok => |direct_hash| switch (chunked) {
            .ok => |chunked_hash| try std.testing.expectEqual(direct_hash, chunked_hash),
            .err => |err| {
                if (err == error.OutOfMemory) return;
                try std.testing.expect(false);
            },
        },
        .err => |direct_err| {
            if (direct_err == error.OutOfMemory) return;
            switch (chunked) {
                .ok => try std.testing.expect(false),
                .err => |chunked_err| {
                    if (chunked_err == error.OutOfMemory) return;
                    try std.testing.expectEqual(@intFromError(direct_err), @intFromError(chunked_err));
                },
            }
        },
    }
}

fn hashEvent(hasher: *std.hash.Wyhash, pool: anytype, event: kdl.StreamIteratorEvent) void {
    switch (event) {
        .start_node => |node| {
            hashTag(hasher, 0);
            hashStringRef(hasher, pool, node.name);
            if (node.type_annotation) |annot| {
                hashTag(hasher, 1);
                hashStringRef(hasher, pool, annot);
            } else {
                hashTag(hasher, 0);
            }
        },
        .end_node => hashTag(hasher, 2),
        .argument => |arg| {
            hashTag(hasher, 3);
            hashValue(hasher, pool, arg.value);
            if (arg.type_annotation) |annot| {
                hashTag(hasher, 1);
                hashStringRef(hasher, pool, annot);
            } else {
                hashTag(hasher, 0);
            }
        },
        .property => |prop| {
            hashTag(hasher, 4);
            hashStringRef(hasher, pool, prop.name);
            hashValue(hasher, pool, prop.value);
            if (prop.type_annotation) |annot| {
                hashTag(hasher, 1);
                hashStringRef(hasher, pool, annot);
            } else {
                hashTag(hasher, 0);
            }
        },
    }
}

fn hashValue(hasher: *std.hash.Wyhash, pool: anytype, value: anytype) void {
    switch (value) {
        .string => |ref| {
            hashTag(hasher, 10);
            hashStringRef(hasher, pool, ref);
        },
        .integer => |val| {
            hashTag(hasher, 11);
            hashBytes(hasher, std.mem.asBytes(&val));
        },
        .float => |val| {
            hashTag(hasher, 12);
            hashBytes(hasher, std.mem.asBytes(&val.value));
            hashStringRef(hasher, pool, val.original);
        },
        .boolean => |val| {
            hashTag(hasher, 13);
            const byte: u8 = if (val) 1 else 0;
            hashBytes(hasher, &[_]u8{byte});
        },
        .null_value => hashTag(hasher, 14),
        .positive_inf => hashTag(hasher, 15),
        .negative_inf => hashTag(hasher, 16),
        .nan_value => hashTag(hasher, 17),
    }
}

fn hashStringRef(hasher: *std.hash.Wyhash, pool: anytype, ref: kdl.StringRef) void {
    const slice = pool.get(ref);
    hashBytes(hasher, slice);
}

fn hashBytes(hasher: *std.hash.Wyhash, bytes: []const u8) void {
    const len: u64 = @intCast(bytes.len);
    hasher.update(std.mem.asBytes(&len));
    hasher.update(bytes);
}

fn hashTag(hasher: *std.hash.Wyhash, tag: u8) void {
    hasher.update(&[_]u8{tag});
}

fn deriveChunkMax(control: []const u8) usize {
    if (control.len == 0) return 16;
    return 1 + @as(usize, control[0]);
}
