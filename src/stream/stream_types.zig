/// Streaming IR Types for Thread-Safe KDL Parsing
///
/// Uses Structure-of-Arrays (SoA) design with pooled storage for:
/// - Cache-friendly iteration (contiguous memory)
/// - No per-element ownership tracking (pool freed as unit)
/// - Thread partitioning (each thread owns pools, merged at end)
/// - Handle-based linking (indices allow easy cross-thread merging)
const std = @import("std");
const Allocator = std.mem.Allocator;

/// Reference to a string in a StringPool or borrowed from source.
/// Uses u64 for offset/len to support documents larger than 4GB.
/// High bit of offset indicates borrowed (points into source) vs owned (points into pool).
pub const StringRef = struct {
    offset: u64,
    len: u64,

    /// High bit indicates borrowed string (points into source buffer).
    const BORROWED_FLAG: u64 = 0x8000_0000_0000_0000;

    pub const empty: StringRef = .{ .offset = 0, .len = 0 };

    /// Create a borrowed string reference (points into source buffer).
    pub fn borrowed(source_offset: u64, length: u64) StringRef {
        return .{
            .offset = source_offset | BORROWED_FLAG,
            .len = length,
        };
    }

    /// Create an owned string reference (points into string pool).
    pub fn owned(pool_offset: u64, length: u64) StringRef {
        return .{
            .offset = pool_offset,
            .len = length,
        };
    }

    /// Check if this is a borrowed reference.
    pub fn isBorrowed(self: StringRef) bool {
        return (self.offset & BORROWED_FLAG) != 0;
    }

    /// Get the actual offset (without borrowed flag).
    pub fn getOffset(self: StringRef) u64 {
        return self.offset & ~BORROWED_FLAG;
    }

    pub fn eql(self: StringRef, other: StringRef) bool {
        return self.offset == other.offset and self.len == other.len;
    }
};

/// Handle to a node in NodeStorage.
/// Uses u64 index to support large documents.
pub const NodeHandle = enum(u64) {
    _,

    pub fn fromIndex(index: usize) NodeHandle {
        return @enumFromInt(@as(u64, @intCast(index)));
    }

    pub fn toIndex(self: NodeHandle) usize {
        return @intCast(@intFromEnum(self));
    }
};

/// Range into a pool (start index + count).
pub const Range = struct {
    start: u64,
    count: u64,

    pub const empty: Range = .{ .start = 0, .count = 0 };
};

/// Contiguous storage for all strings.
/// Strings are appended and referenced by StringRef.
/// Entire pool freed at once - no per-string deallocation.
pub const StringPool = struct {
    data: std.ArrayListUnmanaged(u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) Allocator.Error!StringPool {
        var pool = StringPool{
            .data = .{},
            .allocator = allocator,
        };
        // Reserve offset 0 with a sentinel byte so empty strings added later
        // have offset > 0 and can be distinguished from StringRef.empty
        try pool.data.append(allocator, 0);
        return pool;
    }

    pub fn deinit(self: *StringPool) void {
        self.data.deinit(self.allocator);
    }

    /// Add a string to the pool, returning a reference to it.
    pub fn add(self: *StringPool, str: []const u8) Allocator.Error!StringRef {
        const offset: u64 = @intCast(self.data.items.len);
        try self.data.appendSlice(self.allocator, str);
        return .{
            .offset = offset,
            .len = @intCast(str.len),
        };
    }

    /// Get the string slice for a reference.
    pub fn get(self: *const StringPool, ref: StringRef) []const u8 {
        if (ref.len == 0) return "";
        return self.data.items[ref.offset..][0..ref.len];
    }

    /// Reserve capacity for expected string data.
    pub fn ensureCapacity(self: *StringPool, additional: usize) Allocator.Error!void {
        try self.data.ensureTotalCapacity(self.allocator, self.data.items.len + additional);
    }

    /// Current size of pool in bytes.
    pub fn size(self: *const StringPool) usize {
        return self.data.items.len;
    }
};

/// Value types supported by the streaming IR.
/// Mirrors the existing Value union but uses StringRef for strings.
/// Float with preserved original text for round-tripping overflow/underflow.
pub const FloatWithOriginal = struct {
    value: f64,
    original: StringRef,
};

pub const StreamValue = union(enum) {
    string: StringRef,
    integer: i128,
    float: FloatWithOriginal, // All floats preserve original text for round-tripping
    boolean: bool,
    null_value: void,
    positive_inf: void,
    negative_inf: void,
    nan_value: void,
};

