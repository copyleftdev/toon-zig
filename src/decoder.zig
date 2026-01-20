//! TOON Decoder - TOON to JSON conversion.
//!
//! Implements the decoding rules per TOON specification v3.0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ToonError = @import("error.zig").ToonError;
const value_mod = @import("value.zig");
const JsonValue = value_mod.JsonValue;
const JsonObject = value_mod.JsonObject;
const JsonArray = value_mod.JsonArray;
const escape = @import("escape.zig");
const number = @import("number.zig");
const encoder = @import("encoder.zig");
const Delimiter = encoder.Delimiter;

/// Path expansion mode per §13.4.
pub const PathExpansionMode = enum {
    off,
    safe,
};

/// Decoder options.
pub const DecodeOptions = struct {
    /// Number of spaces per indentation level (default: 2).
    indent: usize = 2,
    /// Strict mode validation (default: true).
    strict: bool = true,
    /// Path expansion mode (default: off).
    expand_paths: PathExpansionMode = .off,
};

/// Parsed line information.
const Line = struct {
    content: []const u8,
    depth: usize,
    line_number: usize,
    is_blank: bool,
};

/// Array header information.
const ArrayHeader = struct {
    key: ?[]const u8,
    length: usize,
    delimiter: Delimiter,
    fields: ?[][]const u8,
    inline_values: ?[]const u8,
};

