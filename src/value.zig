
const std = @import("std");
const Allocator = std.mem.Allocator;
const ToonError = @import("error.zig").ToonError;

pub const JsonArray = std.ArrayList(JsonValue);

pub const JsonObject = std.StringArrayHashMap(JsonValue);

pub const JsonValue = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    string: []const u8,
    array: JsonArray,
    object: JsonObject,

    pub fn initNull() JsonValue {
        return .null;
    }

    pub fn initBool(b: bool) JsonValue {
        return .{ .bool = b };
    }

    pub fn initInteger(i: i64) JsonValue {
        return .{ .integer = i };
    }

    pub fn initFloat(f: f64) JsonValue {
        return .{ .float = f };
    }

    pub fn initString(s: []const u8) JsonValue {
        return .{ .string = s };
    }

    pub fn initStringCopy(allocator: Allocator, s: []const u8) ToonError!JsonValue {
        const copy = allocator.dupe(u8, s) catch return ToonError.OutOfMemory;
        return .{ .string = copy };
    }

    pub fn initArray(allocator: Allocator) JsonValue {
        return .{ .array = JsonArray.init(allocator) };
    }

    pub fn initObject(allocator: Allocator) JsonValue {
        return .{ .object = JsonObject.init(allocator) };
    }

    pub fn clone(self: JsonValue, allocator: Allocator) ToonError!JsonValue {
        return switch (self) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| blk: {
                const copy = allocator.dupe(u8, s) catch return ToonError.OutOfMemory;
                break :blk .{ .string = copy };
            },
            .array => |arr| blk: {
                var new_arr = JsonArray.init(allocator);
                new_arr.ensureTotalCapacity(arr.items.len) catch return ToonError.OutOfMemory;
                for (arr.items) |item| {
                    const cloned = try item.clone(allocator);
                    new_arr.append(cloned) catch return ToonError.OutOfMemory;
                }
                break :blk .{ .array = new_arr };
            },
            .object => |obj| blk: {
                var new_obj = JsonObject.init(allocator);
                new_obj.ensureTotalCapacity(obj.count()) catch return ToonError.OutOfMemory;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch return ToonError.OutOfMemory;
                    const val_copy = try entry.value_ptr.clone(allocator);
                    new_obj.put(key_copy, val_copy) catch return ToonError.OutOfMemory;
                }
                break :blk .{ .object = new_obj };
            },
        };
    }

    pub fn deinit(self: *JsonValue, allocator: Allocator) void {
        switch (self.*) {
            .null, .bool, .integer, .float => {},
            .string => |s| {
                allocator.free(s);
            },
            .array => |*arr| {
                for (arr.items) |*item| {
                    item.deinit(allocator);
                }
                arr.deinit();
            },
            .object => |*obj| {
                var it = obj.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                obj.deinit();
            },
        }
        self.* = .null;
    }

    pub fn isPrimitive(self: JsonValue) bool {
        return switch (self) {
            .null, .bool, .integer, .float, .string => true,
            .array, .object => false,
        };
    }

    pub fn isNull(self: JsonValue) bool {
        return self == .null;
    }

    pub fn isNumber(self: JsonValue) bool {
        return switch (self) {
            .integer, .float => true,
            else => false,
        };
    }

    pub fn asBool(self: JsonValue) ?bool {
        return switch (self) {
            .bool => |b| b,
            else => null,
        };
    }

    pub fn asString(self: JsonValue) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInteger(self: JsonValue) ?i64 {
        return switch (self) {
            .integer => |i| i,
            else => null,
        };
    }

    pub fn asFloat(self: JsonValue) ?f64 {
        return switch (self) {
            .float => |f| f,
            .integer => |i| @floatFromInt(i),
            else => null,
        };
    }

    pub fn asArray(self: *JsonValue) ?*JsonArray {
        return switch (self.*) {
            .array => |*arr| arr,
            else => null,
        };
    }

    pub fn asObject(self: *JsonValue) ?*JsonObject {
        return switch (self.*) {
            .object => |*obj| obj,
            else => null,
        };
    }

    pub fn asConstArray(self: JsonValue) ?JsonArray {
        return switch (self) {
            .array => |arr| arr,
            else => null,
        };
    }

    pub fn asConstObject(self: JsonValue) ?JsonObject {
        return switch (self) {
            .object => |obj| obj,
            else => null,
        };
    }

    pub fn eql(self: JsonValue, other: JsonValue) bool {
        const Tag = @typeInfo(JsonValue).@"union".tag_type.?;
        const self_tag: Tag = self;
        const other_tag: Tag = other;

        if (self_tag != other_tag) {
            // Special case: integer vs float comparison
            if (self == .integer and other == .float) {
                const self_f: f64 = @floatFromInt(self.integer);
                return self_f == other.float;
            }
            if (self == .float and other == .integer) {
                const other_f: f64 = @floatFromInt(other.integer);
                return self.float == other_f;
            }
            return false;
        }

        return switch (self) {
            .null => true,
            .bool => |b| b == other.bool,
            .integer => |i| i == other.integer,
            .float => |f| f == other.float,
            .string => |s| std.mem.eql(u8, s, other.string),
            .array => |arr| {
                const other_arr = other.array;
                if (arr.items.len != other_arr.items.len) return false;
                for (arr.items, other_arr.items) |a, b| {
                    if (!a.eql(b)) return false;
                }
                return true;
            },
            .object => |obj| {
                const other_obj = other.object;
                if (obj.count() != other_obj.count()) return false;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const other_val = other_obj.get(entry.key_ptr.*) orelse return false;
                    if (!entry.value_ptr.eql(other_val)) return false;
                }
                return true;
            },
        };
    }

    pub fn parseJson(allocator: Allocator, json_str: []const u8) ToonError!JsonValue {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
            return ToonError.InvalidInput;
        };
        defer parsed.deinit();

        return fromStdJson(allocator, parsed.value);
    }

    pub fn fromStdJson(allocator: Allocator, val: std.json.Value) ToonError!JsonValue {
        return switch (val) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| blk: {
                const copy = allocator.dupe(u8, s) catch return ToonError.OutOfMemory;
                break :blk .{ .string = copy };
            },
            .array => |arr| blk: {
                var new_arr = JsonArray.init(allocator);
                new_arr.ensureTotalCapacity(arr.items.len) catch return ToonError.OutOfMemory;
                for (arr.items) |item| {
                    const converted = try fromStdJson(allocator, item);
                    new_arr.append(converted) catch return ToonError.OutOfMemory;
                }
                break :blk .{ .array = new_arr };
            },
            .object => |obj| blk: {
                var new_obj = JsonObject.init(allocator);
                new_obj.ensureTotalCapacity(obj.count()) catch return ToonError.OutOfMemory;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch return ToonError.OutOfMemory;
                    const val_copy = try fromStdJson(allocator, entry.value_ptr.*);
                    new_obj.put(key_copy, val_copy) catch return ToonError.OutOfMemory;
                }
                break :blk .{ .object = new_obj };
            },
            .number_string => |s| blk: {
                // Try parsing as integer first, then float
                if (std.fmt.parseInt(i64, s, 10)) |i| {
                    break :blk .{ .integer = i };
                } else |_| {}
                if (std.fmt.parseFloat(f64, s)) |f| {
                    break :blk .{ .float = f };
                } else |_| {}
                // Fall back to string
                const copy = allocator.dupe(u8, s) catch return ToonError.OutOfMemory;
                break :blk .{ .string = copy };
            },
        };
    }

    pub fn toStdJson(self: JsonValue, allocator: Allocator) ToonError!std.json.Value {
        return switch (self) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .integer = i },
            .float => |f| .{ .float = f },
            .string => |s| blk: {
                const copy = allocator.dupe(u8, s) catch return ToonError.OutOfMemory;
                break :blk .{ .string = copy };
            },
            .array => |arr| blk: {
                var new_arr = std.json.Array.init(allocator);
                new_arr.ensureTotalCapacity(arr.items.len) catch return ToonError.OutOfMemory;
                for (arr.items) |item| {
                    const converted = try item.toStdJson(allocator);
                    new_arr.append(converted) catch return ToonError.OutOfMemory;
                }
                break :blk .{ .array = new_arr };
            },
            .object => |obj| blk: {
                var new_obj = std.json.ObjectMap.init(allocator);
                new_obj.ensureTotalCapacity(obj.count()) catch return ToonError.OutOfMemory;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    const key_copy = allocator.dupe(u8, entry.key_ptr.*) catch return ToonError.OutOfMemory;
                    const val_copy = try entry.value_ptr.toStdJson(allocator);
                    new_obj.put(key_copy, val_copy) catch return ToonError.OutOfMemory;
                }
                break :blk .{ .object = new_obj };
            },
        };
    }

    pub fn toJsonString(self: JsonValue, allocator: Allocator) ToonError![]u8 {
        var list = std.ArrayList(u8).init(allocator);
        errdefer list.deinit();
        self.writeJson(list.writer()) catch return ToonError.OutOfMemory;
        return list.toOwnedSlice() catch return ToonError.OutOfMemory;
    }

    pub fn writeJson(self: JsonValue, writer: anytype) !void {
        switch (self) {
            .null => try writer.writeAll("null"),
            .bool => |b| try writer.writeAll(if (b) "true" else "false"),
            .integer => |i| try writer.print("{d}", .{i}),
            .float => |f| {
                if (std.math.isNan(f) or std.math.isInf(f)) {
                    try writer.writeAll("null");
                } else {
                    try writer.print("{d}", .{f});
                }
            },
            .string => |s| {
                try writer.writeByte('"');
                for (s) |c| {
                    switch (c) {
                        '"' => try writer.writeAll("\\\""),
                        '\\' => try writer.writeAll("\\\\"),
                        '\n' => try writer.writeAll("\\n"),
                        '\r' => try writer.writeAll("\\r"),
                        '\t' => try writer.writeAll("\\t"),
                        else => {
                            if (c < 0x20) {
                                try writer.print("\\u{x:0>4}", .{c});
                            } else {
                                try writer.writeByte(c);
                            }
                        },
                    }
                }
                try writer.writeByte('"');
            },
            .array => |arr| {
                try writer.writeByte('[');
                for (arr.items, 0..) |item, i| {
                    if (i > 0) try writer.writeByte(',');
                    try item.writeJson(writer);
                }
                try writer.writeByte(']');
            },
            .object => |obj| {
                try writer.writeByte('{');
                var first = true;
                var it = obj.iterator();
                while (it.next()) |entry| {
                    if (!first) try writer.writeByte(',');
                    first = false;
                    try writer.writeByte('"');
                    for (entry.key_ptr.*) |c| {
                        switch (c) {
                            '"' => try writer.writeAll("\\\""),
                            '\\' => try writer.writeAll("\\\\"),
                            '\n' => try writer.writeAll("\\n"),
                            '\r' => try writer.writeAll("\\r"),
                            '\t' => try writer.writeAll("\\t"),
                            else => try writer.writeByte(c),
                        }
                    }
                    try writer.writeAll("\":");
                    try entry.value_ptr.writeJson(writer);
                }
                try writer.writeByte('}');
            },
        }
    }
};