/// Typed value with optional type annotation.
pub const StreamTypedValue = struct {
    value: StreamValue,
    type_annotation: StringRef = StringRef.empty,
};

/// Property (name=value pair).
pub const StreamProperty = struct {
    name: StringRef,
    value: StreamValue,
    type_annotation: StringRef = StringRef.empty,
};

/// Storage for values (arguments and properties).
pub const ValuePool = struct {
    arguments: std.ArrayListUnmanaged(StreamTypedValue),
    properties: std.ArrayListUnmanaged(StreamProperty),
    allocator: Allocator,

    pub fn init(allocator: Allocator) ValuePool {
        return .{
            .arguments = .{},
            .properties = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ValuePool) void {
        self.arguments.deinit(self.allocator);
        self.properties.deinit(self.allocator);
    }

    /// Add an argument, returning its index.
    pub fn addArgument(self: *ValuePool, arg: StreamTypedValue) Allocator.Error!u64 {
        const index: u64 = @intCast(self.arguments.items.len);
        try self.arguments.append(self.allocator, arg);
        return index;
    }

    /// Add a property, returning its index.
    pub fn addProperty(self: *ValuePool, prop: StreamProperty) Allocator.Error!u64 {
        const index: u64 = @intCast(self.properties.items.len);
        try self.properties.append(self.allocator, prop);
        return index;
    }

    /// Get arguments for a range.
    pub fn getArguments(self: *const ValuePool, range: Range) []const StreamTypedValue {
        if (range.count == 0) return &.{};
        return self.arguments.items[range.start..][0..range.count];
    }

    /// Get properties for a range.
    pub fn getProperties(self: *const ValuePool, range: Range) []const StreamProperty {
        if (range.count == 0) return &.{};
        return self.properties.items[range.start..][0..range.count];
    }
};

/// SoA storage for nodes.
/// Each array is parallel - index i in all arrays refers to same node.
pub const NodeStorage = struct {
    /// Node names (StringRef into StringPool)
    names: std.ArrayListUnmanaged(StringRef),
    /// Type annotations (StringRef.empty if none)
    type_annotations: std.ArrayListUnmanaged(StringRef),
    /// Parent node (null for top-level)
    parents: std.ArrayListUnmanaged(?NodeHandle),
    /// First child node (null if no children)
    first_child: std.ArrayListUnmanaged(?NodeHandle),
    /// Next sibling node (null if last)
    next_sibling: std.ArrayListUnmanaged(?NodeHandle),
    /// Range into ValuePool.arguments
    arg_ranges: std.ArrayListUnmanaged(Range),
    /// Range into ValuePool.properties
    prop_ranges: std.ArrayListUnmanaged(Range),

    allocator: Allocator,

    pub fn init(allocator: Allocator) NodeStorage {
        return .{
            .names = .{},
            .type_annotations = .{},
            .parents = .{},
            .first_child = .{},
            .next_sibling = .{},
            .arg_ranges = .{},
            .prop_ranges = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *NodeStorage) void {
        self.names.deinit(self.allocator);
        self.type_annotations.deinit(self.allocator);
        self.parents.deinit(self.allocator);
        self.first_child.deinit(self.allocator);
        self.next_sibling.deinit(self.allocator);
        self.arg_ranges.deinit(self.allocator);
        self.prop_ranges.deinit(self.allocator);
    }

    /// Add a new node, returning its handle.
    pub fn addNode(
        self: *NodeStorage,
        name: StringRef,
        type_annotation: StringRef,
        parent: ?NodeHandle,
        arg_range: Range,
        prop_range: Range,
    ) Allocator.Error!NodeHandle {
        const index = self.names.items.len;
        try self.names.append(self.allocator, name);
        try self.type_annotations.append(self.allocator, type_annotation);
        try self.parents.append(self.allocator, parent);
        try self.first_child.append(self.allocator, null);
        try self.next_sibling.append(self.allocator, null);
        try self.arg_ranges.append(self.allocator, arg_range);
        try self.prop_ranges.append(self.allocator, prop_range);
        return NodeHandle.fromIndex(index);
    }

    /// Link a child to a parent node.
    pub fn linkChild(self: *NodeStorage, parent: NodeHandle, child: NodeHandle) void {
        const parent_idx = parent.toIndex();
        const child_idx = child.toIndex();

        // Update child's parent
        self.parents.items[child_idx] = parent;

        // Find the last child of parent and link
        if (self.first_child.items[parent_idx]) |first| {
            // Find last sibling
            var current = first;
            while (self.next_sibling.items[current.toIndex()]) |next| {
                current = next;
            }
            self.next_sibling.items[current.toIndex()] = child;
        } else {
            // First child
            self.first_child.items[parent_idx] = child;
        }
    }

    /// Get node count.
    pub fn count(self: *const NodeStorage) usize {
        return self.names.items.len;
    }

    /// Get name for a node.
    pub fn getName(self: *const NodeStorage, handle: NodeHandle) StringRef {
        return self.names.items[handle.toIndex()];
    }

    /// Get type annotation for a node.
    pub fn getTypeAnnotation(self: *const NodeStorage, handle: NodeHandle) StringRef {
        return self.type_annotations.items[handle.toIndex()];
    }

    /// Get parent of a node.
    pub fn getParent(self: *const NodeStorage, handle: NodeHandle) ?NodeHandle {
        return self.parents.items[handle.toIndex()];
    }

    /// Get first child of a node.
    pub fn getFirstChild(self: *const NodeStorage, handle: NodeHandle) ?NodeHandle {
        return self.first_child.items[handle.toIndex()];
    }

    /// Get next sibling of a node.
    pub fn getNextSibling(self: *const NodeStorage, handle: NodeHandle) ?NodeHandle {
        return self.next_sibling.items[handle.toIndex()];
    }

    /// Get argument range for a node.
    pub fn getArgRange(self: *const NodeStorage, handle: NodeHandle) Range {
        return self.arg_ranges.items[handle.toIndex()];
    }

    /// Get property range for a node.
    pub fn getPropRange(self: *const NodeStorage, handle: NodeHandle) Range {
        return self.prop_ranges.items[handle.toIndex()];
    }
};

/// Complete streaming document - owns all pools.
/// Supports both owned strings (in pool) and borrowed strings (in source).
pub const StreamDocument = struct {
    strings: StringPool,
    values: ValuePool,
    nodes: NodeStorage,
    /// Top-level nodes (handles into nodes)
    roots: std.ArrayListUnmanaged(NodeHandle),
    allocator: Allocator,
    /// Optional source buffer for borrowed string references.
    /// When set, borrowed StringRefs point into this buffer.
    /// Caller must ensure source outlives the document.
    source: ?[]const u8 = null,

    pub fn init(allocator: Allocator) Allocator.Error!StreamDocument {
        return .{
            .strings = try StringPool.init(allocator),
            .values = ValuePool.init(allocator),
            .nodes = NodeStorage.init(allocator),
            .roots = .{},
            .allocator = allocator,
            .source = null,
        };
    }

    /// Initialize with a source buffer for zero-copy borrowed strings.
    pub fn initWithSource(allocator: Allocator, source: []const u8) Allocator.Error!StreamDocument {
        return .{
            .strings = try StringPool.init(allocator),
            .values = ValuePool.init(allocator),
            .nodes = NodeStorage.init(allocator),
            .roots = .{},
            .allocator = allocator,
            .source = source,
        };
    }

    pub fn deinit(self: *StreamDocument) void {
        self.strings.deinit();
        self.values.deinit();
        self.nodes.deinit();
        self.roots.deinit(self.allocator);
    }

    /// Add a top-level node.
    pub fn addRoot(self: *StreamDocument, handle: NodeHandle) Allocator.Error!void {
        try self.roots.append(self.allocator, handle);
    }

    /// Get string content from a StringRef.
    /// Handles both owned (pool) and borrowed (source) refs.
    ///
    /// IMPORTANT: For borrowed StringRefs, the document must have been initialized
    /// with `initWithSource` and the source buffer must still be valid. If the
    /// source is null but a borrowed ref is passed, this function returns an empty
    /// string in release mode and asserts in debug mode.
    pub fn getString(self: *const StreamDocument, ref: StringRef) []const u8 {
        if (ref.len == 0) return "";
        if (ref.isBorrowed()) {
            // Borrowed: points into source buffer
            const src = self.source orelse {
                // Debug assertion: borrowed refs require source to be set
                std.debug.assert(false);
                return "";
            };
            const offset = ref.getOffset();
            if (offset + ref.len > src.len) {
                // Debug assertion: borrowed ref points outside source bounds
                std.debug.assert(false);
                return "";
            }
            return src[offset..][0..ref.len];
        } else {
            // Owned: points into string pool
            return self.strings.get(ref);
        }
    }

    /// Iterator over top-level nodes.
    pub fn rootIterator(self: *const StreamDocument) RootIterator {
        return .{ .doc = self, .index = 0 };
    }

    pub const RootIterator = struct {
        doc: *const StreamDocument,
        index: usize,

        pub fn next(self: *RootIterator) ?NodeHandle {
            if (self.index >= self.doc.roots.items.len) return null;
            const handle = self.doc.roots.items[self.index];
            self.index += 1;
            return handle;
        }
    };

    /// Iterator over children of a node.
    pub fn childIterator(self: *const StreamDocument, parent: NodeHandle) ChildIterator {
        return .{
            .doc = self,
            .current = self.nodes.getFirstChild(parent),
        };
    }

    pub const ChildIterator = struct {
        doc: *const StreamDocument,
        current: ?NodeHandle,

        pub fn next(self: *ChildIterator) ?NodeHandle {
            const handle = self.current orelse return null;
            self.current = self.doc.nodes.getNextSibling(handle);
            return handle;
        }
    };
};

// ============================================================================
// Tests
// ============================================================================

test "StringRef equality" {
    const ref1 = StringRef{ .offset = 0, .len = 5 };
    const ref2 = StringRef{ .offset = 0, .len = 5 };
    const ref3 = StringRef{ .offset = 1, .len = 5 };

    try std.testing.expect(ref1.eql(ref2));
    try std.testing.expect(!ref1.eql(ref3));
}

test "StringRef borrowed vs owned" {
    const owned_ref = StringRef.owned(100, 10);
    const borrowed_ref = StringRef.borrowed(100, 10);

    try std.testing.expect(!owned_ref.isBorrowed());
    try std.testing.expect(borrowed_ref.isBorrowed());

    try std.testing.expectEqual(@as(u32, 100), owned_ref.getOffset());
    try std.testing.expectEqual(@as(u32, 100), borrowed_ref.getOffset());

    // They should not be equal (different flags)
    try std.testing.expect(!owned_ref.eql(borrowed_ref));
}

test "StreamDocument borrowed strings" {
    const source = "hello world";
    var doc = try StreamDocument.initWithSource(std.testing.allocator, source);
    defer doc.deinit();

    // Create borrowed refs pointing into source
    const hello_ref = StringRef.borrowed(0, 5); // "hello"
    const world_ref = StringRef.borrowed(6, 5); // "world"

    try std.testing.expectEqualStrings("hello", doc.getString(hello_ref));
    try std.testing.expectEqualStrings("world", doc.getString(world_ref));

    // Also add owned string to pool
    const owned_ref = try doc.strings.add("owned");
    try std.testing.expectEqualStrings("owned", doc.getString(owned_ref));
}

test "StreamDocument mixed owned and borrowed" {
    const source = "identifier";
    var doc = try StreamDocument.initWithSource(std.testing.allocator, source);
    defer doc.deinit();

    // Borrowed from source (no escapes)
    const borrowed = StringRef.borrowed(0, 10);
    // Owned in pool (processed with escapes)
    const owned = try doc.strings.add("processed\nvalue");

    try std.testing.expectEqualStrings("identifier", doc.getString(borrowed));
    try std.testing.expectEqualStrings("processed\nvalue", doc.getString(owned));
}

test "StringPool add and get" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref1 = try pool.add("hello");
    const ref2 = try pool.add("world");

    try std.testing.expectEqualStrings("hello", pool.get(ref1));
    try std.testing.expectEqualStrings("world", pool.get(ref2));
}

test "StringPool empty string" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    const ref = try pool.add("");
    try std.testing.expectEqualStrings("", pool.get(ref));
    try std.testing.expectEqualStrings("", pool.get(StringRef.empty));
}

