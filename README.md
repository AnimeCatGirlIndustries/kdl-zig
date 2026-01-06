# kdl-zig

A robust, idiomatic KDL 2.0.0 parser and serializer for Zig.

## Features

- **KDL 2.0.0 Compliance**: Passes 336/336 official KDL test suite cases (100% spec compliance).
- **Direct Struct Decoding**: Parse KDL directly into Zig structs (similar to `std.json`).
- **Zero-Copy Optimization**: Option to decode strings as slices of the input buffer, minimizing allocations.
- **DOM API**: Parse into a traversable Document Object Model for dynamic inspection.
- **Streaming Events**: SAX-style event iterator (`StreamIterator`) for low memory footprint.
- **Thread-Safe Design**: SoA-based storage for cache-friendly iteration and parallel parsing.
- **Serialization**: Serialize Zig structs or Document nodes back to KDL.

## Installation

Add `kdl-zig` to your `build.zig.zon`:

```bash
zig fetch --save https://github.com/AnimeCatGirlIndustries/kdl-zig/archive/main.tar.gz
```

In `build.zig`:

```zig
const kdl = b.dependency("kdl", .{});
exe.root_module.addImport("kdl", kdl.module("kdl"));
```

## Usage

### 1. Decoding into Structs (Recommended)

The easiest way to use the library is to define a struct that matches your KDL structure and use `kdl.decode`.

```zig
const std = @import("std");
const kdl = @import("kdl");

const Config = struct {
    server: Server,
    database: Database,
};

const Server = struct {
    host: []const u8 = "localhost",
    port: u16 = 8080,
    debug: bool = false,
};

const Database = struct {
    url: []const u8,
    max_connections: i32 = 10,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source =
        \server host="0.0.0.0" port=9000 debug=#true
        \database {
        \    url "postgres://user:pass@db/app"
        \    max_connections 50
        \}
    ;

    var config: Config = .{}; // Initialize with defaults
    
    // Decode directly into the config struct
    // Strings are copied by default (safe ownership).
    try kdl.decode(&config, allocator, source, .{});

    std.debug.print("Server: {s}:{d}\n", .{ config.server.host, config.server.port });
}
```

#### Zero-Copy Decoding

For maximum performance, you can disable string copying. String fields in your struct will point directly to the input source buffer (if unescaped). Note that the input buffer must outlive the struct.

```zig
// Input 'source' must remain valid!
try kdl.decode(&config, allocator, source, .{ .copy_strings = false });
```

### 2. Document DOM API

If you need to manipulate the KDL structure programmatically or handle unknown structures.

```zig
var doc = try kdl.parse(allocator, source);
defer doc.deinit();

// Iterate over root nodes
var roots = doc.rootIterator();
while (roots.next()) |handle| {
    const name = doc.getString(doc.nodes.getName(handle));
    std.debug.print("Node: {s}\n", .{name});

    // Get arguments
    const arg_range = doc.nodes.getArgRange(handle);
    const args = doc.values.getArguments(arg_range);
    for (args) |arg| {
        // Inspect TypedValue...
    }

    // Get properties
    const prop_range = doc.nodes.getPropRange(handle);
    const props = doc.values.getProperties(prop_range);
    for (props) |prop| {
        const prop_name = doc.getString(prop.name);
        std.debug.print("  {s}=...\n", .{prop_name});
    }
}
```

### 3. Streaming Events

For processing large files or implementing custom parsing logic without building a DOM.

```zig
var stream = std.io.fixedBufferStream(source);
var iter = try kdl.StreamIterator(@TypeOf(stream).Reader).init(
    allocator,
    stream.reader(),
    4096, // buffer size
);
defer iter.deinit();

while (try iter.next()) |event| {
    switch (event) {
        .start_node => |n| std.debug.print("Start: {s}\n", .{n.name}),
        .end_node => std.debug.print("End\n", .{}),
        .argument => |val| {},
        .property => |prop| {},
    }
}
```

#### Parallel Parsing

For large documents, parse partitions in parallel and merge:

```zig
// Find safe split points at top-level node boundaries
const boundaries = try kdl.findNodeBoundaries(allocator, source, num_threads);
defer allocator.free(boundaries);

// Parse each partition (can be done in parallel threads)
var docs = std.ArrayList(kdl.Document).init(allocator);
// ... parse source[0..boundaries[0]], source[boundaries[0]..boundaries[1]], etc.

// Merge results
var merged = try kdl.mergeDocuments(allocator, docs.items);
defer merged.deinit();

// Or use VirtualDocument for zero-copy iteration across multiple documents
var virtual = kdl.VirtualDocument.init(docs.items);
var iter = virtual.rootIterator();
while (iter.next()) |handle| {
    // Process nodes across all documents without copying
}
```

### 4. Serialization

Serialize a struct back to KDL.

```zig
try kdl.encode(config, writer, .{});
```

Serialize a Document back to KDL.

```zig
var doc = try kdl.parse(allocator, source);
defer doc.deinit();

const output = try kdl.serializeToString(allocator, &doc, .{});
defer allocator.free(output);
```

## Benchmarks

The library is optimized for performance. Use `zig build bench -Doptimize=ReleaseFast` to run benchmarks.

## Testing & Fuzzing

Run all tests (unit + integration):
```bash
zig build test
```

Run only unit tests:
```bash
zig build test-unit
```

Run only integration tests (official KDL spec test suite):
```bash
zig build test-integration
```

Run fuzzer (requires Zig 0.14+):
```bash
zig build fuzz -- --fuzz
```

## API Reference

### Types

- `Document` - A complete KDL document containing top-level nodes (SoA-based storage)
- `NodeHandle` - Handle to a node in Document
- `Value` - A KDL value (string, integer, float, float_raw, boolean, null, inf, nan)
- `TypedValue` - A value with an optional type annotation
- `Property` - A property (key=value pair) on a node
- `StringRef` - Reference to a string in the document's string pool

### Parsing Functions

- `parse(allocator, source)` - Parse source into a Document
- `parseWithOptions(allocator, source, options)` - Parse with custom options
- `decode(&struct, allocator, source, options)` - Decode directly into a Zig struct

### Serialization Functions

- `serializeToString(allocator, &doc, options)` - Serialize a Document to an allocated string
- `serialize(&doc, writer, options)` - Serialize a Document to a writer
- `encode(value, writer, options)` - Encode a Zig struct to KDL

### Streaming Iterator

- `StreamIterator(Reader)` - SAX-style event iterator for streaming parsing
- Events: `start_node`, `end_node`, `argument`, `property`

### Parallel Parsing

- `findNodeBoundaries(allocator, source, max_partitions)` - Find partition points
- `mergeDocuments(allocator, documents)` - Merge multiple Documents into one
- `VirtualDocument` - Zero-copy iteration across multiple Documents

## License

See LICENSE file for details.
