/// Virtual Document for Zero-Copy Multi-Chunk Iteration
///
/// Wraps multiple `StreamDocument`s and iterates over them logically
/// without performing a physical merge. This avoids doubling memory
/// usage when combining parallel parsing results.
///
/// ## Usage
/// ```zig
/// // Parse chunks in parallel
/// var chunks = try parseChunksParallel(allocator, source);
///
/// // Create virtual view (no copying)
/// var virtual = VirtualDocument.init(&chunks);
///
/// // Iterate as if it were a single document
/// var iter = virtual.rootIterator();
/// while (iter.next()) |handle| {
///     const name = virtual.getNodeName(handle);
///     // ...
/// }
/// ```
///
/// ## Memory Ownership
/// The `VirtualDocument` does NOT own the underlying chunks.
/// The caller must ensure chunks remain valid for the lifetime of the virtual document.
const std = @import("std");
const stream_types = @import("stream_types.zig");
const StreamDocument = stream_types.StreamDocument;
const StringRef = stream_types.StringRef;
const NodeHandle = stream_types.NodeHandle;
const Range = stream_types.Range;
const StreamValue = stream_types.StreamValue;
const StreamTypedValue = stream_types.StreamTypedValue;
const StreamProperty = stream_types.StreamProperty;

/// Handle to a node in a virtual document.
/// Contains chunk index and local handle within that chunk.
pub const VirtualNodeHandle = struct {
    chunk_index: u32,
    local_handle: NodeHandle,

    pub fn eql(self: VirtualNodeHandle, other: VirtualNodeHandle) bool {
        return self.chunk_index == other.chunk_index and
            @intFromEnum(self.local_handle) == @intFromEnum(other.local_handle);
    }
};

