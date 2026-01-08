const std = @import("std");
const kdl = @import("kdl");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("Generating synthetic dataset...\n", .{});
    const input = try generateSyntheticDataset(allocator, 500_000); // ~500k nodes
    defer allocator.free(input);
    std.debug.print("Dataset size: {d:.2} MB\n", .{@as(f64, @floatFromInt(input.len)) / 1024.0 / 1024.0});

    // 1. Single-threaded DOM Parse
    {
        var timer = try std.time.Timer.start();
        var doc = try kdl.parse(allocator, input);
        const ns = timer.read();
        defer doc.deinit();
        printBench("DOM Parse (Single)", input.len, ns);
    }

    // 1b. Single-threaded DOM Parse (Structural Index)
    {
        var timer = try std.time.Timer.start();
        var doc = try kdl.parseWithOptions(allocator, input, .{ .strategy = .structural_index });
        const ns = timer.read();
        defer doc.deinit();
        printBench("DOM Parse (Structural Index)", input.len, ns);
    }

    // 1c. Single-threaded DOM Parse (Preprocessed - simdjson-style)
    {
        var timer = try std.time.Timer.start();
        var doc = try kdl.parseWithOptions(allocator, input, .{ .strategy = .preprocessed });
        const ns = timer.read();
        defer doc.deinit();
        printBench("DOM Parse (Preprocessed)", input.len, ns);
    }

    // 1d. Parallel Preprocessed (simdjson-style + multi-threaded)
    {
        var timer = try std.time.Timer.start();
        const docs = try kdl.preprocessParallelToDocs(allocator, input, 4);
        const vdoc = kdl.VirtualDocument.init(docs);
        
        // Iterate to prove access
        var iter = vdoc.rootIterator();
        var count: usize = 0;
        while (iter.next()) |_| {
            count += 1;
        }
        
        const ns = timer.read();
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }
        printBench("DOM Parse (Parallel Preprocessed)", input.len, ns);
    }

    // 2. StreamIterator (SAX) - No DOM
    {
        var timer = try std.time.Timer.start();
        var reader = std.Io.Reader.fixed(input);
        var iter = try kdl.StreamIterator.init(allocator, &reader);
        defer iter.deinit();

        var count: usize = 0;
        while (try iter.next()) |_| {
            count += 1;
        }
        const ns = timer.read();
        printBench("StreamIterator (No DOM)", input.len, ns);
    }

    // 3. Parallel Parse (Physical Merge)
    {
        const num_threads = 4;
        
        // Find boundaries
        const boundaries = try kdl.findNodeBoundaries(allocator, input, num_threads);
        defer allocator.free(boundaries);
        
        var docs = try allocator.alloc(kdl.Document, boundaries.len + 1);
        defer allocator.free(docs);
        
        // Parse chunks serially to time components
        var total_parse_time: u64 = 0;
        
        var start: usize = 0;
        for (0..boundaries.len + 1) |i| {
            const end = if (i < boundaries.len) boundaries[i] else input.len;
            const chunk = input[start..end];
            
            var chunk_timer = try std.time.Timer.start();
            docs[i] = try kdl.parse(allocator, chunk);
            total_parse_time += chunk_timer.read();
            
            start = end;
        }
        
        // Measure Merge Time
        var merge_timer = try std.time.Timer.start();
        var merged = try kdl.mergeDocuments(allocator, docs);
        const merge_ns = merge_timer.read();
        merged.deinit();
        
        // Cleanup chunks
        for (docs) |*d| d.deinit();
        
        const theoretical_total = (total_parse_time / num_threads) + merge_ns;
        
        printBench("Parallel Parse (4 threads, theoretical)", input.len, theoretical_total);
        std.debug.print("  Merge Overhead: {d:.2} ms\n", .{@as(f64, @floatFromInt(merge_ns)) / 1_000_000.0});
    }

    // 4. Parallel Parse (Virtual Merge / Iterator)
    {
        const num_threads = 4;
        // Find boundaries
        const boundaries = try kdl.findNodeBoundaries(allocator, input, num_threads);
        defer allocator.free(boundaries);
        
        var docs = try allocator.alloc(kdl.Document, boundaries.len + 1);
        defer allocator.free(docs);
        
        // Parse chunks
        var total_parse_time: u64 = 0;
        var start: usize = 0;
        for (0..boundaries.len + 1) |i| {
            const end = if (i < boundaries.len) boundaries[i] else input.len;
            const chunk = input[start..end];
            
            var chunk_timer = try std.time.Timer.start();
            docs[i] = try kdl.parse(allocator, chunk);
            total_parse_time += chunk_timer.read();
            start = end;
        }
        
        // Virtual Merge (Zero Copy)
        var merge_timer = try std.time.Timer.start();
        
        var vdoc = kdl.VirtualDocument.init(docs);
        
        // Iterate to prove access
        var iter = vdoc.rootIterator();
        var count: usize = 0;
        while (iter.next()) |_| {
            count += 1;
        }
        
        const virtual_overhead = merge_timer.read();
        
        // Cleanup chunks
        for (docs) |*d| d.deinit();
        
        const theoretical_total = (total_parse_time / num_threads) + virtual_overhead;
        printBench("Virtual Parse (4 threads, theoretical)", input.len, theoretical_total);
        std.debug.print("  Virtual Overhead: {d:.2} ms\n", .{@as(f64, @floatFromInt(virtual_overhead)) / 1_000_000.0});
    }
}

fn generateSyntheticDataset(allocator: std.mem.Allocator, count: usize) ![]u8 {
    var writer = std.Io.Writer.Allocating.init(allocator);
    errdefer writer.deinit();

    var i: usize = 0;
    while (i < count) : (i += 1) {
        try writer.writer.print("node_{d} index={d} active=#true score=1.2345e2 {{ \n", .{i, i});
        try writer.writer.print("    child key=\"value_{d}\"\n", .{i});
        try writer.writer.writeAll("}\n");
    }
    return writer.toOwnedSlice();
}

fn printBench(name: []const u8, bytes: usize, ns: u64) void {
    const ms = @as(f64, @floatFromInt(ns)) / 1_000_000.0;
    const mb = @as(f64, @floatFromInt(bytes)) / 1024.0 / 1024.0;
    const throughput = mb / (ms / 1000.0);
    std.debug.print("{s: <35}: {d: >8.2} ms ({d: >8.2} MB/s)\n", .{name, ms, throughput});
}