/// Decoder state.
const Decoder = struct {
    allocator: Allocator,
    options: DecodeOptions,
    lines: []Line,
    current_line: usize,
    active_delimiter: Delimiter,

    fn init(allocator: Allocator, input: []const u8, options: DecodeOptions) ToonError!Decoder {
        var lines_list = std.ArrayList(Line).init(allocator);
        errdefer lines_list.deinit();

        var line_start: usize = 0;
        var line_number: usize = 1;

        for (input, 0..) |c, i| {
            if (c == '\n') {
                const line_content = input[line_start..i];
                const line = try parseLine(line_content, line_number, options.indent, options.strict);
                lines_list.append(line) catch return ToonError.OutOfMemory;
                line_start = i + 1;
                line_number += 1;
            }
        }

        // Handle last line (no trailing newline)
        if (line_start <= input.len) {
            const line_content = input[line_start..];
            if (line_content.len > 0 or line_start < input.len) {
                const line = try parseLine(line_content, line_number, options.indent, options.strict);
                lines_list.append(line) catch return ToonError.OutOfMemory;
            }
        }

        return .{
            .allocator = allocator,
            .options = options,
            .lines = lines_list.toOwnedSlice() catch return ToonError.OutOfMemory,
            .current_line = 0,
            .active_delimiter = .comma,
        };
    }

    fn deinit(self: *Decoder) void {
        self.allocator.free(self.lines);
    }

    fn parseLine(content: []const u8, line_number: usize, indent_size: usize, strict: bool) ToonError!Line {
        // Count leading spaces
        var spaces: usize = 0;
        for (content) |c| {
            if (c == ' ') {
                spaces += 1;
            } else if (c == '\t') {
                if (strict) return ToonError.TabIndentation;
                spaces += indent_size; // Approximate
            } else {
                break;
            }
        }

        // Check indentation is valid multiple
        if (strict and spaces % indent_size != 0) {
            return ToonError.InvalidIndentation;
        }

        const depth = spaces / indent_size;
        const trimmed = std.mem.trimRight(u8, content[spaces..], " \t");
        const is_blank = trimmed.len == 0;

        return .{
            .content = trimmed,
            .depth = depth,
            .line_number = line_number,
            .is_blank = is_blank,
        };
    }

    fn currentLine(self: *Decoder) ?*const Line {
        if (self.current_line >= self.lines.len) return null;
        return &self.lines[self.current_line];
    }

    fn advance(self: *Decoder) void {
        self.current_line += 1;
    }

    fn skipBlankLines(self: *Decoder) void {
        while (self.currentLine()) |line| {
            if (!line.is_blank) break;
            self.advance();
        }
    }

    fn peekNonBlank(self: *Decoder) ?*const Line {
        var i = self.current_line;
        while (i < self.lines.len) {
            if (!self.lines[i].is_blank) {
                return &self.lines[i];
            }
            i += 1;
        }
        return null;
    }

    /// Decode the root value.
    fn decodeRoot(self: *Decoder) ToonError!JsonValue {
        self.skipBlankLines();

        // Empty document → empty object
        if (self.peekNonBlank() == null) {
            return JsonValue.initObject(self.allocator);
        }

        const first = self.peekNonBlank().?;

        // Check for root array header (starts with '[', no key)
        if (isRootArrayHeader(first.content)) {
            return self.decodeRootArray();
        }

        // Check for single primitive (exactly one non-blank line, no colon/array header)
        if (self.countNonBlankLines() == 1) {
            if (!isKeyValueLine(first.content) and !isArrayHeader(first.content)) {
                return self.decodePrimitive(first.content);
            }
        }

        // Default: object
        return self.decodeObject(0);
    }

    fn countNonBlankLines(self: *Decoder) usize {
        var count: usize = 0;
        for (self.lines) |line| {
            if (!line.is_blank) count += 1;
        }
        return count;
    }

    /// Decode a root array.
    fn decodeRootArray(self: *Decoder) ToonError!JsonValue {
        const line = self.currentLine() orelse return ToonError.UnexpectedEndOfInput;
        self.advance();

        const header = try self.parseArrayHeader(line.content);
        self.active_delimiter = header.delimiter;

        var arr = JsonValue.initArray(self.allocator);
        errdefer arr.deinit(self.allocator);

        if (header.fields) |fields| {
            // Tabular array
            defer self.allocator.free(fields);
            try self.decodeTabularRows(&arr, header.length, fields, line.depth);
        } else if (header.inline_values) |inline_vals| {
            // Inline primitive array
            try self.decodeInlineValues(&arr, inline_vals);
            if (self.options.strict and arr.asConstArray().?.items.len != header.length) {
                return ToonError.ArrayLengthMismatch;
            }
        } else {
            // Expanded list
            try self.decodeExpandedList(&arr, header.length, line.depth);
        }

        return arr;
    }

    /// Decode an object at given depth.
    fn decodeObject(self: *Decoder, depth: usize) ToonError!JsonValue {
        var obj = JsonValue.initObject(self.allocator);
        errdefer obj.deinit(self.allocator);

        while (self.currentLine()) |line| {
            if (line.is_blank) {
                self.advance();
                continue;
            }

            if (line.depth < depth) break;
            if (line.depth > depth) {
                if (self.options.strict) return ToonError.UnexpectedIndent;
                self.advance();
                continue;
            }

            // Parse key-value or nested structure
            const kv = try self.parseKeyValue(line.content);
            self.advance();

            const key_copy = self.allocator.dupe(u8, kv.key) catch return ToonError.OutOfMemory;
            errdefer self.allocator.free(key_copy);

            if (kv.is_array_header) {
                // Array field
                const header = try self.parseArrayHeader(line.content);
                self.active_delimiter = header.delimiter;

                var arr = JsonValue.initArray(self.allocator);
                errdefer arr.deinit(self.allocator);

                if (header.fields) |fields| {
                    defer self.allocator.free(fields);
                    try self.decodeTabularRows(&arr, header.length, fields, line.depth);
                } else if (header.inline_values) |inline_vals| {
                    try self.decodeInlineValues(&arr, inline_vals);
                    if (self.options.strict and arr.asConstArray().?.items.len != header.length) {
                        return ToonError.ArrayLengthMismatch;
                    }
                } else {
                    try self.decodeExpandedList(&arr, header.length, line.depth);
                }

                obj.asObject().?.put(key_copy, arr) catch return ToonError.OutOfMemory;
            } else if (kv.value) |val_str| {
                // Primitive value
                const val = try self.decodePrimitive(val_str);
                obj.asObject().?.put(key_copy, val) catch return ToonError.OutOfMemory;
            } else {
                // Nested object
                const nested = try self.decodeObject(depth + 1);
                obj.asObject().?.put(key_copy, nested) catch return ToonError.OutOfMemory;
            }
        }

        // Apply path expansion if enabled
        if (self.options.expand_paths == .safe) {
            return self.expandPaths(obj);
        }

        return obj;
    }

    /// Decode tabular rows.
    fn decodeTabularRows(self: *Decoder, arr: *JsonValue, expected_count: usize, fields: [][]const u8, header_depth: usize) ToonError!void {
        const row_depth = header_depth + 1;
        var row_count: usize = 0;

        while (self.currentLine()) |line| {
            if (line.is_blank) {
                if (self.options.strict and row_count > 0 and row_count < expected_count) {
                    return ToonError.BlankLineInArray;
                }
                self.advance();
                continue;
            }

            if (line.depth != row_depth) break;

            // Check if this is a row or a key-value line (disambiguation per §9.3)
            if (self.isTabularRow(line.content)) {
                const row_obj = try self.decodeTabularRow(line.content, fields);
                arr.asArray().?.append(row_obj) catch return ToonError.OutOfMemory;
                row_count += 1;
                self.advance();
            } else {
                break; // End of rows
            }
        }

        if (self.options.strict and row_count != expected_count) {
            return ToonError.ArrayLengthMismatch;
        }
    }

    /// Check if a line is a tabular row (not a key-value line).
    fn isTabularRow(self: *Decoder, content: []const u8) bool {
        const delim_pos = self.findFirstUnquoted(content, self.active_delimiter.char());
        const colon_pos = self.findFirstUnquoted(content, ':');

        // No colon → row
        if (colon_pos == null) return true;

        // Both exist → compare positions
        if (delim_pos) |d| {
            if (colon_pos) |c| {
                return d < c;
            }
        }

        // Only colon → key-value line
        return false;
    }

    /// Find first unquoted occurrence of a character.
    fn findFirstUnquoted(self: *Decoder, content: []const u8, char: u8) ?usize {
        _ = self;
        var in_quotes = false;
        var i: usize = 0;

        while (i < content.len) {
            const c = content[i];
            if (c == '"' and (i == 0 or content[i - 1] != '\\')) {
                in_quotes = !in_quotes;
            } else if (!in_quotes and c == char) {
                return i;
            }
            i += 1;
        }

        return null;
    }

    /// Decode a single tabular row.
    fn decodeTabularRow(self: *Decoder, content: []const u8, fields: [][]const u8) ToonError!JsonValue {
        const values = try self.splitDelimited(content);
        defer self.allocator.free(values);

        if (self.options.strict and values.len != fields.len) {
            return ToonError.RowWidthMismatch;
        }

        var obj = JsonValue.initObject(self.allocator);
        errdefer obj.deinit(self.allocator);

        for (fields, 0..) |field, i| {
            const key_copy = self.allocator.dupe(u8, field) catch return ToonError.OutOfMemory;
            errdefer self.allocator.free(key_copy);

            const val = if (i < values.len)
                try self.decodePrimitive(values[i])
            else
                JsonValue.initNull();

            obj.asObject().?.put(key_copy, val) catch return ToonError.OutOfMemory;
        }

        return obj;
    }

    /// Decode inline values.
    fn decodeInlineValues(self: *Decoder, arr: *JsonValue, inline_vals: []const u8) ToonError!void {
        if (inline_vals.len == 0) return;

        const values = try self.splitDelimited(inline_vals);
        defer self.allocator.free(values);

        for (values) |val_str| {
            const val = try self.decodePrimitive(val_str);
            arr.asArray().?.append(val) catch return ToonError.OutOfMemory;
        }
    }

    /// Decode an expanded list.
    fn decodeExpandedList(self: *Decoder, arr: *JsonValue, expected_count: usize, header_depth: usize) ToonError!void {
        const item_depth = header_depth + 1;
        var item_count: usize = 0;

        while (self.currentLine()) |line| {
            if (line.is_blank) {
                if (self.options.strict and item_count > 0 and item_count < expected_count) {
                    return ToonError.BlankLineInArray;
                }
                self.advance();
                continue;
            }

            if (line.depth != item_depth) break;

            if (!std.mem.startsWith(u8, line.content, "- ") and !std.mem.eql(u8, line.content, "-")) {
                break;
            }

            const item = try self.decodeListItem(line);
            arr.asArray().?.append(item) catch return ToonError.OutOfMemory;
            item_count += 1;
        }

        if (self.options.strict and item_count != expected_count) {
            return ToonError.ArrayLengthMismatch;
        }
    }

    /// Decode a list item.
    fn decodeListItem(self: *Decoder, line: *const Line) ToonError!JsonValue {
        self.advance();

        // Empty object: bare "-"
        if (std.mem.eql(u8, line.content, "-")) {
            return JsonValue.initObject(self.allocator);
        }

        const after_hyphen = line.content[2..]; // Skip "- "

        // Inline array: - [N]: ...
        if (std.mem.startsWith(u8, after_hyphen, "[")) {
            const header = try self.parseArrayHeader(after_hyphen);
            self.active_delimiter = header.delimiter;

            var arr = JsonValue.initArray(self.allocator);
            errdefer arr.deinit(self.allocator);

            if (header.inline_values) |inline_vals| {
                try self.decodeInlineValues(&arr, inline_vals);
            } else {
                // Nested expanded list
                try self.decodeExpandedList(&arr, header.length, line.depth);
            }

            if (self.options.strict and arr.asConstArray().?.items.len != header.length) {
                return ToonError.ArrayLengthMismatch;
            }

            return arr;
        }

        // Object or primitive
        if (self.findFirstUnquoted(after_hyphen, ':')) |colon_pos| {
            // Object with first field on hyphen line
            return self.decodeListItemObject(after_hyphen, colon_pos, line.depth);
        } else {
            // Primitive
            return self.decodePrimitive(after_hyphen);
        }
    }

    /// Decode a list item that is an object.
    fn decodeListItemObject(self: *Decoder, content: []const u8, colon_pos: usize, hyphen_depth: usize) ToonError!JsonValue {
        var obj = JsonValue.initObject(self.allocator);
        errdefer obj.deinit(self.allocator);

        // Parse first field
        const key_part = std.mem.trim(u8, content[0..colon_pos], " ");
        const key = try self.parseKey(key_part);
        const key_copy = self.allocator.dupe(u8, key) catch return ToonError.OutOfMemory;
        errdefer self.allocator.free(key_copy);

        const after_colon = std.mem.trim(u8, content[colon_pos + 1 ..], " ");

        // Check if first field is an array
        if (std.mem.startsWith(u8, key_part, "[") or std.mem.indexOf(u8, key_part, "[") != null) {
            // Array header on hyphen line
            const header = try self.parseArrayHeader(content);
            self.active_delimiter = header.delimiter;

            var arr = JsonValue.initArray(self.allocator);
            errdefer arr.deinit(self.allocator);

            if (header.fields) |fields| {
                defer self.allocator.free(fields);
                // Tabular rows at depth +2
                try self.decodeTabularRowsAtDepth(&arr, header.length, fields, hyphen_depth + 2);
            } else if (header.inline_values) |inline_vals| {
                try self.decodeInlineValues(&arr, inline_vals);
            } else {
                try self.decodeExpandedList(&arr, header.length, hyphen_depth);
            }

            obj.asObject().?.put(key_copy, arr) catch return ToonError.OutOfMemory;
        } else if (after_colon.len > 0) {
            // Primitive value
            const val = try self.decodePrimitive(after_colon);
            obj.asObject().?.put(key_copy, val) catch return ToonError.OutOfMemory;
        } else {
            // Nested object
            const nested = try self.decodeObject(hyphen_depth + 2);
            obj.asObject().?.put(key_copy, nested) catch return ToonError.OutOfMemory;
        }

        // Parse remaining fields at depth +1
        const field_depth = hyphen_depth + 1;
        while (self.currentLine()) |line| {
            if (line.is_blank) {
                self.advance();
                continue;
            }

            if (line.depth != field_depth) break;

            const kv = try self.parseKeyValue(line.content);
            self.advance();

            const field_key = self.allocator.dupe(u8, kv.key) catch return ToonError.OutOfMemory;
            errdefer self.allocator.free(field_key);

            if (kv.is_array_header) {
                const header = try self.parseArrayHeader(line.content);
                self.active_delimiter = header.delimiter;

                var arr = JsonValue.initArray(self.allocator);
                errdefer arr.deinit(self.allocator);

                if (header.fields) |fields| {
                    defer self.allocator.free(fields);
                    try self.decodeTabularRows(&arr, header.length, fields, line.depth);
                } else if (header.inline_values) |inline_vals| {
                    try self.decodeInlineValues(&arr, inline_vals);
                } else {
                    try self.decodeExpandedList(&arr, header.length, line.depth);
                }

                obj.asObject().?.put(field_key, arr) catch return ToonError.OutOfMemory;
            } else if (kv.value) |val_str| {
                const val = try self.decodePrimitive(val_str);
                obj.asObject().?.put(field_key, val) catch return ToonError.OutOfMemory;
            } else {
                const nested = try self.decodeObject(field_depth + 1);
                obj.asObject().?.put(field_key, nested) catch return ToonError.OutOfMemory;
            }
        }

        return obj;
    }

    fn decodeTabularRowsAtDepth(self: *Decoder, arr: *JsonValue, expected_count: usize, fields: [][]const u8, row_depth: usize) ToonError!void {
        var row_count: usize = 0;

        while (self.currentLine()) |line| {
            if (line.is_blank) {
                if (self.options.strict and row_count > 0 and row_count < expected_count) {
                    return ToonError.BlankLineInArray;
                }
                self.advance();
                continue;
            }

            if (line.depth != row_depth) break;

            if (self.isTabularRow(line.content)) {
                const row_obj = try self.decodeTabularRow(line.content, fields);
                arr.asArray().?.append(row_obj) catch return ToonError.OutOfMemory;
                row_count += 1;
                self.advance();
            } else {
                break;
            }
        }

        if (self.options.strict and row_count != expected_count) {
            return ToonError.ArrayLengthMismatch;
        }
    }

    /// Split content by active delimiter, respecting quotes.
    fn splitDelimited(self: *Decoder, content: []const u8) ToonError![][]const u8 {
        var parts = std.ArrayList([]const u8).init(self.allocator);
        errdefer parts.deinit();

        var start: usize = 0;
        var in_quotes = false;
        var i: usize = 0;

        while (i < content.len) {
            const c = content[i];
            if (c == '"' and (i == 0 or content[i - 1] != '\\')) {
                in_quotes = !in_quotes;
            } else if (!in_quotes and c == self.active_delimiter.char()) {
                const part = std.mem.trim(u8, content[start..i], " ");
                parts.append(part) catch return ToonError.OutOfMemory;
                start = i + 1;
            }
            i += 1;
        }

        // Last part
        const part = std.mem.trim(u8, content[start..], " ");
        parts.append(part) catch return ToonError.OutOfMemory;

        return parts.toOwnedSlice() catch return ToonError.OutOfMemory;
    }

    /// Parse a primitive token per §4.
    fn decodePrimitive(self: *Decoder, token: []const u8) ToonError!JsonValue {
        const trimmed = std.mem.trim(u8, token, " ");

        if (trimmed.len == 0) {
            return JsonValue.initStringCopy(self.allocator, "");
        }

        // Quoted string
        if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
            const inner = trimmed[1 .. trimmed.len - 1];
            const unescaped = try escape.unescapeString(self.allocator, inner);
            return .{ .string = unescaped };
        }

        // Unquoted tokens
        if (std.mem.eql(u8, trimmed, "null")) return JsonValue.initNull();
        if (std.mem.eql(u8, trimmed, "true")) return JsonValue.initBool(true);
        if (std.mem.eql(u8, trimmed, "false")) return JsonValue.initBool(false);

        // Number
        if (number.parseNumber(trimmed)) |num| {
            return switch (num) {
                .integer => |i| JsonValue.initInteger(i),
                .float => |f| JsonValue.initFloat(f),
            };
        }

        // Otherwise string (unquoted)
        return JsonValue.initStringCopy(self.allocator, trimmed);
    }

    /// Parse an array header.
    fn parseArrayHeader(self: *Decoder, content: []const u8) ToonError!ArrayHeader {
        // Find key (if any) and bracket segment
        const bracket_start = std.mem.indexOf(u8, content, "[") orelse return ToonError.InvalidArrayHeader;
        const bracket_end = std.mem.indexOf(u8, content, "]") orelse return ToonError.InvalidArrayHeader;

        if (bracket_end <= bracket_start) return ToonError.InvalidArrayHeader;

        const key = if (bracket_start > 0)
            try self.parseKey(std.mem.trim(u8, content[0..bracket_start], " "))
        else
            null;

        // Parse length and delimiter from bracket segment
        const bracket_content = content[bracket_start + 1 .. bracket_end];
        var length: usize = 0;
        var delimiter: Delimiter = .comma;

        // Check for delimiter at end
        if (bracket_content.len > 0) {
            const last_char = bracket_content[bracket_content.len - 1];
            if (last_char == '\t') {
                delimiter = .tab;
                length = std.fmt.parseInt(usize, bracket_content[0 .. bracket_content.len - 1], 10) catch return ToonError.InvalidArrayHeader;
            } else if (last_char == '|') {
                delimiter = .pipe;
                length = std.fmt.parseInt(usize, bracket_content[0 .. bracket_content.len - 1], 10) catch return ToonError.InvalidArrayHeader;
            } else {
                length = std.fmt.parseInt(usize, bracket_content, 10) catch return ToonError.InvalidArrayHeader;
            }
        }

        // Check for field list
        var fields: ?[][]const u8 = null;
        const brace_start = std.mem.indexOf(u8, content[bracket_end..], "{");
        const brace_end = std.mem.indexOf(u8, content[bracket_end..], "}");

        if (brace_start != null and brace_end != null) {
            const brace_start_abs = bracket_end + brace_start.?;
            const brace_end_abs = bracket_end + brace_end.?;
            const fields_str = content[brace_start_abs + 1 .. brace_end_abs];

            // Split fields by delimiter
            var field_list = std.ArrayList([]const u8).init(self.allocator);
            errdefer field_list.deinit();

            var start: usize = 0;
            var i: usize = 0;
            while (i < fields_str.len) {
                if (fields_str[i] == delimiter.char()) {
                    const field = std.mem.trim(u8, fields_str[start..i], " ");
                    const parsed_field = try self.parseKey(field);
                    field_list.append(parsed_field) catch return ToonError.OutOfMemory;
                    start = i + 1;
                }
                i += 1;
            }
            const last_field = std.mem.trim(u8, fields_str[start..], " ");
            const parsed_last = try self.parseKey(last_field);
            field_list.append(parsed_last) catch return ToonError.OutOfMemory;

            fields = field_list.toOwnedSlice() catch return ToonError.OutOfMemory;
        }

        // Find colon
        const colon_pos = std.mem.indexOf(u8, content, ":") orelse return ToonError.MissingColon;

        // Check for inline values after colon
        var inline_values: ?[]const u8 = null;
        if (colon_pos + 1 < content.len) {
            const after_colon = std.mem.trim(u8, content[colon_pos + 1 ..], " ");
            if (after_colon.len > 0) {
                inline_values = after_colon;
            }
        }

        return .{
            .key = key,
            .length = length,
            .delimiter = delimiter,
            .fields = fields,
            .inline_values = inline_values,
        };
    }

    /// Parse a key (quoted or unquoted).
    fn parseKey(self: *Decoder, raw: []const u8) ToonError![]const u8 {
        if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') {
            // Quoted key - unescape
            const inner = raw[1 .. raw.len - 1];
            const unescaped = try escape.unescapeString(self.allocator, inner);
            return unescaped;
        }
        return raw;
    }

    /// Parse key-value or key-only line.
    const KeyValueResult = struct {
        key: []const u8,
        value: ?[]const u8,
        is_array_header: bool,
    };

    fn parseKeyValue(self: *Decoder, content: []const u8) ToonError!KeyValueResult {
        // Check for array header first
        if (std.mem.indexOf(u8, content, "[")) |bracket_pos| {
            if (self.findFirstUnquoted(content, ':')) |colon_pos| {
                if (bracket_pos < colon_pos) {
                    // This is an array header
                    const key = std.mem.trim(u8, content[0..bracket_pos], " ");
                    return .{
                        .key = try self.parseKey(key),
                        .value = null,
                        .is_array_header = true,
                    };
                }
            }
        }

        // Regular key-value
        const colon_pos = self.findFirstUnquoted(content, ':') orelse return ToonError.MissingColon;

        const key = std.mem.trim(u8, content[0..colon_pos], " ");
        const after_colon = std.mem.trim(u8, content[colon_pos + 1 ..], " ");

        return .{
            .key = try self.parseKey(key),
            .value = if (after_colon.len > 0) after_colon else null,
            .is_array_header = false,
        };
    }

    /// Apply path expansion per §13.4.
    fn expandPaths(self: *Decoder, obj: JsonValue) ToonError!JsonValue {
        var result = JsonValue.initObject(self.allocator);
        errdefer result.deinit(self.allocator);

        var it = obj.asConstObject().?.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            // Check if key contains dot and is expandable
            if (std.mem.indexOf(u8, key, ".")) |_| {
                if (self.isExpandableKey(key)) {
                    try self.expandAndMerge(&result, key, val);
                    continue;
                }
            }

            // No expansion - copy directly
            const key_copy = self.allocator.dupe(u8, key) catch return ToonError.OutOfMemory;
            const val_copy = try val.clone(self.allocator);
            result.asObject().?.put(key_copy, val_copy) catch return ToonError.OutOfMemory;
        }

        return result;
    }

    /// Check if a key is expandable (all segments are IdentifierSegments).
    fn isExpandableKey(self: *Decoder, key: []const u8) bool {
        _ = self;
        var it = std.mem.splitScalar(u8, key, '.');
        while (it.next()) |segment| {
            if (!isIdentifierSegment(segment)) return false;
        }
        return true;
    }

    /// Expand a dotted key and merge into result.
    fn expandAndMerge(self: *Decoder, result: *JsonValue, key: []const u8, val: JsonValue) ToonError!void {
        var segments = std.ArrayList([]const u8).init(self.allocator);
        defer segments.deinit();

        var it = std.mem.splitScalar(u8, key, '.');
        while (it.next()) |segment| {
            segments.append(segment) catch return ToonError.OutOfMemory;
        }

        try self.setNestedValue(result, segments.items, val);
    }

    /// Set a value at a nested path, creating objects as needed.
    fn setNestedValue(self: *Decoder, obj: *JsonValue, path: []const []const u8, val: JsonValue) ToonError!void {
        if (path.len == 0) return;

        const first = path[0];
        const rest = path[1..];

        if (rest.len == 0) {
            // Final segment - set the value
            if (obj.asObject().?.get(first)) |existing| {
                // Conflict detection
                if (self.options.strict) {
                    if (existing == .object and val != .object) {
                        return ToonError.ExpansionConflict;
                    }
                    if (existing != .object and val == .object) {
                        return ToonError.ExpansionConflict;
                    }
                }
                // LWW in non-strict mode
            }
            const key_copy = self.allocator.dupe(u8, first) catch return ToonError.OutOfMemory;
            const val_copy = try val.clone(self.allocator);
            obj.asObject().?.put(key_copy, val_copy) catch return ToonError.OutOfMemory;
        } else {
            // Need to recurse
            if (obj.asObject().?.getPtr(first)) |existing| {
                if (existing.* == .object) {
                    try self.setNestedValue(existing, rest, val);
                } else {
                    if (self.options.strict) {
                        return ToonError.ExpansionConflict;
                    }
                    // LWW: replace with object
                    existing.deinit(self.allocator);
                    existing.* = JsonValue.initObject(self.allocator);
                    try self.setNestedValue(existing, rest, val);
                }
            } else {
                // Create new nested object
                const key_copy = self.allocator.dupe(u8, first) catch return ToonError.OutOfMemory;
                var nested = JsonValue.initObject(self.allocator);
                try self.setNestedValue(&nested, rest, val);
                obj.asObject().?.put(key_copy, nested) catch return ToonError.OutOfMemory;
            }
        }
    }
};

