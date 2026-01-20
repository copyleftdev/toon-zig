//! Canonical number formatting per TOON §2.
//!
//! Encoders MUST emit numbers in canonical decimal form:
//! - No exponent notation (1e6 → 1000000)
//! - No leading zeros (except single 0)
//! - No trailing zeros in fractional part
//! - Integer representation when fractional part is zero (1.0 → 1)
//! - -0 normalized to 0

const std = @import("std");
const Allocator = std.mem.Allocator;
const ToonError = @import("error.zig").ToonError;

/// Format an integer in canonical form.
pub fn formatInteger(allocator: Allocator, value: i64) ToonError![]u8 {
    var buf: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ToonError.Overflow;
    return allocator.dupe(u8, slice) catch return ToonError.OutOfMemory;
}

/// Format a float in canonical form per TOON §2.
/// - No exponent notation
/// - No trailing zeros in fractional part
/// - Integer format if fractional part is zero
/// - -0 → 0
pub fn formatFloat(allocator: Allocator, value: f64) ToonError![]u8 {
    // Handle special cases
    if (std.math.isNan(value) or std.math.isInf(value)) {
        return allocator.dupe(u8, "null") catch return ToonError.OutOfMemory;
    }

    // Handle -0
    if (value == 0 and std.math.signbit(value)) {
        return allocator.dupe(u8, "0") catch return ToonError.OutOfMemory;
    }

    // Check if it's effectively an integer
    const rounded = @round(value);
    if (value == rounded and @abs(value) < 9007199254740992.0) { // 2^53, safe integer range
        const int_val: i64 = @intFromFloat(rounded);
        return formatInteger(allocator, int_val);
    }

    // Format as decimal without exponent
    var buf: [350]u8 = undefined; // Enough for extreme values
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ToonError.Overflow;

    // Check if std.fmt used exponent notation
    if (std.mem.indexOfAny(u8, slice, "eE")) |_| {
        // Need to convert from exponent form to decimal
        return expandExponent(allocator, slice);
    }

    // Remove trailing zeros after decimal point
    const result = trimTrailingZeros(allocator, slice) catch return ToonError.OutOfMemory;
    return result;
}

/// Expand exponent notation to decimal form.
fn expandExponent(allocator: Allocator, input: []const u8) ToonError![]u8 {
    // Parse the exponent form
    var neg_mantissa = false;
    var mantissa_start: usize = 0;

    if (input[0] == '-') {
        neg_mantissa = true;
        mantissa_start = 1;
    }

    // Find 'e' or 'E'
    const e_pos = std.mem.indexOfAny(u8, input, "eE") orelse return ToonError.InvalidNumber;

    const mantissa_part = input[mantissa_start..e_pos];

    // Parse exponent
    var exp_start = e_pos + 1;
    var neg_exp = false;
    if (input[exp_start] == '-') {
        neg_exp = true;
        exp_start += 1;
    } else if (input[exp_start] == '+') {
        exp_start += 1;
    }

    const exp_val = std.fmt.parseInt(i32, input[exp_start..], 10) catch return ToonError.InvalidNumber;
    const exponent: i32 = if (neg_exp) -exp_val else exp_val;

    // Find decimal point in mantissa
    const dec_pos = std.mem.indexOf(u8, mantissa_part, ".") orelse mantissa_part.len;

    // Extract digits (without decimal point)
    var digits = std.ArrayList(u8).init(allocator);
    defer digits.deinit();

    for (mantissa_part) |c| {
        if (c != '.') {
            digits.append(c) catch return ToonError.OutOfMemory;
        }
    }

    // Calculate new decimal position
    const current_dec_pos: i32 = @intCast(dec_pos);
    const new_dec_pos = current_dec_pos + exponent;

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    if (neg_mantissa) {
        result.append('-') catch return ToonError.OutOfMemory;
    }

    const digit_count: i32 = @intCast(digits.items.len);

    if (new_dec_pos <= 0) {
        // Need leading zeros: 0.000...
        result.append('0') catch return ToonError.OutOfMemory;
        result.append('.') catch return ToonError.OutOfMemory;
        const zeros_needed: usize = @intCast(-new_dec_pos);
        for (0..zeros_needed) |_| {
            result.append('0') catch return ToonError.OutOfMemory;
        }
        result.appendSlice(digits.items) catch return ToonError.OutOfMemory;
    } else if (new_dec_pos >= digit_count) {
        // Need trailing zeros
        result.appendSlice(digits.items) catch return ToonError.OutOfMemory;
        const zeros_needed: usize = @intCast(new_dec_pos - digit_count);
        for (0..zeros_needed) |_| {
            result.append('0') catch return ToonError.OutOfMemory;
        }
    } else {
        // Decimal point in the middle
        const dec_idx: usize = @intCast(new_dec_pos);
        result.appendSlice(digits.items[0..dec_idx]) catch return ToonError.OutOfMemory;
        result.append('.') catch return ToonError.OutOfMemory;
        result.appendSlice(digits.items[dec_idx..]) catch return ToonError.OutOfMemory;
    }

    // Trim trailing zeros after decimal point
    const slice = result.toOwnedSlice() catch return ToonError.OutOfMemory;
    defer allocator.free(slice);
    return trimTrailingZeros(allocator, slice);
}

