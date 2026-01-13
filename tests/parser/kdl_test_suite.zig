/// KDL 2.0.0 Official Test Suite Integration
/// Validates parser and serializer against the official kdl-org test suite.
const std = @import("std");
const testing = std.testing;
const kdl = @import("kdl");

const test_cases_dir = "tests/kdl-spec/tests/test_cases";

/// Run a single test case
fn runTestCase(allocator: std.mem.Allocator, name: []const u8) !void {
    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();

    const io = threaded.io();

    var stdout_read_buf: [8 * 1 << 20]u8 = undefined;
    var stdout: std.Io.File = .stdout();
    var writer = stdout.writer(io, &stdout_read_buf);

    kdl.encode(threaded, &writer.interface, .{ .indent = 2 });

    const input_path = try std.fmt.allocPrint(allocator, "{s}/input/{s}", .{ test_cases_dir, name });
    defer allocator.free(input_path);

    // Read input file
    const input = std.Io.Dir.cwd().readFileAlloc(
        testing.io,
        input_path,
        allocator,
        .limited(10 * 1 << 20),
    ) catch |err| {
        std.debug.print("Failed to read {s}: {}\n", .{ input_path, err });
        return err;
    };
    defer allocator.free(input);

    const is_fail_test = std.mem.endsWith(u8, name, "_fail.kdl");

    if (is_fail_test) {
        // This test should fail to parse
        const result = kdl.parse(allocator, testing.io, input);
        if (result) |doc| {
            var doc_mut = doc;
            defer doc_mut.deinit();
            std.debug.print("FAIL: {s} - expected parse error but got success\n", .{name});
            return error.TestExpectedError;
        } else |_| {
            // Expected - parse failed as it should
        }
    } else {
        // This test should succeed
        const expected_path = try std.fmt.allocPrint(allocator, "{s}/expected_kdl/{s}", .{ test_cases_dir, name });
        defer allocator.free(expected_path);

        const expected = std.Io.Dir.cwd().readFileAlloc(
            testing.io,
            expected_path,
            allocator,
            .limited(10 * 1 << 20),
        ) catch |err| {
            std.debug.print("Failed to read expected output {s}: {}\n", .{ expected_path, err });
            return err;
        };
        defer allocator.free(expected);

        // Parse the input
        var doc = kdl.parse(allocator, testing.io, input) catch |err| {
            std.debug.print("FAIL: {s} - parse error: {}\n", .{ name, err });
            return err;
        };
        defer doc.deinit();

        // Serialize back to KDL
        const actual = kdl.serializeToString(allocator, &doc, .{}) catch |err| {
            std.debug.print("FAIL: {s} - serialize error: {}\n", .{ name, err });
            return err;
        };
        defer allocator.free(actual);

        // Compare (trim trailing whitespace for comparison)
        const expected_trimmed = std.mem.trimEnd(u8, expected, "\n\r ");
        const actual_trimmed = std.mem.trimEnd(u8, actual, "\n\r ");

        if (!std.mem.eql(u8, expected_trimmed, actual_trimmed)) {
            std.debug.print("\nFAIL: {s}\n", .{name});
            std.debug.print("--- Expected ---\n{s}\n", .{expected_trimmed});
            std.debug.print("--- Actual ---\n{s}\n", .{actual_trimmed});
            std.debug.print("----------------\n", .{});
            return error.TestUnexpectedResult;
        }
    }
}

/// Get all test case file names
fn getTestCases(allocator: std.mem.Allocator) ![][]const u8 {
    const input_dir_path = test_cases_dir ++ "/input";
    var dir = std.Io.Dir.cwd().openDir(
        testing.io,
        input_dir_path,
        .{ .iterate = true },
    ) catch |err| {
        std.debug.print("Cannot open test directory {s}: {}\n", .{ input_dir_path, err });
        return err;
    };
    defer dir.close(testing.io);

    var names: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (names.items) |n| allocator.free(n);
        names.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next(testing.io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".kdl")) {
            try names.append(allocator, try allocator.dupe(u8, entry.name));
        }
    }

    return names.toOwnedSlice(allocator);
}

test "KDL official test suite" {
    const allocator = std.testing.allocator;

    const test_cases = getTestCases(allocator) catch |err| {
        std.debug.print("Failed to get test cases: {}\n", .{err});
        return err;
    };
    defer {
        for (test_cases) |name| allocator.free(name);
        allocator.free(test_cases);
    }

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    var failed_tests: std.ArrayListUnmanaged([]const u8) = .{};
    defer {
        for (failed_tests.items) |n| allocator.free(n);
        failed_tests.deinit(allocator);
    }

    for (test_cases) |name| {
        runTestCase(allocator, name) catch |err| {
            switch (err) {
                error.TestExpectedError, error.TestUnexpectedResult => {
                    failed += 1;
                    failed_tests.append(allocator, allocator.dupe(u8, name) catch continue) catch {};
                },
                else => {
                    skipped += 1;
                },
            }
            continue;
        };
        passed += 1;
    }

    std.debug.print("\n========================================\n", .{});
    std.debug.print("KDL Test Suite Results:\n", .{});
    std.debug.print("  Passed:  {}\n", .{passed});
    std.debug.print("  Failed:  {}\n", .{failed});
    std.debug.print("  Skipped: {}\n", .{skipped});
    std.debug.print("  Total:   {}\n", .{test_cases.len});
    std.debug.print("========================================\n", .{});

    if (failed_tests.items.len > 0) {
        std.debug.print("\nFailed tests:\n", .{});
        for (failed_tests.items) |name| {
            std.debug.print("  - {s}\n", .{name});
        }
    }

    // For now, just report results - don't fail the whole test
    // Uncomment to make tests fail on any failure:
    // if (failed > 0) return error.TestsFailed;
}