/// Check if a string is an IdentifierSegment per §1.9.
fn isIdentifierSegment(s: []const u8) bool {
    if (s.len == 0) return false;

    const first = s[0];
    if (!((first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_')) {
        return false;
    }

    for (s[1..]) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_'))
        {
            return false;
        }
    }

    return true;
}

/// Check if content is a ROOT array header (starts with '[' or quoted key + '[').
/// Object field array headers like "tags[3]:" should NOT match - they are object fields.
fn isRootArrayHeader(content: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, content, " ");
    if (trimmed.len == 0) return false;

    // Root array header starts with '[' (no key)
    if (trimmed[0] == '[') {
        const colon = std.mem.indexOf(u8, trimmed, ":") orelse return false;
        _ = colon;
        return true;
    }

    return false;
}

/// Check if content is any array header (root or keyed).
fn isArrayHeader(content: []const u8) bool {
    const bracket = std.mem.indexOf(u8, content, "[") orelse return false;
    const colon = std.mem.indexOf(u8, content, ":") orelse return false;
    return bracket < colon;
}

/// Check if content is a key-value line.
fn isKeyValueLine(content: []const u8) bool {
    return std.mem.indexOf(u8, content, ":") != null;
}

/// Decode a TOON string to JsonValue.
pub fn decode(allocator: Allocator, input: []const u8, options: DecodeOptions) ToonError!JsonValue {
    var dec = try Decoder.init(allocator, input, options);
    defer dec.deinit();

    return dec.decodeRoot();
}