/// Remove trailing zeros after decimal point.
/// Also removes decimal point if no fractional part remains.
fn trimTrailingZeros(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    const dec_pos = std.mem.indexOf(u8, input, ".") orelse return allocator.dupe(u8, input);

    var end = input.len;
    while (end > dec_pos + 1 and input[end - 1] == '0') {
        end -= 1;
    }

    // Remove decimal point if no fractional digits remain
    if (end == dec_pos + 1) {
        end = dec_pos;
    }

    return allocator.dupe(u8, input[0..end]);
}

/// Parse a number token per TOON §4.
/// Returns null if not a valid number.
pub fn parseNumber(input: []const u8) ?NumberValue {
    if (input.len == 0) return null;

    var i: usize = 0;
    var negative = false;

    // Optional leading minus
    if (input[i] == '-') {
        negative = true;
        i += 1;
        if (i >= input.len) return null;
    }

    // Check for forbidden leading zeros
    if (input[i] == '0' and i + 1 < input.len) {
        const next = input[i + 1];
        // 0 followed by digit is forbidden (e.g., "05", "007")
        // 0 followed by . or e/E is allowed (e.g., "0.5", "0e1")
        if (next >= '0' and next <= '9') {
            return null; // Forbidden leading zero
        }
    }

    // Parse integer part
    var has_digits = false;
    while (i < input.len and input[i] >= '0' and input[i] <= '9') {
        has_digits = true;
        i += 1;
    }

    if (!has_digits) return null;

    var is_float = false;

    // Optional fractional part
    if (i < input.len and input[i] == '.') {
        is_float = true;
        i += 1;
        var frac_digits = false;
        while (i < input.len and input[i] >= '0' and input[i] <= '9') {
            frac_digits = true;
            i += 1;
        }
        if (!frac_digits) return null; // Must have at least one digit after .
    }

    // Optional exponent
    if (i < input.len and (input[i] == 'e' or input[i] == 'E')) {
        is_float = true;
        i += 1;
        if (i < input.len and (input[i] == '+' or input[i] == '-')) {
            i += 1;
        }
        var exp_digits = false;
        while (i < input.len and input[i] >= '0' and input[i] <= '9') {
            exp_digits = true;
            i += 1;
        }
        if (!exp_digits) return null;
    }

    // Must have consumed entire input
    if (i != input.len) return null;

    // Parse the value
    if (is_float) {
        const f = std.fmt.parseFloat(f64, input) catch return null;
        if (!std.math.isFinite(f)) return null;
        // Normalize -0 to 0
        if (f == 0 and negative) {
            return .{ .float = 0 };
        }
        return .{ .float = f };
    } else {
        const int_val = std.fmt.parseInt(i64, input, 10) catch {
            // Overflow - try as float
            const f = std.fmt.parseFloat(f64, input) catch return null;
            if (!std.math.isFinite(f)) return null;
            return .{ .float = f };
        };
        // Normalize -0 to 0
        if (int_val == 0 and negative) {
            return .{ .integer = 0 };
        }
        return .{ .integer = int_val };
    }
}

