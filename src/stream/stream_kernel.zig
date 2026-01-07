/// Kernel-driven streaming parser using zero-copy string views.
const std = @import("std");
const Allocator = std.mem.Allocator;
const util = @import("util");
const simd = @import("simd");
const constants = util.constants;
const index_parser = simd.index_parser;
const structural = simd.structural;
const stream_events = @import("events");
const stream_types = @import("types");
const value_builder = @import("values");

pub const StringKind = stream_events.StringKind;
pub const StringView = stream_events.StringView;
pub const ValueView = stream_events.ValueView;
pub const Event = stream_events.Event;

pub const ParseOptions = struct {
    /// Maximum nesting depth for nodes.
    max_depth: u16 = constants.DEFAULT_MAX_DEPTH,
    /// Chunk size used by the structural scanner for reader input.
    chunk_size: usize = constants.DEFAULT_BUFFER_SIZE,
    /// Maximum size for streaming scans.
    max_document_size: usize = constants.MAX_POOL_SIZE,
};

pub fn parseWithKernel(allocator: Allocator, source: []const u8, sink: anytype, options: ParseOptions) !void {
    const index = try structural.scan(allocator, source, .{});
    defer index.deinit(allocator);

    var parser = index_parser.IndexParser.initKernel(allocator, source, index, .{
        .max_depth = options.max_depth,
    });
    defer parser.deinit();
    try parser.parseWithSink(sink);
}

pub fn parseReaderWithKernel(allocator: Allocator, reader: anytype, sink: anytype, options: ParseOptions) !void {
    const scan_result = try structural.scanReader(allocator, reader, .{
        .chunk_size = options.chunk_size,
        .max_document_size = options.max_document_size,
    });
    
    // Check if sink can accept ownership of the source
    var source_owned = false;
    const SinkType = @TypeOf(sink);
    const ActualSinkType = switch (@typeInfo(SinkType)) {
        .pointer => |ptr| ptr.child,
        else => SinkType,
    };
    if (@hasDecl(ActualSinkType, "acceptChunkedSource")) {
        // Pass a copy of the struct (slices are shallow copied)
        // sink takes ownership of the underlying memory
        sink.acceptChunkedSource(scan_result.source);
        source_owned = true;
    }

    defer {
        scan_result.index.deinit(allocator);
        if (!source_owned) {
            scan_result.source.deinit(allocator);
        }
    }

    var parser = index_parser.initChunkedKernelParser(allocator, scan_result.source, scan_result.index, .{
        .max_depth = options.max_depth,
    });
    defer parser.deinit();
    try parser.parseWithSink(sink);
}

