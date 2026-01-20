//! TOON Encoder - JSON to TOON conversion.
//!
//! Implements the encoding rules per TOON specification v3.0.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ToonError = @import("error.zig").ToonError;
const value_mod = @import("value.zig");
const JsonValue = value_mod.JsonValue;
const JsonObject = value_mod.JsonObject;
const JsonArray = value_mod.JsonArray;
const escape = @import("escape.zig");
const number = @import("number.zig");

/// Delimiter options for TOON encoding.
pub const Delimiter = enum {
    comma,
    tab,
    pipe,

    pub fn char(self: Delimiter) u8 {
        return switch (self) {
            .comma => ',',
            .tab => '\t',
            .pipe => '|',
        };
    }

    pub fn headerSuffix(self: Delimiter) []const u8 {
        return switch (self) {
            .comma => "",
            .tab => "\t",
            .pipe => "|",
        };
    }

    pub fn fromChar(c: u8) ?Delimiter {
        return switch (c) {
            ',' => .comma,
            '\t' => .tab,
            '|' => .pipe,
            else => null,
        };
    }
};

/// Key folding mode per §13.4.
pub const KeyFoldingMode = enum {
    off,
    safe,
};

/// Encoder options.
pub const EncodeOptions = struct {
    /// Number of spaces per indentation level (default: 2).
    indent: usize = 2,
    /// Document delimiter (default: comma).
    delimiter: Delimiter = .comma,
    /// Key folding mode (default: off).
    key_folding: KeyFoldingMode = .off,
    /// Maximum depth for key folding (default: max).
    flatten_depth: usize = std.math.maxInt(usize),
};