test "StringPool multiple strings contiguous" {
    var pool = try StringPool.init(std.testing.allocator);
    defer pool.deinit();

    _ = try pool.add("abc");
    _ = try pool.add("def");
    _ = try pool.add("ghi");

    // Verify contiguous storage (accounts for 1-byte sentinel at offset 0)
    try std.testing.expectEqual(@as(usize, 10), pool.size());
    try std.testing.expectEqualStrings("abcdefghi", pool.data.items[1..]);
}

test "NodeHandle conversion" {
    const handle = NodeHandle.fromIndex(42);
    try std.testing.expectEqual(@as(usize, 42), handle.toIndex());
}

test "ValuePool add and get arguments" {
    var pool = ValuePool.init(std.testing.allocator);
    defer pool.deinit();

    const idx1 = try pool.addArgument(.{ .value = .{ .integer = 42 } });
    const idx2 = try pool.addArgument(.{ .value = .{ .boolean = true } });

    try std.testing.expectEqual(@as(u32, 0), idx1);
    try std.testing.expectEqual(@as(u32, 1), idx2);

    const range = Range{ .start = 0, .count = 2 };
    const args = pool.getArguments(range);
    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqual(@as(i128, 42), args[0].value.integer);
    try std.testing.expect(args[1].value.boolean);
}