pub const StreamDocumentKernel = struct {
    allocator: Allocator,
    doc: stream_types.StreamDocument,
    node_stack: std.ArrayListUnmanaged(NodeFrame) = .{},
    child_stack: std.ArrayListUnmanaged(stream_types.NodeHandle) = .{},

    const NodeFrame = struct {
        name: stream_types.StringRef,
        type_annotation: stream_types.StringRef,
        arg_start: u64,
        prop_start: u64,
        child_start: usize,
    };

    pub fn init(allocator: Allocator) !StreamDocumentKernel {
        const doc = try stream_types.StreamDocument.init(allocator);
        return .{
            .allocator = allocator,
            .doc = doc,
        };
    }

    pub fn deinit(self: *StreamDocumentKernel) void {
        self.node_stack.deinit(self.allocator);
        self.child_stack.deinit(self.allocator);
        self.doc.deinit();
    }

    pub fn document(self: *StreamDocumentKernel) *stream_types.StreamDocument {
        return &self.doc;
    }

    pub fn acceptChunkedSource(self: *StreamDocumentKernel, source: stream_types.ChunkedSource) void {
        // If the document already has a chunked source, we should probably deinit the old one?
        // But current usage implies one-shot parse.
        if (self.doc.chunked_source) |cs| {
            cs.deinit(self.allocator);
        }
        self.doc.chunked_source = source;
    }

    pub fn onEvent(self: *StreamDocumentKernel, event: Event) !void {
        switch (event) {
            .start_node => |n| try self.handleStartNode(n),
            .end_node => try self.handleEndNode(),
            .argument => |a| try self.handleArgument(a),
            .property => |p| try self.handleProperty(p),
        }
    }

    fn handleStartNode(self: *StreamDocumentKernel, node: Event.start_node) !void {
        const name = try self.buildStringRef(node.name);
        const type_annot = if (node.type_annotation) |t|
            try self.buildStringRef(t)
        else
            stream_types.StringRef.empty;

        const frame = NodeFrame{
            .name = name,
            .type_annotation = type_annot,
            .arg_start = @intCast(self.doc.values.arguments.items.len),
            .prop_start = @intCast(self.doc.values.properties.items.len),
            .child_start = self.child_stack.items.len,
        };
        try self.node_stack.append(self.allocator, frame);
    }

    fn handleEndNode(self: *StreamDocumentKernel) !void {
        if (self.node_stack.items.len == 0) return index_parser.ParseError.InvalidSyntax;
        const frame = self.node_stack.pop();

        const arg_end: u64 = @intCast(self.doc.values.arguments.items.len);
        const prop_end: u64 = @intCast(self.doc.values.properties.items.len);

        const node = self.doc.nodes.addNode(
            frame.name,
            frame.type_annotation,
            null,
            .{ .start = frame.arg_start, .count = arg_end - frame.arg_start },
            .{ .start = frame.prop_start, .count = prop_end - frame.prop_start },
        ) catch return index_parser.ParseError.OutOfMemory;

        const child_slice = self.child_stack.items[frame.child_start..];
        for (child_slice) |child| {
            self.doc.nodes.linkChild(node, child);
        }
        self.child_stack.items.len = frame.child_start;

        if (self.node_stack.items.len == 0) {
            try self.doc.addRoot(node);
        } else {
            try self.child_stack.append(self.allocator, node);
        }
    }

    fn handleArgument(self: *StreamDocumentKernel, arg: Event.argument) !void {
        if (self.node_stack.items.len == 0) return index_parser.ParseError.InvalidSyntax;
        const type_annot = if (arg.type_annotation) |t|
            try self.buildStringRef(t)
        else
            stream_types.StringRef.empty;

        const value = try self.buildValue(arg.value);
        _ = self.doc.values.addArgument(.{
            .value = value,
            .type_annotation = type_annot,
        }) catch return index_parser.ParseError.OutOfMemory;
    }

    fn handleProperty(self: *StreamDocumentKernel, prop: Event.property) !void {
        if (self.node_stack.items.len == 0) return index_parser.ParseError.InvalidSyntax;
        const name = try self.buildStringRef(prop.name);
        const type_annot = if (prop.type_annotation) |t|
            try self.buildStringRef(t)
        else
            stream_types.StringRef.empty;

        const value = try self.buildValue(prop.value);
        _ = self.doc.values.addProperty(.{
            .name = name,
            .value = value,
            .type_annotation = type_annot,
        }) catch return index_parser.ParseError.OutOfMemory;
    }

    fn buildStringRef(self: *StreamDocumentKernel, view: StringView) !stream_types.StringRef {
        return switch (view.kind) {
            .identifier => value_builder.buildIdentifier(&self.doc.strings, view.text, &self.doc) catch return index_parser.ParseError.OutOfMemory,
            .quoted_string => value_builder.buildQuotedString(&self.doc.strings, view.text, &self.doc) catch |err| return mapStringError(err),
            .raw_string => value_builder.buildRawString(&self.doc.strings, view.text, &self.doc) catch |err| return mapStringError(err),
            .multiline_string => value_builder.buildMultilineString(&self.doc.strings, view.text) catch |err| return mapStringError(err),
        };
    }

    fn buildValue(self: *StreamDocumentKernel, value: ValueView) !stream_types.StreamValue {
        return switch (value) {
            .string => |s| stream_types.StreamValue{ .string = try self.buildStringRef(s) },
            .integer => |i| stream_types.StreamValue{ .integer = i },
            .float => |f| blk: {
                var ref: stream_types.StringRef = undefined;
                if (self.doc.getBorrowedRef(f.original)) |borrowed| {
                    ref = borrowed;
                } else {
                    ref = self.doc.strings.add(f.original) catch return index_parser.ParseError.OutOfMemory;
                }
                break :blk stream_types.StreamValue{ .float = .{ .value = f.value, .original = ref } };
            },
            .boolean => |b| stream_types.StreamValue{ .boolean = b },
            .null_value => stream_types.StreamValue{ .null_value = {} },
            .positive_inf => stream_types.StreamValue{ .positive_inf = {} },
            .negative_inf => stream_types.StreamValue{ .negative_inf = {} },
            .nan_value => stream_types.StreamValue{ .nan_value = {} },
        };
    }

    fn mapStringError(err: value_builder.Error) index_parser.ParseError {
        return switch (err) {
            error.InvalidString => index_parser.ParseError.InvalidString,
            error.InvalidEscape => index_parser.ParseError.InvalidEscape,
            error.OutOfMemory => index_parser.ParseError.OutOfMemory,
        };
    }
};