/// Result of parsing a number.
pub const NumberValue = union(enum) {
    integer: i64,
    float: f64,
};

/// Check if a string looks like a number (for quoting decisions).
pub fn looksLikeNumber(input: []const u8) bool {
    if (input.len == 0) return false;

    // Check standard numeric pattern
    if (parseNumber(input) != null) return true;

    // Also check leading-zero patterns that must be quoted
    if (input.len >= 2 and input[0] == '0' and input[1] >= '0' and input[1] <= '9') {
        return true; // "05", "007", etc.
    }
    if (input.len >= 3 and input[0] == '-' and input[1] == '0' and input[2] >= '0' and input[2] <= '9') {
        return true; // "-05", etc.
    }

    return false;
}

test "formatInteger" {
    const allocator = std.testing.allocator;

    const zero = try formatInteger(allocator, 0);
    defer allocator.free(zero);
    try std.testing.expectEqualStrings("0", zero);

    const pos = try formatInteger(allocator, 42);
    defer allocator.free(pos);
    try std.testing.expectEqualStrings("42", pos);

    const neg = try formatInteger(allocator, -123);
    defer allocator.free(neg);
    try std.testing.expectEqualStrings("-123", neg);
}

test "formatFloat" {
    const allocator = std.testing.allocator;

    // Integer-like floats
    const whole = try formatFloat(allocator, 1.0);
    defer allocator.free(whole);
    try std.testing.expectEqualStrings("1", whole);

    // Negative zero
    const neg_zero = try formatFloat(allocator, -0.0);
    defer allocator.free(neg_zero);
    try std.testing.expectEqualStrings("0", neg_zero);

    // Simple decimal
    const dec = try formatFloat(allocator, 3.14);
    defer allocator.free(dec);
    try std.testing.expect(std.mem.startsWith(u8, dec, "3.14"));

    // NaN/Infinity → null
    const nan = try formatFloat(allocator, std.math.nan(f64));
    defer allocator.free(nan);
    try std.testing.expectEqualStrings("null", nan);

    const inf = try formatFloat(allocator, std.math.inf(f64));
    defer allocator.free(inf);
    try std.testing.expectEqualStrings("null", inf);
}

test "parseNumber" {
    // Valid integers
    try std.testing.expectEqual(@as(i64, 42), parseNumber("42").?.integer);
    try std.testing.expectEqual(@as(i64, -123), parseNumber("-123").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parseNumber("0").?.integer);

    // Valid floats
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), parseNumber("3.14").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), parseNumber("-0.5").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), parseNumber("1e3").?.float, 0.001);

    // Forbidden leading zeros → treated as string (returns null)
    try std.testing.expect(parseNumber("05") == null);
    try std.testing.expect(parseNumber("007") == null);
    try std.testing.expect(parseNumber("-05") == null);

    // Valid leading zero cases
    try std.testing.expect(parseNumber("0.5") != null);
    try std.testing.expect(parseNumber("0e1") != null);

    // Invalid
    try std.testing.expect(parseNumber("") == null);
    try std.testing.expect(parseNumber("abc") == null);
    try std.testing.expect(parseNumber("1.") == null);
    try std.testing.expect(parseNumber(".5") == null);
}

test "looksLikeNumber" {
    try std.testing.expect(looksLikeNumber("42"));
    try std.testing.expect(looksLikeNumber("-3.14"));
    try std.testing.expect(looksLikeNumber("1e-6"));
    try std.testing.expect(looksLikeNumber("05")); // Must be quoted
    try std.testing.expect(looksLikeNumber("-007")); // Must be quoted
    try std.testing.expect(!looksLikeNumber("hello"));
    try std.testing.expect(!looksLikeNumber(""));
}