test "ValuePool add and get properties" {
    var pool = ValuePool.init(std.testing.allocator);
    defer pool.deinit();

    const idx = try pool.addProperty(.{
        .name = .{ .offset = 0, .len = 3 },
        .value = .{ .string = .{ .offset = 10, .len = 5 } },
    });

    try std.testing.expectEqual(@as(u32, 0), idx);

    const range = Range{ .start = 0, .count = 1 };
    const props = pool.getProperties(range);
    try std.testing.expectEqual(@as(usize, 1), props.len);
}

test "NodeStorage add node" {
    var storage = NodeStorage.init(std.testing.allocator);
    defer storage.deinit();

    const name = StringRef{ .offset = 0, .len = 4 };
    const handle = try storage.addNode(name, StringRef.empty, null, Range.empty, Range.empty);

    try std.testing.expectEqual(@as(usize, 0), handle.toIndex());
    try std.testing.expectEqual(@as(usize, 1), storage.count());
    try std.testing.expect(storage.getName(handle).eql(name));
}

test "NodeStorage link parent-child" {
    var storage = NodeStorage.init(std.testing.allocator);
    defer storage.deinit();

    const parent = try storage.addNode(.{ .offset = 0, .len = 6 }, StringRef.empty, null, Range.empty, Range.empty);
    const child1 = try storage.addNode(.{ .offset = 6, .len = 6 }, StringRef.empty, null, Range.empty, Range.empty);
    const child2 = try storage.addNode(.{ .offset = 12, .len = 6 }, StringRef.empty, null, Range.empty, Range.empty);

    storage.linkChild(parent, child1);
    storage.linkChild(parent, child2);

    // Verify parent-child relationship
    try std.testing.expectEqual(parent, storage.getParent(child1).?);
    try std.testing.expectEqual(parent, storage.getParent(child2).?);

    // Verify sibling chain
    try std.testing.expectEqual(child1, storage.getFirstChild(parent).?);
    try std.testing.expectEqual(child2, storage.getNextSibling(child1).?);
    try std.testing.expectEqual(@as(?NodeHandle, null), storage.getNextSibling(child2));
}

