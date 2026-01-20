//! String escaping and unescaping per TOON §7.1.
//!
//! TOON supports only five escape sequences:
//! - \\ → backslash
//! - \" → double quote
//! - \n → newline (U+000A)
//! - \r → carriage return (U+000D)
//! - \t → tab (U+0009)
//!
//! Any other escape sequence is invalid.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ToonError = @import("error.zig").ToonError;

/// Escape a string for TOON output.
/// Only escapes: \, ", newline, carriage return, tab.
pub fn escapeString(allocator: Allocator, input: []const u8) ToonError![]u8 {
    // Count how many characters need escaping
    var extra_chars: usize = 0;
    for (input) |c| {
        if (needsEscape(c)) {
            extra_chars += 1;
        }
    }

    if (extra_chars == 0) {
        return allocator.dupe(u8, input) catch return ToonError.OutOfMemory;
    }

    var result = allocator.alloc(u8, input.len + extra_chars) catch return ToonError.OutOfMemory;
    var i: usize = 0;
    for (input) |c| {
        switch (c) {
            '\\' => {
                result[i] = '\\';
                result[i + 1] = '\\';
                i += 2;
            },
            '"' => {
                result[i] = '\\';
                result[i + 1] = '"';
                i += 2;
            },
            '\n' => {
                result[i] = '\\';
                result[i + 1] = 'n';
                i += 2;
            },
            '\r' => {
                result[i] = '\\';
                result[i + 1] = 'r';
                i += 2;
            },
            '\t' => {
                result[i] = '\\';
                result[i + 1] = 't';
                i += 2;
            },
            else => {
                result[i] = c;
                i += 1;
            },
        }
    }
    return result;
}

/// Unescape a TOON string.
/// Returns error for invalid escape sequences or unterminated strings.
pub fn unescapeString(allocator: Allocator, input: []const u8) ToonError![]u8 {
    // Count escapes to determine output size
    var escape_count: usize = 0;
    var i: usize = 0;
    while (i < input.len) {
        if (input[i] == '\\') {
            if (i + 1 >= input.len) {
                return ToonError.UnterminatedString;
            }
            const next = input[i + 1];
            if (!isValidEscapeChar(next)) {
                return ToonError.InvalidEscape;
            }
            escape_count += 1;
            i += 2;
        } else {
            i += 1;
        }
    }

    if (escape_count == 0) {
        return allocator.dupe(u8, input) catch return ToonError.OutOfMemory;
    }

    var result = allocator.alloc(u8, input.len - escape_count) catch return ToonError.OutOfMemory;
    errdefer allocator.free(result);

    var src_i: usize = 0;
    var dst_i: usize = 0;
    while (src_i < input.len) {
        if (input[src_i] == '\\') {
            const next = input[src_i + 1];
            result[dst_i] = switch (next) {
                '\\' => '\\',
                '"' => '"',
                'n' => '\n',
                'r' => '\r',
                't' => '\t',
                else => unreachable, // Already validated above
            };
            src_i += 2;
        } else {
            result[dst_i] = input[src_i];
            src_i += 1;
        }
        dst_i += 1;
    }

    return result;
}

/// Check if a character needs escaping.
pub fn needsEscape(c: u8) bool {
    return switch (c) {
        '\\', '"', '\n', '\r', '\t' => true,
        else => false,
    };
}

/// Check if a character is valid after a backslash.
fn isValidEscapeChar(c: u8) bool {
    return switch (c) {
        '\\', '"', 'n', 'r', 't' => true,
        else => false,
    };
}

/// Check if a string contains any characters that need escaping.
pub fn containsEscapable(input: []const u8) bool {
    for (input) |c| {
        if (needsEscape(c)) return true;
    }
    return false;
}

test "escape string" {
    const allocator = std.testing.allocator;

    // No escaping needed
    const simple = try escapeString(allocator, "hello");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("hello", simple);

    // Backslash
    const backslash = try escapeString(allocator, "a\\b");
    defer allocator.free(backslash);
    try std.testing.expectEqualStrings("a\\\\b", backslash);

    // Quote
    const quote = try escapeString(allocator, "say \"hi\"");
    defer allocator.free(quote);
    try std.testing.expectEqualStrings("say \\\"hi\\\"", quote);

    // Newline
    const newline = try escapeString(allocator, "line1\nline2");
    defer allocator.free(newline);
    try std.testing.expectEqualStrings("line1\\nline2", newline);

    // All escapes
    const all = try escapeString(allocator, "\\\"\n\r\t");
    defer allocator.free(all);
    try std.testing.expectEqualStrings("\\\\\\\"\\n\\r\\t", all);
}

test "unescape string" {
    const allocator = std.testing.allocator;

    // No escaping
    const simple = try unescapeString(allocator, "hello");
    defer allocator.free(simple);
    try std.testing.expectEqualStrings("hello", simple);

    // Backslash
    const backslash = try unescapeString(allocator, "a\\\\b");
    defer allocator.free(backslash);
    try std.testing.expectEqualStrings("a\\b", backslash);

    // Quote
    const quote = try unescapeString(allocator, "say \\\"hi\\\"");
    defer allocator.free(quote);
    try std.testing.expectEqualStrings("say \"hi\"", quote);

    // All escapes
    const all = try unescapeString(allocator, "\\\\\\\"\\n\\r\\t");
    defer allocator.free(all);
    try std.testing.expectEqualStrings("\\\"\n\r\t", all);
}

test "unescape invalid sequences" {
    const allocator = std.testing.allocator;

    // Invalid escape
    try std.testing.expectError(ToonError.InvalidEscape, unescapeString(allocator, "\\x"));
    try std.testing.expectError(ToonError.InvalidEscape, unescapeString(allocator, "\\u0041"));

    // Unterminated
    try std.testing.expectError(ToonError.UnterminatedString, unescapeString(allocator, "test\\"));
}