/// Virtual document that wraps multiple StreamDocuments.
/// Provides unified iteration without physical merging.
pub const VirtualDocument = struct {
    chunks: []const StreamDocument,

    pub fn init(chunks: []const StreamDocument) VirtualDocument {
        return .{ .chunks = chunks };
    }

    /// Total number of chunks.
    pub fn chunkCount(self: *const VirtualDocument) usize {
        return self.chunks.len;
    }

    /// Total number of root nodes across all chunks.
    pub fn rootCount(self: *const VirtualDocument) usize {
        var count: usize = 0;
        for (self.chunks) |chunk| {
            count += chunk.roots.items.len;
        }
        return count;
    }

    /// Total number of nodes across all chunks.
    pub fn nodeCount(self: *const VirtualDocument) usize {
        var count: usize = 0;
        for (self.chunks) |chunk| {
            count += chunk.nodes.count();
        }
        return count;
    }

    /// Iterator over all root nodes across all chunks.
    pub fn rootIterator(self: *const VirtualDocument) RootIterator {
        return .{
            .doc = self,
            .chunk_index = 0,
            .root_index = 0,
        };
    }

    pub const RootIterator = struct {
        doc: *const VirtualDocument,
        chunk_index: usize,
        root_index: usize,

        pub fn next(self: *RootIterator) ?VirtualNodeHandle {
            while (self.chunk_index < self.doc.chunks.len) {
                const chunk = &self.doc.chunks[self.chunk_index];
                if (self.root_index < chunk.roots.items.len) {
                    const handle = chunk.roots.items[self.root_index];
                    self.root_index += 1;
                    return VirtualNodeHandle{
                        .chunk_index = @intCast(self.chunk_index),
                        .local_handle = handle,
                    };
                }
                self.chunk_index += 1;
                self.root_index = 0;
            }
            return null;
        }
    };

    /// Iterator over children of a node.
    pub fn childIterator(self: *const VirtualDocument, parent: VirtualNodeHandle) ChildIterator {
        const chunk = &self.chunks[parent.chunk_index];
        return .{
            .doc = self,
            .chunk_index = parent.chunk_index,
            .current = chunk.nodes.getFirstChild(parent.local_handle),
        };
    }

    pub const ChildIterator = struct {
        doc: *const VirtualDocument,
        chunk_index: u32,
        current: ?NodeHandle,

        pub fn next(self: *ChildIterator) ?VirtualNodeHandle {
            const handle = self.current orelse return null;
            const chunk = &self.doc.chunks[self.chunk_index];
            self.current = chunk.nodes.getNextSibling(handle);
            return VirtualNodeHandle{
                .chunk_index = self.chunk_index,
                .local_handle = handle,
            };
        }
    };

    // ==========================================================================
    // Node Accessors
    // ==========================================================================

    /// Get the name of a node.
    pub fn getNodeName(self: *const VirtualDocument, handle: VirtualNodeHandle) []const u8 {
        const chunk = &self.chunks[handle.chunk_index];
        const name_ref = chunk.nodes.getName(handle.local_handle);
        return chunk.getString(name_ref);
    }

    /// Get the name StringRef of a node.
    pub fn getNodeNameRef(self: *const VirtualDocument, handle: VirtualNodeHandle) StringRef {
        const chunk = &self.chunks[handle.chunk_index];
        return chunk.nodes.getName(handle.local_handle);
    }

    /// Get the type annotation of a node (empty string if none).
    pub fn getTypeAnnotation(self: *const VirtualDocument, handle: VirtualNodeHandle) []const u8 {
        const chunk = &self.chunks[handle.chunk_index];
        const type_ref = chunk.nodes.getTypeAnnotation(handle.local_handle);
        return chunk.getString(type_ref);
    }

    /// Get the type annotation StringRef of a node.
    pub fn getTypeAnnotationRef(self: *const VirtualDocument, handle: VirtualNodeHandle) StringRef {
        const chunk = &self.chunks[handle.chunk_index];
        return chunk.nodes.getTypeAnnotation(handle.local_handle);
    }

    /// Get parent of a node.
    pub fn getParent(self: *const VirtualDocument, handle: VirtualNodeHandle) ?VirtualNodeHandle {
        const chunk = &self.chunks[handle.chunk_index];
        const parent = chunk.nodes.getParent(handle.local_handle) orelse return null;
        return VirtualNodeHandle{
            .chunk_index = handle.chunk_index,
            .local_handle = parent,
        };
    }

    /// Check if a node has children.
    pub fn hasChildren(self: *const VirtualDocument, handle: VirtualNodeHandle) bool {
        const chunk = &self.chunks[handle.chunk_index];
        return chunk.nodes.getFirstChild(handle.local_handle) != null;
    }

    // ==========================================================================
    // Value Accessors
    // ==========================================================================

    /// Get arguments for a node.
    pub fn getArguments(self: *const VirtualDocument, handle: VirtualNodeHandle) []const StreamTypedValue {
        const chunk = &self.chunks[handle.chunk_index];
        const range = chunk.nodes.getArgRange(handle.local_handle);
        return chunk.values.getArguments(range);
    }

    /// Get properties for a node.
    pub fn getProperties(self: *const VirtualDocument, handle: VirtualNodeHandle) []const StreamProperty {
        const chunk = &self.chunks[handle.chunk_index];
        const range = chunk.nodes.getPropRange(handle.local_handle);
        return chunk.values.getProperties(range);
    }

    /// Get string content from a StringRef within a specific chunk.
    pub fn getString(self: *const VirtualDocument, handle: VirtualNodeHandle, ref: StringRef) []const u8 {
        const chunk = &self.chunks[handle.chunk_index];
        return chunk.getString(ref);
    }

    /// Get string content from a StreamValue (if it's a string).
    pub fn getStringValue(self: *const VirtualDocument, handle: VirtualNodeHandle, value: StreamValue) ?[]const u8 {
        return switch (value) {
            .string => |ref| self.getString(handle, ref),
            else => null,
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

const Allocator = std.mem.Allocator;
const stream_parser = @import("stream_parser.zig");

fn parseDoc(allocator: Allocator, source: []const u8) !StreamDocument {
    return stream_parser.parse(allocator, source);
}

test "VirtualDocument single chunk" {
    var doc = try parseDoc(std.testing.allocator, "node1\nnode2");
    defer doc.deinit();

    const chunks = [_]StreamDocument{doc};
    const virtual = VirtualDocument.init(&chunks);

    try std.testing.expectEqual(@as(usize, 1), virtual.chunkCount());
    try std.testing.expectEqual(@as(usize, 2), virtual.rootCount());

    var iter = virtual.rootIterator();
    const n1 = iter.next().?;
    try std.testing.expectEqualStrings("node1", virtual.getNodeName(n1));
    const n2 = iter.next().?;
    try std.testing.expectEqualStrings("node2", virtual.getNodeName(n2));
    try std.testing.expectEqual(@as(?VirtualNodeHandle, null), iter.next());
}

test "VirtualDocument multiple chunks" {
    var doc1 = try parseDoc(std.testing.allocator, "chunk1_node1\nchunk1_node2");
    defer doc1.deinit();

    var doc2 = try parseDoc(std.testing.allocator, "chunk2_node1");
    defer doc2.deinit();

    var doc3 = try parseDoc(std.testing.allocator, "chunk3_node1\nchunk3_node2\nchunk3_node3");
    defer doc3.deinit();

    const chunks = [_]StreamDocument{ doc1, doc2, doc3 };
    const virtual = VirtualDocument.init(&chunks);

    try std.testing.expectEqual(@as(usize, 3), virtual.chunkCount());
    try std.testing.expectEqual(@as(usize, 6), virtual.rootCount());

    var names = std.ArrayListUnmanaged([]const u8){};
    defer names.deinit(std.testing.allocator);

    var iter = virtual.rootIterator();
    while (iter.next()) |handle| {
        try names.append(std.testing.allocator, virtual.getNodeName(handle));
    }

    try std.testing.expectEqual(@as(usize, 6), names.items.len);
    try std.testing.expectEqualStrings("chunk1_node1", names.items[0]);
    try std.testing.expectEqualStrings("chunk1_node2", names.items[1]);
    try std.testing.expectEqualStrings("chunk2_node1", names.items[2]);
    try std.testing.expectEqualStrings("chunk3_node1", names.items[3]);
    try std.testing.expectEqualStrings("chunk3_node2", names.items[4]);
    try std.testing.expectEqualStrings("chunk3_node3", names.items[5]);
}

test "VirtualDocument child iteration" {
    var doc = try parseDoc(std.testing.allocator,
        \\parent {
        \\    child1
        \\    child2
        \\}
    );
    defer doc.deinit();

    const chunks = [_]StreamDocument{doc};
    const virtual = VirtualDocument.init(&chunks);

    var roots = virtual.rootIterator();
    const parent = roots.next().?;
    try std.testing.expectEqualStrings("parent", virtual.getNodeName(parent));

    var children = virtual.childIterator(parent);
    const c1 = children.next().?;
    try std.testing.expectEqualStrings("child1", virtual.getNodeName(c1));
    const c2 = children.next().?;
    try std.testing.expectEqualStrings("child2", virtual.getNodeName(c2));
    try std.testing.expectEqual(@as(?VirtualNodeHandle, null), children.next());
}

test "VirtualDocument arguments and properties" {
    var doc = try parseDoc(std.testing.allocator, "node 42 \"hello\" key=\"value\"");
    defer doc.deinit();

    const chunks = [_]StreamDocument{doc};
    const virtual = VirtualDocument.init(&chunks);

    var roots = virtual.rootIterator();
    const node = roots.next().?;

    const args = virtual.getArguments(node);
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqual(@as(i128, 42), args[0].value.integer);
    try std.testing.expectEqualStrings("hello", virtual.getString(node, args[1].value.string));

    const props = virtual.getProperties(node);
    try std.testing.expectEqual(@as(usize, 1), props.len);
    try std.testing.expectEqualStrings("key", virtual.getString(node, props[0].name));
    try std.testing.expectEqualStrings("value", virtual.getString(node, props[0].value.string));
}

test "VirtualDocument type annotations" {
    var doc = try parseDoc(std.testing.allocator, "(mytype)node");
    defer doc.deinit();

    const chunks = [_]StreamDocument{doc};
    const virtual = VirtualDocument.init(&chunks);

    var roots = virtual.rootIterator();
    const node = roots.next().?;

    try std.testing.expectEqualStrings("node", virtual.getNodeName(node));
    try std.testing.expectEqualStrings("mytype", virtual.getTypeAnnotation(node));
}

test "VirtualDocument empty chunks" {
    var doc1 = try parseDoc(std.testing.allocator, "");
    defer doc1.deinit();

    var doc2 = try parseDoc(std.testing.allocator, "node");
    defer doc2.deinit();

    var doc3 = try parseDoc(std.testing.allocator, "");
    defer doc3.deinit();

    const chunks = [_]StreamDocument{ doc1, doc2, doc3 };
    const virtual = VirtualDocument.init(&chunks);

    try std.testing.expectEqual(@as(usize, 3), virtual.chunkCount());
    try std.testing.expectEqual(@as(usize, 1), virtual.rootCount());

    var iter = virtual.rootIterator();
    const node = iter.next().?;
    try std.testing.expectEqualStrings("node", virtual.getNodeName(node));
    try std.testing.expectEqual(@as(?VirtualNodeHandle, null), iter.next());
}

test "VirtualDocument parent access" {
    var doc = try parseDoc(std.testing.allocator,
        \\parent {
        \\    child
        \\}
    );
    defer doc.deinit();

    const chunks = [_]StreamDocument{doc};
    const virtual = VirtualDocument.init(&chunks);

    var roots = virtual.rootIterator();
    const parent = roots.next().?;

    var children = virtual.childIterator(parent);
    const child = children.next().?;

    const child_parent = virtual.getParent(child).?;
    try std.testing.expect(parent.eql(child_parent));

    // Root has no parent
    try std.testing.expectEqual(@as(?VirtualNodeHandle, null), virtual.getParent(parent));
}

test "VirtualDocument hasChildren" {
    var doc = try parseDoc(std.testing.allocator,
        \\parent { child }
        \\leaf
    );
    defer doc.deinit();

    const chunks = [_]StreamDocument{doc};
    const virtual = VirtualDocument.init(&chunks);

    var roots = virtual.rootIterator();
    const parent = roots.next().?;
    const leaf = roots.next().?;

    try std.testing.expect(virtual.hasChildren(parent));
    try std.testing.expect(!virtual.hasChildren(leaf));
}

test "VirtualNodeHandle equality" {
    const h1 = VirtualNodeHandle{ .chunk_index = 0, .local_handle = NodeHandle.fromIndex(5) };
    const h2 = VirtualNodeHandle{ .chunk_index = 0, .local_handle = NodeHandle.fromIndex(5) };
    const h3 = VirtualNodeHandle{ .chunk_index = 1, .local_handle = NodeHandle.fromIndex(5) };
    const h4 = VirtualNodeHandle{ .chunk_index = 0, .local_handle = NodeHandle.fromIndex(6) };

    try std.testing.expect(h1.eql(h2));
    try std.testing.expect(!h1.eql(h3));
    try std.testing.expect(!h1.eql(h4));
}