/// Encoder state.
const Encoder = struct {
    allocator: Allocator,
    options: EncodeOptions,
    output: std.ArrayList(u8),
    current_depth: usize,
    active_delimiter: Delimiter,

    fn init(allocator: Allocator, options: EncodeOptions) Encoder {
        return .{
            .allocator = allocator,
            .options = options,
            .output = std.ArrayList(u8).init(allocator),
            .current_depth = 0,
            .active_delimiter = options.delimiter,
        };
    }

    fn deinit(self: *Encoder) void {
        self.output.deinit();
    }

    fn writeIndent(self: *Encoder) ToonError!void {
        const spaces = self.current_depth * self.options.indent;
        for (0..spaces) |_| {
            self.output.append(' ') catch return ToonError.OutOfMemory;
        }
    }

    fn writeByte(self: *Encoder, byte: u8) ToonError!void {
        self.output.append(byte) catch return ToonError.OutOfMemory;
    }

    fn writeSlice(self: *Encoder, slice: []const u8) ToonError!void {
        self.output.appendSlice(slice) catch return ToonError.OutOfMemory;
    }

    fn writeNewline(self: *Encoder) ToonError!void {
        self.output.append('\n') catch return ToonError.OutOfMemory;
    }

    /// Encode a primitive value as a string token.
    fn encodePrimitiveToken(self: *Encoder, val: JsonValue) ToonError!void {
        switch (val) {
            .null => try self.writeSlice("null"),
            .bool => |b| try self.writeSlice(if (b) "true" else "false"),
            .integer => |i| {
                const formatted = try number.formatInteger(self.allocator, i);
                defer self.allocator.free(formatted);
                try self.writeSlice(formatted);
            },
            .float => |f| {
                const formatted = try number.formatFloat(self.allocator, f);
                defer self.allocator.free(formatted);
                try self.writeSlice(formatted);
            },
            .string => |s| {
                if (self.needsQuoting(s)) {
                    try self.writeByte('"');
                    const escaped = try escape.escapeString(self.allocator, s);
                    defer self.allocator.free(escaped);
                    try self.writeSlice(escaped);
                    try self.writeByte('"');
                } else {
                    try self.writeSlice(s);
                }
            },
            .array, .object => return ToonError.InvalidInput,
        }
    }

    /// Check if a string value needs quoting per §7.2.
    fn needsQuoting(self: *Encoder, s: []const u8) bool {
        return needsQuotingWithDelimiter(s, self.active_delimiter);
    }

    /// Encode a key per §7.3.
    fn encodeKey(self: *Encoder, key: []const u8) ToonError!void {
        if (isValidUnquotedKey(key)) {
            try self.writeSlice(key);
        } else {
            try self.writeByte('"');
            const escaped = try escape.escapeString(self.allocator, key);
            defer self.allocator.free(escaped);
            try self.writeSlice(escaped);
            try self.writeByte('"');
        }
    }

    /// Encode the root value.
    fn encodeRoot(self: *Encoder, val: JsonValue) ToonError!void {
        switch (val) {
            .null, .bool, .integer, .float, .string => {
                // Single primitive at root
                try self.encodePrimitiveToken(val);
            },
            .array => |arr| {
                // Root array
                try self.encodeRootArray(arr);
            },
            .object => |obj| {
                // Root object (empty produces empty output)
                try self.encodeObject(obj, null);
            },
        }
    }

    /// Encode a root-level array.
    fn encodeRootArray(self: *Encoder, arr: JsonArray) ToonError!void {
        if (arr.items.len == 0) {
            // Empty root array: [0]:
            try self.writeSlice("[0");
            try self.writeSlice(self.options.delimiter.headerSuffix());
            try self.writeSlice("]:");
            return;
        }

        // Detect array form
        const form = detectArrayForm(arr);

        switch (form) {
            .primitive_inline => try self.encodePrimitiveArrayInline(arr, null),
            .tabular => try self.encodeTabularArray(arr, null),
            .array_of_arrays => try self.encodeArrayOfArrays(arr, null),
            .mixed_expanded => try self.encodeMixedArray(arr, null),
        }
    }

    /// Encode an object.
    fn encodeObject(self: *Encoder, obj: JsonObject, first_on_hyphen: ?bool) ToonError!void {
        const is_first_on_hyphen = first_on_hyphen orelse false;
        var first = true;

        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            if (first and is_first_on_hyphen) {
                // First field on hyphen line - already indented, no newline needed
            } else if (first) {
                // First field at root or nested - just indent, no newline
                try self.writeIndent();
            } else {
                // Subsequent fields - newline then indent
                try self.writeNewline();
                try self.writeIndent();
            }

            switch (val) {
                .null, .bool, .integer, .float, .string => {
                    try self.encodeKey(key);
                    try self.writeByte(':');
                    try self.writeByte(' ');
                    try self.encodePrimitiveToken(val);
                },
                .object => |nested_obj| {
                    try self.encodeKey(key);
                    try self.writeByte(':');
                    if (nested_obj.count() == 0) {
                        // Empty object - just the colon
                    } else {
                        // Nested object content starts on next line
                        self.current_depth += 1;
                        try self.writeNewline();
                        try self.encodeObjectFields(nested_obj);
                        self.current_depth -= 1;
                    }
                },
                .array => |nested_arr| {
                    // For arrays, key is part of the header: key[N]:
                    try self.encodeKey(key);
                    try self.encodeArrayField(nested_arr);
                },
            }

            first = false;
        }
    }

    /// Encode object fields (for nested objects - starts at current depth).
    fn encodeObjectFields(self: *Encoder, obj: JsonObject) ToonError!void {
        var first = true;

        var it = obj.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const val = entry.value_ptr.*;

            if (!first) {
                try self.writeNewline();
            }
            try self.writeIndent();

            switch (val) {
                .null, .bool, .integer, .float, .string => {
                    try self.encodeKey(key);
                    try self.writeByte(':');
                    try self.writeByte(' ');
                    try self.encodePrimitiveToken(val);
                },
                .object => |nested_obj| {
                    try self.encodeKey(key);
                    try self.writeByte(':');
                    if (nested_obj.count() > 0) {
                        self.current_depth += 1;
                        try self.writeNewline();
                        try self.encodeObjectFields(nested_obj);
                        self.current_depth -= 1;
                    }
                },
                .array => |nested_arr| {
                    try self.encodeKey(key);
                    try self.encodeArrayField(nested_arr);
                },
            }

            first = false;
        }
    }

    /// Encode an array as a field value (key already written).
    fn encodeArrayField(self: *Encoder, arr: JsonArray) ToonError!void {
        if (arr.items.len == 0) {
            // Empty array: just header
            try self.writeSlice("[0");
            try self.writeSlice(self.options.delimiter.headerSuffix());
            try self.writeSlice("]:");
            return;
        }

        const form = detectArrayForm(arr);
        const saved_delimiter = self.active_delimiter;
        self.active_delimiter = self.options.delimiter;
        defer self.active_delimiter = saved_delimiter;

        switch (form) {
            .primitive_inline => {
                try self.writeSlice("[");
                try self.writeArrayLength(arr.items.len);
                try self.writeSlice(self.options.delimiter.headerSuffix());
                try self.writeSlice("]: ");
                try self.encodePrimitiveValues(arr);
            },
            .tabular => {
                const fields = try self.getTabularFields(arr);
                defer self.allocator.free(fields);

                try self.writeSlice("[");
                try self.writeArrayLength(arr.items.len);
                try self.writeSlice(self.options.delimiter.headerSuffix());
                try self.writeSlice("]{");
                try self.writeFieldList(fields);
                try self.writeSlice("}:");

                self.current_depth += 1;
                for (arr.items) |item| {
                    try self.writeNewline();
                    try self.writeIndent();
                    try self.encodeTabularRow(item.object, fields);
                }
                self.current_depth -= 1;
            },
            .array_of_arrays => {
                try self.writeSlice("[");
                try self.writeArrayLength(arr.items.len);
                try self.writeSlice(self.options.delimiter.headerSuffix());
                try self.writeSlice("]:");

                self.current_depth += 1;
                for (arr.items) |item| {
                    try self.writeNewline();
                    try self.writeIndent();
                    try self.writeSlice("- [");
                    try self.writeArrayLength(item.array.items.len);
                    try self.writeSlice(self.options.delimiter.headerSuffix());
                    try self.writeSlice("]: ");
                    try self.encodePrimitiveValues(item.array);
                }
                self.current_depth -= 1;
            },
            .mixed_expanded => {
                try self.writeSlice("[");
                try self.writeArrayLength(arr.items.len);
                try self.writeSlice(self.options.delimiter.headerSuffix());
                try self.writeSlice("]:");

                self.current_depth += 1;
                for (arr.items) |item| {
                    try self.writeNewline();
                    try self.writeIndent();
                    try self.encodeListItem(item);
                }
                self.current_depth -= 1;
            },
        }
    }

    /// Encode a primitive inline array.
    fn encodePrimitiveArrayInline(self: *Encoder, arr: JsonArray, key: ?[]const u8) ToonError!void {
        if (key) |k| {
            try self.encodeKey(k);
        }
        try self.writeSlice("[");
        try self.writeArrayLength(arr.items.len);
        try self.writeSlice(self.options.delimiter.headerSuffix());
        try self.writeSlice("]: ");
        try self.encodePrimitiveValues(arr);
    }

    /// Encode a tabular array.
    fn encodeTabularArray(self: *Encoder, arr: JsonArray, key: ?[]const u8) ToonError!void {
        const fields = try self.getTabularFields(arr);
        defer self.allocator.free(fields);

        if (key) |k| {
            try self.encodeKey(k);
        }
        try self.writeSlice("[");
        try self.writeArrayLength(arr.items.len);
        try self.writeSlice(self.options.delimiter.headerSuffix());
        try self.writeSlice("]{");
        try self.writeFieldList(fields);
        try self.writeSlice("}:");

        self.current_depth += 1;
        for (arr.items) |item| {
            try self.writeNewline();
            try self.writeIndent();
            try self.encodeTabularRow(item.object, fields);
        }
        self.current_depth -= 1;
    }

    /// Encode an array of arrays.
    fn encodeArrayOfArrays(self: *Encoder, arr: JsonArray, key: ?[]const u8) ToonError!void {
        if (key) |k| {
            try self.encodeKey(k);
        }
        try self.writeSlice("[");
        try self.writeArrayLength(arr.items.len);
        try self.writeSlice(self.options.delimiter.headerSuffix());
        try self.writeSlice("]:");

        self.current_depth += 1;
        for (arr.items) |item| {
            try self.writeNewline();
            try self.writeIndent();
            try self.writeSlice("- [");
            try self.writeArrayLength(item.array.items.len);
            try self.writeSlice(self.options.delimiter.headerSuffix());
            try self.writeSlice("]:");
            if (item.array.items.len > 0) {
                try self.writeByte(' ');
                try self.encodePrimitiveValues(item.array);
            }
        }
        self.current_depth -= 1;
    }

    /// Encode a mixed/non-uniform array.
    fn encodeMixedArray(self: *Encoder, arr: JsonArray, key: ?[]const u8) ToonError!void {
        if (key) |k| {
            try self.encodeKey(k);
        }
        try self.writeSlice("[");
        try self.writeArrayLength(arr.items.len);
        try self.writeSlice(self.options.delimiter.headerSuffix());
        try self.writeSlice("]:");

        self.current_depth += 1;
        for (arr.items) |item| {
            try self.writeNewline();
            try self.writeIndent();
            try self.encodeListItem(item);
        }
        self.current_depth -= 1;
    }

    /// Encode a list item.
    fn encodeListItem(self: *Encoder, item: JsonValue) ToonError!void {
        switch (item) {
            .null, .bool, .integer, .float, .string => {
                try self.writeSlice("- ");
                try self.encodePrimitiveToken(item);
            },
            .array => |arr| {
                try self.writeSlice("- [");
                try self.writeArrayLength(arr.items.len);
                try self.writeSlice(self.options.delimiter.headerSuffix());
                try self.writeSlice("]:");
                if (arr.items.len > 0) {
                    const form = detectArrayForm(arr);
                    if (form == .primitive_inline) {
                        try self.writeByte(' ');
                        try self.encodePrimitiveValues(arr);
                    } else {
                        self.current_depth += 1;
                        for (arr.items) |sub_item| {
                            try self.writeNewline();
                            try self.writeIndent();
                            try self.encodeListItem(sub_item);
                        }
                        self.current_depth -= 1;
                    }
                }
            },
            .object => |obj| {
                if (obj.count() == 0) {
                    try self.writeByte('-');
                } else {
                    try self.writeSlice("- ");
                    // Check if first field is tabular array
                    var it = obj.iterator();
                    if (it.next()) |first_entry| {
                        const first_key = first_entry.key_ptr.*;
                        const first_val = first_entry.value_ptr.*;

                        if (first_val == .array and isTabularArray(first_val.array)) {
                            // First field is tabular - special handling per §10
                            try self.encodeKey(first_key);
                            const tab_arr = first_val.array;
                            const fields = try self.getTabularFields(tab_arr);
                            defer self.allocator.free(fields);

                            try self.writeSlice("[");
                            try self.writeArrayLength(tab_arr.items.len);
                            try self.writeSlice(self.options.delimiter.headerSuffix());
                            try self.writeSlice("]{");
                            try self.writeFieldList(fields);
                            try self.writeSlice("}:");

                            // Rows at depth +2
                            self.current_depth += 2;
                            for (tab_arr.items) |row| {
                                try self.writeNewline();
                                try self.writeIndent();
                                try self.encodeTabularRow(row.object, fields);
                            }
                            self.current_depth -= 2;

                            // Remaining fields at depth +1
                            self.current_depth += 1;
                            while (it.next()) |entry| {
                                try self.writeNewline();
                                try self.writeIndent();
                                try self.encodeKey(entry.key_ptr.*);

                                const val = entry.value_ptr.*;
                                switch (val) {
                                    .null, .bool, .integer, .float, .string => {
                                        try self.writeByte(':');
                                        try self.writeByte(' ');
                                        try self.encodePrimitiveToken(val);
                                    },
                                    .object => |nested| {
                                        try self.writeByte(':');
                                        if (nested.count() > 0) {
                                            self.current_depth += 1;
                                            try self.encodeObject(nested, false);
                                            self.current_depth -= 1;
                                        }
                                    },
                                    .array => |nested_arr| {
                                        try self.encodeArrayField(nested_arr);
                                    },
                                }
                            }
                            self.current_depth -= 1;
                        } else {
                            // First field on hyphen line
                            try self.encodeKey(first_key);

                            switch (first_val) {
                                .null, .bool, .integer, .float, .string => {
                                    try self.writeByte(':');
                                    try self.writeByte(' ');
                                    try self.encodePrimitiveToken(first_val);
                                },
                                .object => |nested| {
                                    try self.writeByte(':');
                                    if (nested.count() > 0) {
                                        self.current_depth += 2;
                                        try self.encodeObject(nested, false);
                                        self.current_depth -= 2;
                                    }
                                },
                                .array => |nested_arr| {
                                    try self.encodeArrayField(nested_arr);
                                },
                            }

                            // Remaining fields at depth +1
                            self.current_depth += 1;
                            while (it.next()) |entry| {
                                try self.writeNewline();
                                try self.writeIndent();
                                try self.encodeKey(entry.key_ptr.*);

                                const val = entry.value_ptr.*;
                                switch (val) {
                                    .null, .bool, .integer, .float, .string => {
                                        try self.writeByte(':');
                                        try self.writeByte(' ');
                                        try self.encodePrimitiveToken(val);
                                    },
                                    .object => |nested| {
                                        try self.writeByte(':');
                                        if (nested.count() > 0) {
                                            self.current_depth += 1;
                                            try self.encodeObject(nested, false);
                                            self.current_depth -= 1;
                                        }
                                    },
                                    .array => |nested_arr| {
                                        try self.encodeArrayField(nested_arr);
                                    },
                                }
                            }
                            self.current_depth -= 1;
                        }
                    }
                }
            },
        }
    }

    /// Encode primitive values separated by delimiter.
    fn encodePrimitiveValues(self: *Encoder, arr: JsonArray) ToonError!void {
        for (arr.items, 0..) |item, i| {
            if (i > 0) {
                try self.writeByte(self.options.delimiter.char());
            }
            try self.encodePrimitiveToken(item);
        }
    }

    /// Encode a tabular row.
    fn encodeTabularRow(self: *Encoder, obj: JsonObject, fields: []const []const u8) ToonError!void {
        for (fields, 0..) |field, i| {
            if (i > 0) {
                try self.writeByte(self.options.delimiter.char());
            }
            if (obj.get(field)) |val| {
                try self.encodePrimitiveToken(val);
            } else {
                try self.writeSlice("null");
            }
        }
    }

    /// Write array length.
    fn writeArrayLength(self: *Encoder, len: usize) ToonError!void {
        var buf: [20]u8 = undefined;
        const slice = std.fmt.bufPrint(&buf, "{d}", .{len}) catch return ToonError.Overflow;
        try self.writeSlice(slice);
    }

    /// Write field list.
    fn writeFieldList(self: *Encoder, fields: []const []const u8) ToonError!void {
        for (fields, 0..) |field, i| {
            if (i > 0) {
                try self.writeByte(self.options.delimiter.char());
            }
            try self.encodeKey(field);
        }
    }

    /// Get field names for tabular array (from first object).
    fn getTabularFields(self: *Encoder, arr: JsonArray) ToonError![][]const u8 {
        if (arr.items.len == 0) return &[_][]const u8{};

        const first = arr.items[0];
        if (first != .object) return ToonError.InvalidInput;

        const obj = first.object;
        var fields = self.allocator.alloc([]const u8, obj.count()) catch return ToonError.OutOfMemory;

        var i: usize = 0;
        var it = obj.iterator();
        while (it.next()) |entry| {
            fields[i] = entry.key_ptr.*;
            i += 1;
        }

        return fields;
    }

    fn getResult(self: *Encoder) ToonError![]u8 {
        return self.output.toOwnedSlice() catch return ToonError.OutOfMemory;
    }
};

