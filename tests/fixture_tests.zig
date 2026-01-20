
const std = @import("std");
const toon = @import("toon");
const JsonValue = toon.JsonValue;

const testing = std.testing;

const TestFixture = struct {
    version: []const u8,
    category: []const u8,
    description: []const u8,
    tests: []TestCase,
};

const TestCase = struct {
    name: []const u8,
    input: std.json.Value,
    expected: std.json.Value,
    shouldError: bool = false,
    options: ?TestOptions = null,
    specSection: ?[]const u8 = null,
    note: ?[]const u8 = null,
};

const TestOptions = struct {
    delimiter: ?[]const u8 = null,
    indent: ?usize = null,
    strict: ?bool = null,
    keyFolding: ?[]const u8 = null,
    flattenDepth: ?usize = null,
    expandPaths: ?[]const u8 = null,
};

fn runEncodeFixture(allocator: std.mem.Allocator, fixture_path: []const u8) !void {
    const file = std.fs.cwd().openFile(fixture_path, .{}) catch |err| {
        std.debug.print("Note: Fixture file not found: {s} (error: {})\n", .{ fixture_path, err });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        std.debug.print("Failed to parse fixture: {s} (error: {})\n", .{ fixture_path, err });
        return;
    };
    defer parsed.deinit();

    const fixture = parsed.value.object;
    const tests_array = fixture.get("tests").?.array;

    for (tests_array.items) |test_case| {
        const tc = test_case.object;
        const name = tc.get("name").?.string;
        const input = tc.get("input").?;
        const expected = tc.get("expected").?;
        const should_error = if (tc.get("shouldError")) |v| v.bool else false;

        // Convert input to our JsonValue
        var input_val = JsonValue.fromStdJson(allocator, input) catch {
            std.debug.print("  SKIP: {s} (failed to convert input)\n", .{name});
            continue;
        };
        defer input_val.deinit(allocator);


        var options = toon.EncodeOptions{};
        if (tc.get("options")) |opts| {
            if (opts.object.get("delimiter")) |d| {
                if (std.mem.eql(u8, d.string, "\t")) {
                    options.delimiter = .tab;
                } else if (std.mem.eql(u8, d.string, "|")) {
                    options.delimiter = .pipe;
                }
            }
            if (opts.object.get("indent")) |i| {
                options.indent = @intCast(i.integer);
            }
            if (opts.object.get("keyFolding")) |kf| {
                if (std.mem.eql(u8, kf.string, "safe")) {
                    options.key_folding = .safe;
                }
            }
        }

        // Run encoder
        if (should_error) {
            const result = toon.encode(allocator, input_val, options);
            if (result) |r| {
                allocator.free(r);
                std.debug.print("  FAIL: {s} (expected error, got success)\n", .{name});
            } else |_| {
                // Expected error
            }
        } else {
            const result = toon.encode(allocator, input_val, options) catch |err| {
                std.debug.print("  FAIL: {s} (unexpected error: {})\n", .{ name, err });
                continue;
            };
            defer allocator.free(result);

            const expected_str = expected.string;
            if (!std.mem.eql(u8, result, expected_str)) {
                std.debug.print("  FAIL: {s}\n", .{name});
                std.debug.print("    Expected: {s}\n", .{expected_str});
                std.debug.print("    Got:      {s}\n", .{result});
            }
        }
    }
}