test "decode primitives" {
    const allocator = std.testing.allocator;

    // null
    var null_val = try decode(allocator, "null", .{});
    defer null_val.deinit(allocator);
    try std.testing.expect(null_val.isNull());

    // bool
    var true_val = try decode(allocator, "true", .{});
    defer true_val.deinit(allocator);
    try std.testing.expectEqual(true, true_val.asBool().?);

    // integer
    var int_val = try decode(allocator, "42", .{});
    defer int_val.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 42), int_val.asInteger().?);

    // string
    var str_val = try decode(allocator, "hello", .{});
    defer str_val.deinit(allocator);
    try std.testing.expectEqualStrings("hello", str_val.asString().?);
}

test "decode simple object" {
    const allocator = std.testing.allocator;

    var obj = try decode(allocator, "name: Alice\nage: 30", .{});
    defer obj.deinit(allocator);

    const name = obj.asConstObject().?.get("name").?.asString().?;
    try std.testing.expectEqualStrings("Alice", name);

    const age = obj.asConstObject().?.get("age").?.asInteger().?;
    try std.testing.expectEqual(@as(i64, 30), age);
}

test "decode inline array" {
    const allocator = std.testing.allocator;

    var arr = try decode(allocator, "[3]: 1,2,3", .{});
    defer arr.deinit(allocator);

    const items = arr.asConstArray().?.items;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].asInteger().?);
    try std.testing.expectEqual(@as(i64, 2), items[1].asInteger().?);
    try std.testing.expectEqual(@as(i64, 3), items[2].asInteger().?);
}

test "decode empty document" {
    const allocator = std.testing.allocator;

    var empty = try decode(allocator, "", .{});
    defer empty.deinit(allocator);

    try std.testing.expect(empty == .object);
    try std.testing.expectEqual(@as(usize, 0), empty.asConstObject().?.count());
}

test "isIdentifierSegment" {
    try std.testing.expect(isIdentifierSegment("name"));
    try std.testing.expect(isIdentifierSegment("user_id"));
    try std.testing.expect(isIdentifierSegment("User123"));
    try std.testing.expect(isIdentifierSegment("_private"));
    try std.testing.expect(!isIdentifierSegment("123"));
    try std.testing.expect(!isIdentifierSegment("my-key"));
    try std.testing.expect(!isIdentifierSegment("a.b"));
    try std.testing.expect(!isIdentifierSegment(""));
}
