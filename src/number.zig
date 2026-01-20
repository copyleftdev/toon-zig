const std = @import("std");
const Allocator = std.mem.Allocator;
const ToonError = @import("error.zig").ToonError;
pub fn formatInteger(allocator: Allocator, value: i64) ToonError![]u8 {
    var buf: [32]u8 = undefined;
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ToonError.Overflow;
    return allocator.dupe(u8, slice) catch return ToonError.OutOfMemory;
}
pub fn formatFloat(allocator: Allocator, value: f64) ToonError![]u8 {
    if (std.math.isNan(value) or std.math.isInf(value)) {
        return allocator.dupe(u8, "null") catch return ToonError.OutOfMemory;
    }
    if (value == 0 and std.math.signbit(value)) {
        return allocator.dupe(u8, "0") catch return ToonError.OutOfMemory;
    }
    const rounded = @round(value);
    if (value == rounded and @abs(value) < 9007199254740992.0) { // 2^53, safe integer range
        const int_val: i64 = @intFromFloat(rounded);
        return formatInteger(allocator, int_val);
    }
    var buf: [350]u8 = undefined; // Enough for extreme values
    const slice = std.fmt.bufPrint(&buf, "{d}", .{value}) catch return ToonError.Overflow;
    if (std.mem.indexOfAny(u8, slice, "eE")) |_| {
        return expandExponent(allocator, slice);
    }
    const result = trimTrailingZeros(allocator, slice) catch return ToonError.OutOfMemory;
    return result;
}
fn expandExponent(allocator: Allocator, input: []const u8) ToonError![]u8 {
    var neg_mantissa = false;
    var mantissa_start: usize = 0;
    if (input[0] == '-') {
        neg_mantissa = true;
        mantissa_start = 1;
    }
    const e_pos = std.mem.indexOfAny(u8, input, "eE") orelse return ToonError.InvalidNumber;
    const mantissa_part = input[mantissa_start..e_pos];
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
    const dec_pos = std.mem.indexOf(u8, mantissa_part, ".") orelse mantissa_part.len;
    var digits = std.ArrayList(u8).init(allocator);
    defer digits.deinit();
    for (mantissa_part) |c| {
        if (c != '.') {
            digits.append(c) catch return ToonError.OutOfMemory;
        }
    }
    const current_dec_pos: i32 = @intCast(dec_pos);
    const new_dec_pos = current_dec_pos + exponent;
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    if (neg_mantissa) {
        result.append('-') catch return ToonError.OutOfMemory;
    }
    const digit_count: i32 = @intCast(digits.items.len);
    if (new_dec_pos <= 0) {
        result.append('0') catch return ToonError.OutOfMemory;
        result.append('.') catch return ToonError.OutOfMemory;
        const zeros_needed: usize = @intCast(-new_dec_pos);
        for (0..zeros_needed) |_| {
            result.append('0') catch return ToonError.OutOfMemory;
        }
        result.appendSlice(digits.items) catch return ToonError.OutOfMemory;
    } else if (new_dec_pos >= digit_count) {
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
    const slice = result.toOwnedSlice() catch return ToonError.OutOfMemory;
    defer allocator.free(slice);
    return trimTrailingZeros(allocator, slice);
}
fn trimTrailingZeros(allocator: Allocator, input: []const u8) Allocator.Error![]u8 {
    const dec_pos = std.mem.indexOf(u8, input, ".") orelse return allocator.dupe(u8, input);
    var end = input.len;
    while (end > dec_pos + 1 and input[end - 1] == '0') {
        end -= 1;
    }
    if (end == dec_pos + 1) {
        end = dec_pos;
    }
    return allocator.dupe(u8, input[0..end]);
}
pub fn parseNumber(input: []const u8) ?NumberValue {
    if (input.len == 0) return null;
    var i: usize = 0;
    var negative = false;
    if (input[i] == '-') {
        negative = true;
        i += 1;
        if (i >= input.len) return null;
    }
    if (input[i] == '0' and i + 1 < input.len) {
        const next = input[i + 1];
        // 0 followed by digit is forbidden (e.g., "05", "007")
        // 0 followed by . or e/E is allowed (e.g., "0.5", "0e1")
        if (next >= '0' and next <= '9') {
            return null;
        }
    }
    var has_digits = false;
    while (i < input.len and input[i] >= '0' and input[i] <= '9') {
        has_digits = true;
        i += 1;
    }
    if (!has_digits) return null;
    var is_float = false;
    if (i < input.len and input[i] == '.') {
        is_float = true;
        i += 1;
        var frac_digits = false;
        while (i < input.len and input[i] >= '0' and input[i] <= '9') {
            frac_digits = true;
            i += 1;
        }
        if (!frac_digits) return null;
    }
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
    if (i != input.len) return null;
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
pub const NumberValue = union(enum) {
    integer: i64,
    float: f64,
};
pub fn looksLikeNumber(input: []const u8) bool {
    if (input.len == 0) return false;
    if (parseNumber(input) != null) return true;
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
    const whole = try formatFloat(allocator, 1.0);
    defer allocator.free(whole);
    try std.testing.expectEqualStrings("1", whole);
    const neg_zero = try formatFloat(allocator, -0.0);
    defer allocator.free(neg_zero);
    try std.testing.expectEqualStrings("0", neg_zero);
    const dec = try formatFloat(allocator, 3.14);
    defer allocator.free(dec);
    try std.testing.expect(std.mem.startsWith(u8, dec, "3.14"));
    const nan = try formatFloat(allocator, std.math.nan(f64));
    defer allocator.free(nan);
    try std.testing.expectEqualStrings("null", nan);
    const inf = try formatFloat(allocator, std.math.inf(f64));
    defer allocator.free(inf);
    try std.testing.expectEqualStrings("null", inf);
}
test "parseNumber" {
    try std.testing.expectEqual(@as(i64, 42), parseNumber("42").?.integer);
    try std.testing.expectEqual(@as(i64, -123), parseNumber("-123").?.integer);
    try std.testing.expectEqual(@as(i64, 0), parseNumber("0").?.integer);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), parseNumber("3.14").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, -0.5), parseNumber("-0.5").?.float, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1000.0), parseNumber("1e3").?.float, 0.001);
    try std.testing.expect(parseNumber("05") == null);
    try std.testing.expect(parseNumber("007") == null);
    try std.testing.expect(parseNumber("-05") == null);
    try std.testing.expect(parseNumber("0.5") != null);
    try std.testing.expect(parseNumber("0e1") != null);
    try std.testing.expect(parseNumber("") == null);
    try std.testing.expect(parseNumber("abc") == null);
    try std.testing.expect(parseNumber("1.") == null);
    try std.testing.expect(parseNumber(".5") == null);
}
test "looksLikeNumber" {
    try std.testing.expect(looksLikeNumber("42"));
    try std.testing.expect(looksLikeNumber("-3.14"));
    try std.testing.expect(looksLikeNumber("1e-6"));
    try std.testing.expect(looksLikeNumber("05"));
    try std.testing.expect(looksLikeNumber("-007"));
    try std.testing.expect(!looksLikeNumber("hello"));
    try std.testing.expect(!looksLikeNumber(""));
}
