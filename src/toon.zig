//! TOON - Token-Oriented Object Notation
//!
//! A Zig implementation of the TOON format specification v3.0.
//! TOON is a compact, human-readable, line-oriented format that encodes the JSON data model
//! with explicit structure and minimal quoting.
//!
//! ## Features
//! - Full spec compliance with TOON v3.0
//! - Encoder: JSON → TOON
//! - Decoder: TOON → JSON
//! - Strict mode validation
//! - Configurable delimiters (comma, tab, pipe)
//! - Key folding and path expansion (v1.5+ features)
//!
//! ## Example
//! ```zig
//! const toon = @import("toon");
//!
//! // Encode
//! var json = try toon.JsonValue.parse(allocator, "{\"users\":[{\"id\":1,\"name\":\"Alice\"}]}");
//! defer json.deinit(allocator);
//! const encoded = try toon.encode(allocator, json, .{});
//! defer allocator.free(encoded);
//!
//! // Decode
//! var decoded = try toon.decode(allocator, "name: Alice\nage: 30", .{});
//! defer decoded.deinit(allocator);
//! ```

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const value = @import("value.zig");
pub const encoder = @import("encoder.zig");
pub const decoder = @import("decoder.zig");
pub const escape = @import("escape.zig");
pub const number = @import("number.zig");

pub const JsonValue = value.JsonValue;
pub const JsonObject = value.JsonObject;
pub const JsonArray = value.JsonArray;

pub const Delimiter = encoder.Delimiter;
pub const EncodeOptions = encoder.EncodeOptions;
pub const DecodeOptions = decoder.DecodeOptions;
pub const KeyFoldingMode = encoder.KeyFoldingMode;
pub const PathExpansionMode = decoder.PathExpansionMode;

pub const ToonError = @import("error.zig").ToonError;

/// Encode a JsonValue to TOON format.
pub fn encode(allocator: Allocator, val: JsonValue, options: EncodeOptions) ToonError![]u8 {
    return encoder.encode(allocator, val, options);
}

/// Decode a TOON string to JsonValue.
pub fn decode(allocator: Allocator, input: []const u8, options: DecodeOptions) ToonError!JsonValue {
    return decoder.decode(allocator, input, options);
}

/// Convenience: encode with default options.
pub fn encodeDefault(allocator: Allocator, val: JsonValue) ToonError![]u8 {
    return encode(allocator, val, .{});
}

/// Convenience: decode with default options.
pub fn decodeDefault(allocator: Allocator, input: []const u8) ToonError!JsonValue {
    return decode(allocator, input, .{});
}

test {
    std.testing.refAllDecls(@This());
}
