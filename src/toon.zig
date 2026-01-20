
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

pub fn encode(allocator: Allocator, val: JsonValue, options: EncodeOptions) ToonError![]u8 {
    return encoder.encode(allocator, val, options);
}

pub fn decode(allocator: Allocator, input: []const u8, options: DecodeOptions) ToonError!JsonValue {
    return decoder.decode(allocator, input, options);
}

pub fn encodeDefault(allocator: Allocator, val: JsonValue) ToonError![]u8 {
    return encode(allocator, val, .{});
}

pub fn decodeDefault(allocator: Allocator, input: []const u8) ToonError!JsonValue {
    return decode(allocator, input, .{});
}

test {
    std.testing.refAllDecls(@This());
}
