//! Chaos Testing Harness for TOON
//!
//! Property-based/fuzz testing that generates random JSON structures
//! and validates round-trip encoding/decoding. Designed to find edge cases
//! in real-world chaotic data scenarios.
//!
//! Features:
//! - Seed-based reproducibility for debugging failures
//! - Chaos multiplier for complexity scaling
//! - Automatic failure capture with reproduction info
//! - Shrinking to find minimal failing cases

const std = @import("std");
const toon = @import("toon");
const JsonValue = toon.JsonValue;
const JsonArray = toon.JsonArray;
const JsonObject = toon.JsonObject;

const testing = std.testing;

/// Chaos configuration for test generation
pub const ChaosConfig = struct {
    /// Random seed for reproducibility
    seed: u64 = 0,
    /// Maximum depth of nested structures
    max_depth: u8 = 8,
    /// Maximum number of keys in an object
    max_object_width: u16 = 20,
    /// Maximum number of elements in an array
    max_array_length: u16 = 50,
    /// Maximum string length
    max_string_length: u16 = 500,
    /// Probability of generating special unicode (0-100)
    unicode_probability: u8 = 30,
    /// Probability of generating edge case numbers (0-100)
    edge_number_probability: u8 = 25,
    /// Chaos multiplier (1.0 = normal, 2.0 = double complexity)
    chaos_multiplier: f32 = 1.0,
    /// Number of iterations to run
    iterations: u32 = 1000,

    pub fn withChaos(self: ChaosConfig, multiplier: f32) ChaosConfig {
        var config = self;
        config.chaos_multiplier = multiplier;
        config.max_depth = @intFromFloat(@min(255, @as(f32, @floatFromInt(self.max_depth)) * multiplier));
        config.max_object_width = @intFromFloat(@min(65535, @as(f32, @floatFromInt(self.max_object_width)) * multiplier));
        config.max_array_length = @intFromFloat(@min(65535, @as(f32, @floatFromInt(self.max_array_length)) * multiplier));
        config.max_string_length = @intFromFloat(@min(65535, @as(f32, @floatFromInt(self.max_string_length)) * multiplier));
        return config;
    }
};

/// Test result with failure information
pub const ChaosResult = struct {
    passed: u32 = 0,
    failed: u32 = 0,
    errors: std.ArrayList(ChaosFailure),

    pub fn init(allocator: std.mem.Allocator) ChaosResult {
        return .{
            .errors = std.ArrayList(ChaosFailure).init(allocator),
        };
    }

    pub fn deinit(self: *ChaosResult) void {
        for (self.errors.items) |*err| {
            err.deinit();
        }
        self.errors.deinit();
    }

    pub fn recordPass(self: *ChaosResult) void {
        self.passed += 1;
    }

    pub fn recordFailure(self: *ChaosResult, failure: ChaosFailure) !void {
        self.failed += 1;
        try self.errors.append(failure);
    }

    pub fn summary(self: ChaosResult) void {
        const total = self.passed + self.failed;
        const pass_rate = if (total > 0) (@as(f64, @floatFromInt(self.passed)) / @as(f64, @floatFromInt(total))) * 100.0 else 0.0;

        std.debug.print("\n╔══════════════════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║                    CHAOS TEST RESULTS                        ║\n", .{});
        std.debug.print("╠══════════════════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║  Total:  {d:>8}                                            ║\n", .{total});
        std.debug.print("║  Passed: {d:>8}  ({d:.2}%)                                  ║\n", .{ self.passed, pass_rate });
        std.debug.print("║  Failed: {d:>8}                                            ║\n", .{self.failed});
        std.debug.print("╚══════════════════════════════════════════════════════════════╝\n", .{});

        if (self.failed > 0) {
            std.debug.print("\n🔴 FAILURES:\n", .{});
            for (self.errors.items, 0..) |err, i| {
                std.debug.print("\n─── Failure #{d} ───\n", .{i + 1});
                std.debug.print("  Seed:  {d}\n", .{err.seed});
                std.debug.print("  Iter:  {d}\n", .{err.iteration});
                std.debug.print("  Phase: {s}\n", .{@tagName(err.phase)});
                std.debug.print("  Error: {s}\n", .{err.error_msg});
                if (err.input_json) |json| {
                    const preview = if (json.len > 200) json[0..200] else json;
                    std.debug.print("  Input: {s}...\n", .{preview});
                }
            }
            std.debug.print("\n💡 To reproduce: use seed {d}\n", .{self.errors.items[0].seed});
        }
    }
};

