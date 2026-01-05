# kdl-zig

A robust, idiomatic KDL 2.0.0 parser and serializer for Zig.

## Features

- **KDL 2.0.0 Compliance**: Passes all 336 official KDL test suite cases (100% spec compliance).
- **Direct Struct Decoding**: Parse KDL directly into Zig structs (similar to `std.json`).
- **Zero-Copy Optimization**: Option to decode strings as slices of the input buffer, minimizing allocations.
- **DOM API**: Parse into a traversable Document Object Model (`Document`, `Node`) for dynamic inspection.
- **Pull Parser**: SAX-style streaming parser (`PullParser`) for advanced use cases and low memory footprint.
- **Serialization**: Serialize Zig structs or DOM nodes back to KDL.

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
const doc = try kdl.parse(allocator, source);
defer doc.deinit();

for (doc.nodes) |node| {
    std.debug.print("Node: {s}\n", .{node.name});
    for (node.arguments) |arg| {
        // Inspect TypedValue...
    }
    for (node.properties) |prop| {
        // Inspect Property...
    }
}
```

### 3. Pull Parser (Streaming)

For processing large files or implementing custom parsing logic.

```zig
var parser = kdl.PullParser.init(allocator, source);
// Or from a reader (with optional size limit):
// var parser = try kdl.PullParser.initReader(allocator, reader, .{});
// var parser = try kdl.PullParser.initReader(allocator, reader, .{ .max_size = null }); // unlimited
// defer parser.deinit();

while (try parser.next()) |event| {
    switch (event) {
        .start_node => |n| std.debug.print("Start: {s}\n", .{n.name}),
        .end_node => std.debug.print("End\n", .{}),
        .argument => |val| {},
        .property => |prop| {},
    }
}
```

### 4. Serialization

Serialize a struct back to KDL.

```zig
try kdl.encode(config, writer, .{});
```

Serialize a Document AST back to KDL.

```zig
// Create a document manually or modify one
const doc = Document{ .nodes = ..., .allocator = allocator };
try kdl.serialize(doc, writer, .{});
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

- `Document` - A complete KDL document containing top-level nodes
- `Node` - A KDL node with name, arguments, properties, and children
- `Value` - A KDL value (string, integer, float, boolean, null, inf, nan)
- `TypedValue` - A value with an optional type annotation
- `Property` - A property (key=value pair) on a node

### Parsing Functions

- `parse(allocator, source)` - Parse source into a Document AST
- `parseWithOptions(allocator, source, options)` - Parse with custom options
- `decode(&struct, allocator, source, options)` - Decode directly into a Zig struct

### Serialization Functions

- `serialize(document, writer, options)` - Serialize a Document to a writer
- `serializeToString(allocator, document)` - Serialize a Document to an allocated string
- `encode(value, writer, options)` - Encode a Zig struct to KDL

### Streaming

- `PullParser.init(allocator, source)` - Create a pull parser from source
- `PullParser.initReader(allocator, reader, options)` - Create a pull parser from a reader

## License

See LICENSE file for details.