/// Array form detection.
const ArrayForm = enum {
    primitive_inline,
    tabular,
    array_of_arrays,
    mixed_expanded,
};

/// Detect the appropriate encoding form for an array.
fn detectArrayForm(arr: JsonArray) ArrayForm {
    if (arr.items.len == 0) return .primitive_inline;

    // Check if all primitives
    var all_primitives = true;
    var all_arrays = true;
    var all_primitive_arrays = true;
    var all_objects = true;

    for (arr.items) |item| {
        switch (item) {
            .null, .bool, .integer, .float, .string => {
                all_arrays = false;
                all_objects = false;
            },
            .array => |sub_arr| {
                all_primitives = false;
                all_objects = false;
                // Check if inner array is all primitives
                for (sub_arr.items) |sub_item| {
                    if (!sub_item.isPrimitive()) {
                        all_primitive_arrays = false;
                        break;
                    }
                }
            },
            .object => {
                all_primitives = false;
                all_arrays = false;
            },
        }
    }

    if (all_primitives) return .primitive_inline;
    if (all_arrays and all_primitive_arrays) return .array_of_arrays;
    if (all_objects and isTabularArray(arr)) return .tabular;
    return .mixed_expanded;
}

/// Check if an array qualifies for tabular encoding per §9.3.
fn isTabularArray(arr: JsonArray) bool {
    if (arr.items.len == 0) return false;

    // All elements must be objects
    for (arr.items) |item| {
        if (item != .object) return false;
    }

    // Get keys from first object
    const first_obj = arr.items[0].object;
    if (first_obj.count() == 0) return false;

    // All values in first object must be primitives
    var it = first_obj.iterator();
    while (it.next()) |entry| {
        if (!entry.value_ptr.isPrimitive()) return false;
    }

    // All objects must have the same keys
    for (arr.items[1..]) |item| {
        const obj = item.object;
        if (obj.count() != first_obj.count()) return false;

        var key_it = first_obj.iterator();
        while (key_it.next()) |entry| {
            const val = obj.get(entry.key_ptr.*) orelse return false;
            if (!val.isPrimitive()) return false;
        }
    }

    return true;
}