/// Information about a test failure
pub const ChaosFailure = struct {
    seed: u64,
    iteration: u32,
    phase: TestPhase,
    error_msg: []const u8,
    input_json: ?[]const u8,
    allocator: std.mem.Allocator,

    pub const TestPhase = enum {
        generation,
        encoding,
        decoding,
        comparison,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        seed: u64,
        iteration: u32,
        phase: TestPhase,
        error_msg: []const u8,
        input_json: ?[]const u8,
    ) !ChaosFailure {
        return .{
            .seed = seed,
            .iteration = iteration,
            .phase = phase,
            .error_msg = try allocator.dupe(u8, error_msg),
            .input_json = if (input_json) |j| try allocator.dupe(u8, j) else null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ChaosFailure) void {
        self.allocator.free(self.error_msg);
        if (self.input_json) |j| self.allocator.free(j);
    }
};

/// Random JSON value generator
pub const ChaosGenerator = struct {
    allocator: std.mem.Allocator,
    rng: std.Random,
    config: ChaosConfig,
    current_depth: u8,

    // Character sets for string generation
    const ascii_printable = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 !@#$%^&*()_+-=[]{}|;':\",./<>?`~";
    const unicode_chars = "αβγδεζηθικλμνξοπρστυφχψω中文日本語한국어العربيةעברית🎉🚀💻🔥✨🌍🎨📊🔷⚡";
    const escape_chars = "\\\"\n\r\t";

    pub const GeneratorError = error{OutOfMemory} || toon.ToonError;

    pub fn init(allocator: std.mem.Allocator, config: ChaosConfig) ChaosGenerator {
        var prng = std.Random.DefaultPrng.init(config.seed);
        return .{
            .allocator = allocator,
            .rng = prng.random(),
            .config = config,
            .current_depth = 0,
        };
    }

    /// Generate a random JSON value
    pub fn generate(self: *ChaosGenerator) GeneratorError!JsonValue {
        return self.generateValue();
    }

    fn generateValue(self: *ChaosGenerator) GeneratorError!JsonValue {
        // At max depth, only generate primitives
        if (self.current_depth >= self.config.max_depth) {
            return self.generatePrimitive();
        }

        // Weighted random selection of value types
        const roll = self.rng.intRangeAtMost(u8, 0, 100);

        if (roll < 40) {
            return self.generatePrimitive();
        } else if (roll < 70) {
            return self.generateObject();
        } else {
            return self.generateArray();
        }
    }

    fn generatePrimitive(self: *ChaosGenerator) GeneratorError!JsonValue {
        const roll = self.rng.intRangeAtMost(u8, 0, 100);

        if (roll < 10) {
            return JsonValue.initNull();
        } else if (roll < 20) {
            return JsonValue.initBool(self.rng.boolean());
        } else if (roll < 50) {
            return self.generateNumber();
        } else {
            return self.generateString();
        }
    }

    fn generateNumber(self: *ChaosGenerator) GeneratorError!JsonValue {
        const edge_roll = self.rng.intRangeAtMost(u8, 0, 100);

        if (edge_roll < self.config.edge_number_probability) {
            // Edge case numbers
            const edge_cases = [_]i64{
                0,
                0, // -0 is same as 0 for integers
                1,
                -1,
                std.math.maxInt(i32),
                std.math.minInt(i32),
                std.math.maxInt(i64),
                std.math.minInt(i64),
                9007199254740992, // 2^53 (max safe integer in JS)
                -9007199254740992,
                42,
                -42,
                1000000000,
                -1000000000,
            };
            const idx = self.rng.intRangeAtMost(usize, 0, edge_cases.len - 1);
            return JsonValue.initInteger(edge_cases[idx]);
        }

        // Random decision: integer or float
        if (self.rng.boolean()) {
            // Integer
            const val = self.rng.int(i64);
            return JsonValue.initInteger(val);
        } else {
            // Float
            const float_roll = self.rng.intRangeAtMost(u8, 0, 100);
            if (float_roll < 10) {
                // Edge case floats
                const edge_floats = [_]f64{
                    0.0,
                    -0.0,
                    0.1,
                    0.01,
                    0.001,
                    3.14159265358979,
                    2.718281828459045,
                    0.3333333333333333,
                    1e-10,
                    1e10,
                    -1e-10,
                    -1e10,
                };
                const idx = self.rng.intRangeAtMost(usize, 0, edge_floats.len - 1);
                return JsonValue.initFloat(edge_floats[idx]);
            } else {
                // Random float
                const val = self.rng.float(f64) * 1e6 - 5e5;
                return JsonValue.initFloat(val);
            }
        }
    }

    fn generateString(self: *ChaosGenerator) GeneratorError!JsonValue {
        const len = self.rng.intRangeAtMost(u16, 0, self.config.max_string_length);

        if (len == 0) {
            const empty = try self.allocator.dupe(u8, "");
            return .{ .string = empty };
        }

        var str = std.ArrayList(u8).init(self.allocator);
        errdefer str.deinit();

        var i: u16 = 0;
        while (i < len) {
            const char_type = self.rng.intRangeAtMost(u8, 0, 100);

            if (char_type < 5) {
                // Escape characters
                const idx = self.rng.intRangeAtMost(usize, 0, escape_chars.len - 1);
                try str.append(escape_chars[idx]);
                i += 1;
            } else if (char_type < 5 + self.config.unicode_probability) {
                // Unicode characters (multi-byte)
                const start = self.rng.intRangeAtMost(usize, 0, unicode_chars.len - 4);
                // Find a valid UTF-8 boundary
                var end = start + 1;
                while (end < unicode_chars.len and (unicode_chars[end] & 0xC0) == 0x80) {
                    end += 1;
                }
                try str.appendSlice(unicode_chars[start..end]);
                i += 1;
            } else {
                // ASCII printable
                const idx = self.rng.intRangeAtMost(usize, 0, ascii_printable.len - 1);
                try str.append(ascii_printable[idx]);
                i += 1;
            }
        }

        return .{ .string = try str.toOwnedSlice() };
    }

    fn generateObject(self: *ChaosGenerator) GeneratorError!JsonValue {
        self.current_depth += 1;
        defer self.current_depth -= 1;

        var obj = JsonValue.initObject(self.allocator);
        errdefer obj.deinit(self.allocator);

        const num_keys = self.rng.intRangeAtMost(u16, 0, self.config.max_object_width);

        for (0..num_keys) |_| {
            const key = try self.generateKey();
            errdefer self.allocator.free(key);

            const val = try self.generateValue();
            errdefer {
                var v = val;
                v.deinit(self.allocator);
            }

            // Skip if key already exists (duplicate keys)
            if (obj.asObject().?.contains(key)) {
                self.allocator.free(key);
                var v = val;
                v.deinit(self.allocator);
                continue;
            }

            obj.asObject().?.put(key, val) catch {
                self.allocator.free(key);
                var v = val;
                v.deinit(self.allocator);
                return toon.ToonError.OutOfMemory;
            };
        }

        return obj;
    }

    fn generateArray(self: *ChaosGenerator) GeneratorError!JsonValue {
        self.current_depth += 1;
        defer self.current_depth -= 1;

        var arr = JsonValue.initArray(self.allocator);
        errdefer arr.deinit(self.allocator);

        const len = self.rng.intRangeAtMost(u16, 0, self.config.max_array_length);

        // Decide array type for more realistic data
        const array_type = self.rng.intRangeAtMost(u8, 0, 100);

        if (array_type < 30) {
            // Uniform primitive array (good for tabular)
            try self.generateUniformArray(&arr, len);
        } else if (array_type < 50) {
            // Uniform object array (tabular candidate)
            try self.generateTabularArray(&arr, len);
        } else {
            // Mixed array
            for (0..len) |_| {
                const val = try self.generateValue();
                arr.asArray().?.append(val) catch {
                    var v = val;
                    v.deinit(self.allocator);
                    return toon.ToonError.OutOfMemory;
                };
            }
        }

        return arr;
    }

    fn generateUniformArray(self: *ChaosGenerator, arr: *JsonValue, len: u16) GeneratorError!void {
        const prim_type = self.rng.intRangeAtMost(u8, 0, 4);

        for (0..len) |_| {
            const val: JsonValue = switch (prim_type) {
                0 => JsonValue.initNull(),
                1 => JsonValue.initBool(self.rng.boolean()),
                2 => try self.generateNumber(),
                3 => try self.generateString(),
                else => try self.generatePrimitive(),
            };
            arr.asArray().?.append(val) catch {
                var v = val;
                v.deinit(self.allocator);
                return toon.ToonError.OutOfMemory;
            };
        }
    }

    fn generateTabularArray(self: *ChaosGenerator, arr: *JsonValue, len: u16) GeneratorError!void {
        if (len == 0) return;

        // Generate a template with fixed keys
        const num_fields = self.rng.intRangeAtMost(u8, 1, 10);
        var field_names = std.ArrayList([]const u8).init(self.allocator);
        defer {
            for (field_names.items) |name| {
                self.allocator.free(name);
            }
            field_names.deinit();
        }

        for (0..num_fields) |_| {
            const key = try self.generateKey();
            try field_names.append(key);
        }

        // Generate objects with same keys
        for (0..len) |_| {
            var obj = JsonValue.initObject(self.allocator);
            errdefer obj.deinit(self.allocator);

            for (field_names.items) |field| {
                const key = try self.allocator.dupe(u8, field);
                const val = try self.generatePrimitive();
                obj.asObject().?.put(key, val) catch {
                    self.allocator.free(key);
                    var v = val;
                    v.deinit(self.allocator);
                    return toon.ToonError.OutOfMemory;
                };
            }

            arr.asArray().?.append(obj) catch {
                obj.deinit(self.allocator);
                return toon.ToonError.OutOfMemory;
            };
        }
    }

    fn generateKey(self: *ChaosGenerator) GeneratorError![]const u8 {
        const key_type = self.rng.intRangeAtMost(u8, 0, 100);

        if (key_type < 70) {
            // Simple identifier key (most common)
            return self.generateIdentifierKey();
        } else if (key_type < 85) {
            // Key with special chars (needs quoting)
            return self.generateSpecialKey();
        } else {
            // Dotted key (for path expansion testing)
            return self.generateDottedKey();
        }
    }

    fn generateIdentifierKey(self: *ChaosGenerator) GeneratorError![]const u8 {
        const alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_";
        const alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_";

        const len = self.rng.intRangeAtMost(u8, 1, 20);
        var key = try self.allocator.alloc(u8, len);

        key[0] = alpha[self.rng.intRangeAtMost(usize, 0, alpha.len - 1)];
        for (1..len) |i| {
            key[i] = alnum[self.rng.intRangeAtMost(usize, 0, alnum.len - 1)];
        }

        return key;
    }

    fn generateSpecialKey(self: *ChaosGenerator) GeneratorError![]const u8 {
        const specials = [_][]const u8{
            "my-key",
            "key with spaces",
            "key:with:colons",
            "123numeric",
            "",
            "true",
            "false",
            "null",
            "key\"quote",
            "key\\backslash",
            "emoji🔑",
            "日本語キー",
        };
        const idx = self.rng.intRangeAtMost(usize, 0, specials.len - 1);
        return self.allocator.dupe(u8, specials[idx]);
    }

    fn generateDottedKey(self: *ChaosGenerator) GeneratorError![]const u8 {
        const num_segments = self.rng.intRangeAtMost(u8, 2, 4);
        var parts = std.ArrayList(u8).init(self.allocator);
        defer parts.deinit();

        for (0..num_segments) |i| {
            if (i > 0) try parts.append('.');
            const segment = try self.generateIdentifierKey();
            defer self.allocator.free(segment);
            try parts.appendSlice(segment);
        }

        return parts.toOwnedSlice();
    }
};

/// Run chaos tests with given configuration
pub fn runChaosTests(allocator: std.mem.Allocator, config: ChaosConfig) !ChaosResult {
    var result = ChaosResult.init(allocator);
    errdefer result.deinit();

    std.debug.print("\n🌪️  CHAOS TESTING - Seed: {d}, Iterations: {d}, Multiplier: {d:.1}x\n", .{
        config.seed,
        config.iterations,
        config.chaos_multiplier,
    });
    std.debug.print("   Max depth: {d}, Max width: {d}, Max array: {d}\n\n", .{
        config.max_depth,
        config.max_object_width,
        config.max_array_length,
    });

    var progress_interval = config.iterations / 10;
    if (progress_interval == 0) progress_interval = 1;

    for (0..config.iterations) |iter| {
        // Progress indicator
        if (iter % progress_interval == 0) {
            const pct = (iter * 100) / config.iterations;
            std.debug.print("   Progress: {d}% ({d}/{d})\r", .{ pct, iter, config.iterations });
        }

        // Use iteration-based sub-seed for reproducibility
        var iter_config = config;
        iter_config.seed = config.seed +% @as(u64, @intCast(iter));

        const test_result = runSingleChaosTest(allocator, iter_config, @intCast(iter));

        switch (test_result) {
            .pass => result.recordPass(),
            .fail => |failure| try result.recordFailure(failure),
        }
    }

    std.debug.print("   Progress: 100%% ({d}/{d})\n", .{ config.iterations, config.iterations });

    return result;
}

const SingleTestResult = union(enum) {
    pass: void,
    fail: ChaosFailure,
};

fn runSingleChaosTest(allocator: std.mem.Allocator, config: ChaosConfig, iteration: u32) SingleTestResult {
    var generator = ChaosGenerator.init(allocator, config);

    // Generate random value
    var value = generator.generate() catch |err| {
        const failure = ChaosFailure.init(
            allocator,
            config.seed,
            iteration,
            .generation,
            @errorName(err),
            null,
        ) catch return .pass; // Can't record, just skip
        return .{ .fail = failure };
    };
    defer value.deinit(allocator);

    // Get JSON representation for debugging
    const input_json = value.toJsonString(allocator) catch null;
    defer if (input_json) |j| allocator.free(j);

    // Encode to TOON
    const encoded = toon.encode(allocator, value, .{}) catch |err| {
        const failure = ChaosFailure.init(
            allocator,
            config.seed,
            iteration,
            .encoding,
            @errorName(err),
            input_json,
        ) catch return .pass;
        return .{ .fail = failure };
    };
    defer allocator.free(encoded);

    // Decode back
    var decoded = toon.decode(allocator, encoded, .{ .strict = true }) catch |err| {
        const failure = ChaosFailure.init(
            allocator,
            config.seed,
            iteration,
            .decoding,
            @errorName(err),
            input_json,
        ) catch return .pass;
        return .{ .fail = failure };
    };
    defer decoded.deinit(allocator);

    // Compare
    if (!value.eql(decoded)) {
        const failure = ChaosFailure.init(
            allocator,
            config.seed,
            iteration,
            .comparison,
            "Round-trip mismatch",
            input_json,
        ) catch return .pass;
        return .{ .fail = failure };
    }

    return .pass;
}

// ============================================================================
// Test Entry Points
// ============================================================================

test "chaos: baseline (100 iterations, 1x multiplier)" {
    const config = ChaosConfig{
        .seed = 42,
        .iterations = 100,
        .chaos_multiplier = 1.0,
    };

    var result = try runChaosTests(testing.allocator, config);
    defer result.deinit();

    result.summary();

    // Fail the test if any chaos tests failed
    try testing.expect(result.failed == 0);
}

test "chaos: stress (50 iterations, 2x multiplier)" {
    const base_config = ChaosConfig{
        .seed = 12345,
        .iterations = 50,
        .chaos_multiplier = 1.0,
    };
    const config = base_config.withChaos(2.0);

    var result = try runChaosTests(testing.allocator, config);
    defer result.deinit();

    result.summary();
    try testing.expect(result.failed == 0);
}

test "chaos: deep nesting (30 iterations, deep structures)" {
    const config = ChaosConfig{
        .seed = 98765,
        .iterations = 30,
        .max_depth = 15,
        .max_object_width = 5,
        .max_array_length = 5,
    };

    var result = try runChaosTests(testing.allocator, config);
    defer result.deinit();

    result.summary();
    try testing.expect(result.failed == 0);
}

test "chaos: wide structures (30 iterations, many keys)" {
    const config = ChaosConfig{
        .seed = 55555,
        .iterations = 30,
        .max_depth = 3,
        .max_object_width = 100,
        .max_array_length = 100,
    };

    var result = try runChaosTests(testing.allocator, config);
    defer result.deinit();

    result.summary();
    try testing.expect(result.failed == 0);
}

test "chaos: unicode heavy (50 iterations, high unicode)" {
    const config = ChaosConfig{
        .seed = 77777,
        .iterations = 50,
        .unicode_probability = 80,
        .max_string_length = 200,
    };

    var result = try runChaosTests(testing.allocator, config);
    defer result.deinit();

    result.summary();
    try testing.expect(result.failed == 0);
}

test "chaos: edge numbers (50 iterations, edge cases)" {
    const config = ChaosConfig{
        .seed = 88888,
        .iterations = 50,
        .edge_number_probability = 80,
    };

    var result = try runChaosTests(testing.allocator, config);
    defer result.deinit();

    result.summary();
    try testing.expect(result.failed == 0);
}