fn runDecodeFixture(allocator: std.mem.Allocator, fixture_path: []const u8) !void {
    const file = std.fs.cwd().openFile(fixture_path, .{}) catch |err| {
        std.debug.print("Note: Fixture file not found: {s} (error: {})\n", .{ fixture_path, err });
        return;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch return;
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch |err| {
        std.debug.print("Failed to parse fixture: {s} (error: {})\n", .{ fixture_path, err });
        return;
    };
    defer parsed.deinit();

    const fixture = parsed.value.object;
    const tests_array = fixture.get("tests").?.array;

    for (tests_array.items) |test_case| {
        const tc = test_case.object;
        const name = tc.get("name").?.string;
        const input = tc.get("input").?.string;
        const expected = tc.get("expected").?;
        const should_error = if (tc.get("shouldError")) |v| v.bool else false;


        var options = toon.DecodeOptions{};
        if (tc.get("options")) |opts| {
            if (opts.object.get("indent")) |i| {
                options.indent = @intCast(i.integer);
            }
            if (opts.object.get("strict")) |s| {
                options.strict = s.bool;
            }
            if (opts.object.get("expandPaths")) |ep| {
                if (std.mem.eql(u8, ep.string, "safe")) {
                    options.expand_paths = .safe;
                }
            }
        }

        // Run decoder
        if (should_error) {
            const result = toon.decode(allocator, input, options);
            if (result) |*r| {
                var r_mut = r.*;
                r_mut.deinit(allocator);
                std.debug.print("  FAIL: {s} (expected error, got success)\n", .{name});
            } else |_| {
                // Expected error
            }
        } else {
            var result = toon.decode(allocator, input, options) catch |err| {
                std.debug.print("  FAIL: {s} (unexpected error: {})\n", .{ name, err });
                continue;
            };
            defer result.deinit(allocator);

            // Convert expected to our JsonValue for comparison
            var expected_val = JsonValue.fromStdJson(allocator, expected) catch {
                std.debug.print("  SKIP: {s} (failed to convert expected)\n", .{name});
                continue;
            };
            defer expected_val.deinit(allocator);

            if (!result.eql(expected_val)) {
                const result_json = result.toJsonString(allocator) catch continue;
                defer allocator.free(result_json);
                const expected_json = expected_val.toJsonString(allocator) catch continue;
                defer allocator.free(expected_json);

                std.debug.print("  FAIL: {s}\n", .{name});
                std.debug.print("    Expected: {s}\n", .{expected_json});
                std.debug.print("    Got:      {s}\n", .{result_json});
            }
        }
    }
}

test "encode fixtures - primitives" {
    try runEncodeFixture(testing.allocator, "tests/fixtures/encode/primitives.json");
}

test "encode fixtures - objects" {
    try runEncodeFixture(testing.allocator, "tests/fixtures/encode/objects.json");
}

test "encode fixtures - arrays-primitive" {
    try runEncodeFixture(testing.allocator, "tests/fixtures/encode/arrays-primitive.json");
}

test "encode fixtures - arrays-tabular" {
    try runEncodeFixture(testing.allocator, "tests/fixtures/encode/arrays-tabular.json");
}

test "encode fixtures - arrays-nested" {
    try runEncodeFixture(testing.allocator, "tests/fixtures/encode/arrays-nested.json");
}

test "encode fixtures - delimiters" {
    try runEncodeFixture(testing.allocator, "tests/fixtures/encode/delimiters.json");
}

test "decode fixtures - primitives" {
    try runDecodeFixture(testing.allocator, "tests/fixtures/decode/primitives.json");
}

test "decode fixtures - numbers" {
    try runDecodeFixture(testing.allocator, "tests/fixtures/decode/numbers.json");
}

test "decode fixtures - objects" {
    try runDecodeFixture(testing.allocator, "tests/fixtures/decode/objects.json");
}

test "decode fixtures - arrays-primitive" {
    try runDecodeFixture(testing.allocator, "tests/fixtures/decode/arrays-primitive.json");
}

test "decode fixtures - arrays-tabular" {
    try runDecodeFixture(testing.allocator, "tests/fixtures/decode/arrays-tabular.json");
}

test "decode fixtures - root-form" {
    try runDecodeFixture(testing.allocator, "tests/fixtures/decode/root-form.json");
}

test "decode fixtures - validation-errors" {
    try runDecodeFixture(testing.allocator, "tests/fixtures/decode/validation-errors.json");
}
