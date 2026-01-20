const std = @import("std");

pub const ToonError = error{
    OutOfMemory,
    InvalidEscape,
    UnterminatedString,
    MissingColon,
    InvalidArrayHeader,
    DelimiterMismatch,
    InvalidKey,
    UnexpectedCharacter,
    ArrayLengthMismatch,
    RowWidthMismatch,
    InvalidIndentation,
    TabIndentation,
    UnexpectedIndent,
    BlankLineInArray,
    InvalidListItem,
    NestingError,
    ExpansionConflict,
    InvalidNumber,
    Overflow,
    InvalidInput,
    UnexpectedEndOfInput,
};

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
