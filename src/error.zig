//! Error types for TOON encoding and decoding.

const std = @import("std");

/// Errors that can occur during TOON encoding or decoding.
pub const ToonError = error{
    /// Memory allocation failed.
    OutOfMemory,

    // === Syntax Errors (§14.2) ===
    /// Invalid escape sequence in quoted string.
    InvalidEscape,
    /// Unterminated quoted string.
    UnterminatedString,
    /// Missing colon after key.
    MissingColon,
    /// Invalid array header syntax.
    InvalidArrayHeader,
    /// Mismatched delimiter between bracket and brace segments.
    DelimiterMismatch,
    /// Invalid character in unquoted key.
    InvalidKey,
    /// Unexpected character encountered.
    UnexpectedCharacter,

    // === Count/Width Mismatches (§14.1) ===
    /// Array length does not match declared count.
    ArrayLengthMismatch,
    /// Tabular row width does not match field count.
    RowWidthMismatch,

    // === Indentation Errors (§14.3) ===
    /// Leading spaces not a multiple of indent size.
    InvalidIndentation,
    /// Tab used for indentation (not allowed).
    TabIndentation,
    /// Unexpected indentation level.
    UnexpectedIndent,

    // === Structural Errors (§14.4) ===
    /// Blank line inside array or tabular block.
    BlankLineInArray,
    /// Invalid list item marker.
    InvalidListItem,
    /// Structural nesting error.
    NestingError,

    // === Path Expansion Conflicts (§14.5) ===
    /// Expansion conflict (object vs primitive/array).
    ExpansionConflict,

    // === Number Errors ===
    /// Number cannot be represented.
    InvalidNumber,
    /// Number overflow.
    Overflow,

    // === General ===
    /// Invalid input.
    InvalidInput,
    /// End of input reached unexpectedly.
    UnexpectedEndOfInput,
};

/// Error context with line/column information for diagnostics.
pub const ErrorContext = struct {
    line: usize,
    column: usize,
    message: []const u8,

    pub fn format(
        self: ErrorContext,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;
        try writer.print("line {d}, column {d}: {s}", .{ self.line, self.column, self.message });
    }
};
