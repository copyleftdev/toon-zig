//! Round-trip tests for TOON encoder/decoder.
//!
//! These tests verify that encode(decode(x)) == x and decode(encode(x)) == x.

const std = @import("std");
const toon = @import("toon");
const JsonValue = toon.JsonValue;

const testing = std.testing;

fn expectRoundTrip(allocator: std.mem.Allocator, input_json: []const u8) !void {
    // Parse JSON input
    var original = try JsonValue.parseJson(allocator, input_json);
    defer original.deinit(allocator);

    // Encode to TOON
    const encoded = try toon.encode(allocator, original, .{});
    defer allocator.free(encoded);

    // Decode back
    var decoded = try toon.decode(allocator, encoded, .{});
    defer decoded.deinit(allocator);

    // Compare
    if (!original.eql(decoded)) {
        const orig_str = try original.toJsonString(allocator);
        defer allocator.free(orig_str);
        const dec_str = try decoded.toJsonString(allocator);
        defer allocator.free(dec_str);

        std.debug.print("Round-trip failed!\n", .{});
        std.debug.print("  Original: {s}\n", .{orig_str});
        std.debug.print("  TOON:     {s}\n", .{encoded});
        std.debug.print("  Decoded:  {s}\n", .{dec_str});
        return error.RoundTripFailed;
    }
}

test "round-trip: simple object" {
    try expectRoundTrip(testing.allocator,
        \\{"name":"Alice","age":30,"active":true}
    );
}

test "round-trip: nested object" {
    try expectRoundTrip(testing.allocator,
        \\{"user":{"id":123,"profile":{"name":"Ada"}}}
    );
}

test "round-trip: primitive array" {
    try expectRoundTrip(testing.allocator,
        \\{"tags":["admin","ops","dev"]}
    );
}

test "round-trip: integer array" {
    try expectRoundTrip(testing.allocator,
        \\{"numbers":[1,2,3,4,5]}
    );
}

test "round-trip: empty object" {
    try expectRoundTrip(testing.allocator, "{}");
}

test "round-trip: empty array" {
    try expectRoundTrip(testing.allocator,
        \\{"items":[]}
    );
}

test "round-trip: mixed primitives" {
    try expectRoundTrip(testing.allocator,
        \\{"string":"hello","number":42,"float":3.14,"bool":true,"null":null}
    );
}

test "round-trip: unicode content" {
    try expectRoundTrip(testing.allocator,
        \\{"message":"Hello 世界 🎉"}
    );
}

test "round-trip: tabular array" {
    try expectRoundTrip(testing.allocator,
        \\{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}
    );
}

test "round-trip: array of arrays" {
    try expectRoundTrip(testing.allocator,
        \\{"matrix":[[1,2,3],[4,5,6]]}
    );
}

test "decode then encode: simple object" {
    const allocator = testing.allocator;
    const toon_input = "name: Alice\nage: 30";

    var decoded = try toon.decode(allocator, toon_input, .{});
    defer decoded.deinit(allocator);

    const re_encoded = try toon.encode(allocator, decoded, .{});
    defer allocator.free(re_encoded);

    try testing.expectEqualStrings(toon_input, re_encoded);
}

test "decode then encode: inline array" {
    const allocator = testing.allocator;
    const toon_input = "[3]: 1,2,3";

    var decoded = try toon.decode(allocator, toon_input, .{});
    defer decoded.deinit(allocator);

    const re_encoded = try toon.encode(allocator, decoded, .{});
    defer allocator.free(re_encoded);

    try testing.expectEqualStrings(toon_input, re_encoded);
}