test "JsonValue basic operations" {
    const allocator = std.testing.allocator;

    // Test primitives
    const null_val = JsonValue.initNull();
    try std.testing.expect(null_val.isNull());
    try std.testing.expect(null_val.isPrimitive());

    const bool_val = JsonValue.initBool(true);
    try std.testing.expectEqual(true, bool_val.asBool().?);

    const int_val = JsonValue.initInteger(42);
    try std.testing.expectEqual(@as(i64, 42), int_val.asInteger().?);

    const float_val = JsonValue.initFloat(3.14);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), float_val.asFloat().?, 0.001);

    // Test string with copy
    var str_val = try JsonValue.initStringCopy(allocator, "hello");
    defer str_val.deinit(allocator);
    try std.testing.expectEqualStrings("hello", str_val.asString().?);

    // Test array
    var arr_val = JsonValue.initArray(allocator);
    defer arr_val.deinit(allocator);
    try arr_val.asArray().?.append(JsonValue.initInteger(1));
    try arr_val.asArray().?.append(JsonValue.initInteger(2));
    try std.testing.expectEqual(@as(usize, 2), arr_val.asConstArray().?.items.len);

    // Test object
    var obj_val = JsonValue.initObject(allocator);
    defer obj_val.deinit(allocator);
    const key = try allocator.dupe(u8, "name");
    const val = try JsonValue.initStringCopy(allocator, "test");
    try obj_val.asObject().?.put(key, val);
    try std.testing.expectEqual(@as(usize, 1), obj_val.asConstObject().?.count());
}

test "JsonValue clone and equality" {
    const allocator = std.testing.allocator;

    var original = JsonValue.initObject(allocator);
    defer original.deinit(allocator);

    const key1 = try allocator.dupe(u8, "name");
    const val1 = try JsonValue.initStringCopy(allocator, "Alice");
    try original.asObject().?.put(key1, val1);

    const key2 = try allocator.dupe(u8, "age");
    try original.asObject().?.put(key2, JsonValue.initInteger(30));

    var cloned = try original.clone(allocator);
    defer cloned.deinit(allocator);

    try std.testing.expect(original.eql(cloned));
}