/// Check if a string needs quoting with a given delimiter.
pub fn needsQuotingWithDelimiter(s: []const u8, delimiter: Delimiter) bool {
    // Empty string
    if (s.len == 0) return true;

    // Leading/trailing whitespace
    if (s[0] == ' ' or s[0] == '\t' or s[s.len - 1] == ' ' or s[s.len - 1] == '\t') {
        return true;
    }

    // Equals reserved words
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) {
        return true;
    }

    // Numeric-like
    if (number.looksLikeNumber(s)) return true;

    // Starts with hyphen
    if (s[0] == '-') return true;

    // Contains special characters
    for (s) |c| {
        switch (c) {
            ':', '"', '\\', '[', ']', '{', '}', '\n', '\r', '\t' => return true,
            else => {},
        }
        if (c == delimiter.char()) return true;
    }

    return false;
}

/// Check if a key can be unquoted per §7.3.
/// Pattern: ^[A-Za-z_][A-Za-z0-9_.]*$
pub fn isValidUnquotedKey(key: []const u8) bool {
    if (key.len == 0) return false;

    const first = key[0];
    if (!((first >= 'A' and first <= 'Z') or (first >= 'a' and first <= 'z') or first == '_')) {
        return false;
    }

    for (key[1..]) |c| {
        if (!((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '_' or c == '.'))
        {
            return false;
        }
    }

    return true;
}

/// Encode a JsonValue to TOON format.
pub fn encode(allocator: Allocator, val: JsonValue, options: EncodeOptions) ToonError![]u8 {
    var enc = Encoder.init(allocator, options);
    errdefer enc.deinit();

    try enc.encodeRoot(val);

    return enc.getResult();
}

test "encode primitives" {
    const allocator = std.testing.allocator;

    // null
    const null_result = try encode(allocator, JsonValue.initNull(), .{});
    defer allocator.free(null_result);
    try std.testing.expectEqualStrings("null", null_result);

    // bool
    const true_result = try encode(allocator, JsonValue.initBool(true), .{});
    defer allocator.free(true_result);
    try std.testing.expectEqualStrings("true", true_result);

    // integer
    const int_result = try encode(allocator, JsonValue.initInteger(42), .{});
    defer allocator.free(int_result);
    try std.testing.expectEqualStrings("42", int_result);

    // string (no quoting needed)
    const str_result = try encode(allocator, JsonValue.initString("hello"), .{});
    defer allocator.free(str_result);
    try std.testing.expectEqualStrings("hello", str_result);

    // string (needs quoting - reserved word)
    const true_str = try encode(allocator, JsonValue.initString("true"), .{});
    defer allocator.free(true_str);
    try std.testing.expectEqualStrings("\"true\"", true_str);
}

test "encode simple object" {
    const allocator = std.testing.allocator;

    var obj = JsonValue.initObject(allocator);
    defer obj.deinit(allocator);

    const key1 = try allocator.dupe(u8, "name");
    const val1 = try JsonValue.initStringCopy(allocator, "Alice");
    try obj.asObject().?.put(key1, val1);

    const key2 = try allocator.dupe(u8, "age");
    try obj.asObject().?.put(key2, JsonValue.initInteger(30));

    const result = try encode(allocator, obj, .{});
    defer allocator.free(result);

    try std.testing.expectEqualStrings("name: Alice\nage: 30", result);
}

test "encode primitive array" {
    const allocator = std.testing.allocator;

    var arr = JsonValue.initArray(allocator);
    defer arr.deinit(allocator);

    try arr.asArray().?.append(JsonValue.initInteger(1));
    try arr.asArray().?.append(JsonValue.initInteger(2));
    try arr.asArray().?.append(JsonValue.initInteger(3));

    const result = try encode(allocator, arr, .{});
    defer allocator.free(result);

    try std.testing.expectEqualStrings("[3]: 1,2,3", result);
}

test "isValidUnquotedKey" {
    try std.testing.expect(isValidUnquotedKey("name"));
    try std.testing.expect(isValidUnquotedKey("user_id"));
    try std.testing.expect(isValidUnquotedKey("User123"));
    try std.testing.expect(isValidUnquotedKey("a.b.c"));
    try std.testing.expect(!isValidUnquotedKey("123"));
    try std.testing.expect(!isValidUnquotedKey("my-key"));
    try std.testing.expect(!isValidUnquotedKey(""));
    try std.testing.expect(!isValidUnquotedKey("key:value"));
}

test "needsQuotingWithDelimiter" {
    // Empty
    try std.testing.expect(needsQuotingWithDelimiter("", .comma));

    // Reserved
    try std.testing.expect(needsQuotingWithDelimiter("true", .comma));
    try std.testing.expect(needsQuotingWithDelimiter("false", .comma));
    try std.testing.expect(needsQuotingWithDelimiter("null", .comma));

    // Numeric
    try std.testing.expect(needsQuotingWithDelimiter("42", .comma));
    try std.testing.expect(needsQuotingWithDelimiter("3.14", .comma));

    // Contains delimiter
    try std.testing.expect(needsQuotingWithDelimiter("a,b", .comma));
    try std.testing.expect(!needsQuotingWithDelimiter("a,b", .pipe));

    // Safe
    try std.testing.expect(!needsQuotingWithDelimiter("hello", .comma));
    try std.testing.expect(!needsQuotingWithDelimiter("hello world", .comma));
}