test "StreamDocument basic usage" {
    var doc = try StreamDocument.init(std.testing.allocator);
    defer doc.deinit();

    // Add strings
    const name_ref = try doc.strings.add("node");
    const arg_ref = try doc.strings.add("value");

    // Add argument
    const arg_idx = try doc.values.addArgument(.{
        .value = .{ .string = arg_ref },
    });

    // Add node
    const node = try doc.nodes.addNode(
        name_ref,
        StringRef.empty,
        null,
        .{ .start = arg_idx, .count = 1 },
        Range.empty,
    );

    try doc.addRoot(node);

    // Verify
    try std.testing.expectEqualStrings("node", doc.getString(doc.nodes.getName(node)));

    const args = doc.values.getArguments(doc.nodes.getArgRange(node));
    try std.testing.expectEqual(@as(usize, 1), args.len);
    try std.testing.expectEqualStrings("value", doc.getString(args[0].value.string));
}

test "StreamDocument iteration" {
    var doc = try StreamDocument.init(std.testing.allocator);
    defer doc.deinit();

    // Add parent with two children
    const parent_name = try doc.strings.add("parent");
    const child1_name = try doc.strings.add("child1");
    const child2_name = try doc.strings.add("child2");

    const parent = try doc.nodes.addNode(parent_name, StringRef.empty, null, Range.empty, Range.empty);
    const child1 = try doc.nodes.addNode(child1_name, StringRef.empty, null, Range.empty, Range.empty);
    const child2 = try doc.nodes.addNode(child2_name, StringRef.empty, null, Range.empty, Range.empty);

    doc.nodes.linkChild(parent, child1);
    doc.nodes.linkChild(parent, child2);
    try doc.addRoot(parent);

    // Test root iterator
    var root_iter = doc.rootIterator();
    try std.testing.expectEqual(parent, root_iter.next().?);
    try std.testing.expectEqual(@as(?NodeHandle, null), root_iter.next());

    // Test child iterator
    var child_iter = doc.childIterator(parent);
    try std.testing.expectEqual(child1, child_iter.next().?);
    try std.testing.expectEqual(child2, child_iter.next().?);
    try std.testing.expectEqual(@as(?NodeHandle, null), child_iter.next());
}
