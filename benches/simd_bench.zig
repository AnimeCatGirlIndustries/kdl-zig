//! SIMD micro-benchmarks to validate performance gains.

const std = @import("std");
const kdl = @import("kdl");
const simd = kdl.simd;

pub fn main() !void {
    const print = std.debug.print;

    print("SIMD Micro-benchmarks\n", .{});
    print("=====================\n", .{});
    print("Detected ISA: {s}\n", .{@tagName(simd.detected_isa)});
    print("Vector width: {} bytes\n\n", .{simd.vector_width});

    // Create test data with various whitespace patterns
    var short_ws: [64]u8 = undefined;
    @memset(&short_ws, ' ');
    short_ws[4] = 'x'; // 4 spaces then x

    var medium_ws: [256]u8 = undefined;
    @memset(&medium_ws, ' ');
    medium_ws[32] = 'x'; // 32 spaces then x

    var long_ws: [4096]u8 = undefined;
    @memset(&long_ws, ' ');
    long_ws[1024] = 'x'; // 1024 spaces then x

    var very_long_ws: [65536]u8 = undefined;
    @memset(&very_long_ws, ' ');
    very_long_ws[32768] = 'x'; // 32K spaces then x

    // String data - typical KDL strings
    var string_short: [64]u8 = undefined;
    @memset(&string_short, 'a');
    string_short[16] = '"'; // 16 chars then quote

    var string_long: [4096]u8 = undefined;
    @memset(&string_long, 'a');
    string_long[1024] = '"'; // 1024 chars then quote

    const iterations: usize = 1_000_000;

    print("Running {} iterations each...\n\n", .{iterations});

    // Benchmark SIMD whitespace scanning
    {
        var timer = try std.time.Timer.start();

        var result: usize = 0;
        for (0..iterations) |_| {
            result = simd.findWhitespaceLength(&short_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_short = timer.lap();

        for (0..iterations) |_| {
            result = simd.findWhitespaceLength(&medium_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_medium = timer.lap();

        for (0..iterations) |_| {
            result = simd.findWhitespaceLength(&long_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_long = timer.lap();

        for (0..iterations / 10) |_| {
            result = simd.findWhitespaceLength(&very_long_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_very_long = timer.lap();

        print("Whitespace scanning (SIMD: {s}):\n", .{@tagName(simd.detected_isa)});
        print("  4 bytes:    {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_short)) / @as(f64, @floatFromInt(iterations))});
        print("  32 bytes:   {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_medium)) / @as(f64, @floatFromInt(iterations))});
        print("  1024 bytes: {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_long)) / @as(f64, @floatFromInt(iterations))});
        print("  32K bytes:  {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_very_long)) / @as(f64, @floatFromInt(iterations / 10))});
    }

    // Benchmark scalar whitespace scanning for comparison
    {
        var timer = try std.time.Timer.start();

        var result: usize = 0;
        for (0..iterations) |_| {
            result = simd.generic.findWhitespaceLength(&short_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_short = timer.lap();

        for (0..iterations) |_| {
            result = simd.generic.findWhitespaceLength(&medium_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_medium = timer.lap();

        for (0..iterations) |_| {
            result = simd.generic.findWhitespaceLength(&long_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_long = timer.lap();

        for (0..iterations / 10) |_| {
            result = simd.generic.findWhitespaceLength(&very_long_ws);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_very_long = timer.lap();

        print("\nWhitespace scanning (Scalar):\n", .{});
        print("  4 bytes:    {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_short)) / @as(f64, @floatFromInt(iterations))});
        print("  32 bytes:   {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_medium)) / @as(f64, @floatFromInt(iterations))});
        print("  1024 bytes: {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_long)) / @as(f64, @floatFromInt(iterations))});
        print("  32K bytes:  {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_very_long)) / @as(f64, @floatFromInt(iterations / 10))});
    }

    // Benchmark string terminator scanning
    {
        var timer = try std.time.Timer.start();

        var result: usize = 0;
        for (0..iterations) |_| {
            result = simd.findStringTerminator(&string_short);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_short = timer.lap();

        for (0..iterations) |_| {
            result = simd.findStringTerminator(&string_long);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_long = timer.lap();

        print("\nString terminator scanning (SIMD: {s}):\n", .{@tagName(simd.detected_isa)});
        print("  16 bytes:   {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_short)) / @as(f64, @floatFromInt(iterations))});
        print("  1024 bytes: {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_long)) / @as(f64, @floatFromInt(iterations))});
    }

    {
        var timer = try std.time.Timer.start();

        var result: usize = 0;
        for (0..iterations) |_| {
            result = simd.generic.findStringTerminator(&string_short);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_short = timer.lap();

        for (0..iterations) |_| {
            result = simd.generic.findStringTerminator(&string_long);
            std.mem.doNotOptimizeAway(&result);
        }
        const elapsed_long = timer.lap();

        print("\nString terminator scanning (Scalar):\n", .{});
        print("  16 bytes:   {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_short)) / @as(f64, @floatFromInt(iterations))});
        print("  1024 bytes: {d:.2} ns/iter\n", .{@as(f64, @floatFromInt(elapsed_long)) / @as(f64, @floatFromInt(iterations))});
    }

    // Benchmark Structural Scanning (Stage 1)
    {
        const large_kdl = "node (type)key=\"value\" { child prop=123; } \n" ** 100;
        const allocator = std.heap.page_allocator;

        var timer = try std.time.Timer.start();
        for (0..iterations / 100) |_| {
            const index = try simd.structural.scan(allocator, large_kdl, .{});
            index.deinit(allocator);
        }
        const elapsed_simd = timer.lap();

        print("\nStructural scanning (Stage 1, SIMD-assisted):\n", .{});
        print("  {d} bytes: {d:.2} ns/iter ({d:.2} MB/s)\n", .{
            large_kdl.len,
            @as(f64, @floatFromInt(elapsed_simd)) / @as(f64, @floatFromInt(iterations / 100)),
            (@as(f64, @floatFromInt(large_kdl.len)) * @as(f64, @floatFromInt(iterations / 100))) / (@as(f64, @floatFromInt(elapsed_simd)) / 1e9) / 1024 / 1024,
        });
    }

    print("\nDone.\n", .{});
}
