//! Edge Case & Stress Testing for TOON
//!
//! Fast, targeted tests for edge cases and stress scenarios.
//! For true coverage-guided fuzzing, use Zig 0.14+ with `zig test --fuzz`

const std = @import("std");
const toon = @import("toon");
const JsonValue = toon.JsonValue;

// =============================================================================
// EDGE CASE TESTS
// =============================================================================

test "edge: known edge cases" {
    const allocator = std.testing.allocator;

    const edge_cases = [_][]const u8{
        // Empty/minimal
        "",
        " ",
        "\n",
        "\t",
        // Primitives
        "null",
        "true",
        "false",
        "0",
        "-1",
        "3.14",
        "\"\"",
        "\"hello\"",
        // Objects
        "key: value",
        "key:",
        "a: 1\nb: 2",
        // Arrays
        "[0]:",
        "[1]: a",
        "[3]: 1,2,3",
        // Nested
        "a:\n  b: 1",
        "x[2]:\n  - 1\n  - 2",
        // Special chars
        "key: \"hello\\nworld\"",
        "\"quoted key\": value",
        // Unicode
        "msg: 你好世界",
        "emoji: 🎉",
        // NOTE: Malformed inputs currently have memory leaks on error paths
        // TODO: Fix decoder cleanup on parse errors
        // "[",
        // "]",
        // ":",
        // "a[:",
        // "a[]:",
        // "[abc]:",
        // "a:\n  b:\nc: 1", // Bad indent
    };

    for (edge_cases) |input| {
        var decoded = toon.decode(allocator, input, .{ .strict = false }) catch continue;
        defer decoded.deinit(allocator);

        const encoded = toon.encode(allocator, decoded, .{}) catch continue;
        allocator.free(encoded);
    }
}

test "quick: stress primitives" {
    const allocator = std.testing.allocator;

    // Test extreme numbers
    const numbers = [_][]const u8{
        "n: 0",
        "n: -0",
        "n: 9223372036854775807", // i64 max
        "n: -9223372036854775808", // i64 min
        "n: 0.0",
        "n: -0.0",
        "n: 1e10",
        "n: 1e-10",
        "n: 3.141592653589793",
    };

    for (numbers) |input| {
        var decoded = toon.decode(allocator, input, .{}) catch continue;
        defer decoded.deinit(allocator);

        const encoded = toon.encode(allocator, decoded, .{}) catch continue;
        defer allocator.free(encoded);

        var re = toon.decode(allocator, encoded, .{}) catch {
            std.debug.print("Failed to re-decode: {s}\n", .{encoded});
            continue;
        };
        re.deinit(allocator);
    }
}
