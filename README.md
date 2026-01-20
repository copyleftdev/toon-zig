<div align="center">

# 🔷 toon-zig

**Zig implementation of TOON (Token-Oriented Object Notation)**

[![Zig](https://img.shields.io/badge/Zig-0.14%2B-f7a41d?style=flat&logo=zig&logoColor=white)](https://ziglang.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![TOON Spec](https://img.shields.io/badge/TOON-v3.0-green.svg)](https://github.com/toon-format/spec)

A spec-compliant Zig library for encoding and decoding [TOON format](https://toonformat.dev) — a compact, human-readable, line-oriented format for structured data, **optimized for LLM prompts with 30-60% token reduction vs JSON**.

[Features](#features) • [Installation](#installation) • [Usage](#usage) • [API Reference](#api-reference) • [Contributing](#contributing)

</div>

---

## Features

- **Full TOON v3.0 Specification Compliance** — Implements all normative requirements
- **Encoder**: JSON → TOON with configurable delimiters and indentation
- **Decoder**: TOON → JSON with strict mode validation
- **Zero Dependencies** — Pure Zig, no external dependencies
- **Memory Safe** — Explicit allocator-based memory management
- **v1.5 Features** — Key folding and path expansion support

## Quick Example

**JSON** (40 bytes):
```json
{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}
```

**TOON** (28 bytes) — 30% smaller:
```
users[2]{id,name}:
  1,Alice
  2,Bob
```

## Installation

Add to your `build.zig.zon`:

```zig
.dependencies = .{
    .toon = .{
        .url = "https://github.com/copyleftdev/toon-zig/archive/refs/tags/v0.1.0.tar.gz",
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const toon = b.dependency("toon", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("toon", toon.module("toon"));
```

## Usage

### Encoding (JSON → TOON)

```zig
const std = @import("std");
const toon = @import("toon");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create a value
    var obj = toon.JsonValue.initObject(allocator);
    defer obj.deinit(allocator);

    const name_key = try allocator.dupe(u8, "name");
    try obj.asObject().?.put(name_key, toon.JsonValue.initString("Alice"));

    const age_key = try allocator.dupe(u8, "age");
    try obj.asObject().?.put(age_key, toon.JsonValue.initInteger(30));

    // Encode to TOON
    const encoded = try toon.encode(allocator, obj, .{});
    defer allocator.free(encoded);

    std.debug.print("{s}\n", .{encoded});
    // Output:
    // name: Alice
    // age: 30
}
```

### Decoding (TOON → JSON)

```zig
const std = @import("std");
const toon = @import("toon");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const input =
        \\users[2]{id,name}:
        \\  1,Alice
        \\  2,Bob
    ;

    var decoded = try toon.decode(allocator, input, .{});
    defer decoded.deinit(allocator);

    // Access the data
    const users = decoded.asConstObject().?.get("users").?;
    const first_user = users.asConstArray().?.items[0];
    const name = first_user.asConstObject().?.get("name").?.asString().?;

    std.debug.print("First user: {s}\n", .{name}); // Alice
}
```

### Encoder Options

```zig
const options = toon.EncodeOptions{
    .indent = 4,                    // Spaces per level (default: 2)
    .delimiter = .tab,              // .comma (default), .tab, or .pipe
    .key_folding = .safe,           // .off (default) or .safe
    .flatten_depth = 3,             // Max folding depth (default: max)
};

const encoded = try toon.encode(allocator, value, options);
```

### Decoder Options

```zig
const options = toon.DecodeOptions{
    .indent = 2,                    // Expected indent size (default: 2)
    .strict = true,                 // Strict validation (default: true)
    .expand_paths = .safe,          // .off (default) or .safe
};

var decoded = try toon.decode(allocator, input, options);
```

## TOON Format Overview

TOON is designed for efficient structured data in LLM prompts:

### Objects
```
name: Alice
age: 30
active: true
```

### Nested Objects
```
user:
  id: 123
  profile:
    name: Ada
```

### Primitive Arrays (Inline)
```
tags[3]: admin,ops,dev
```

### Tabular Arrays
```
users[2]{id,name,role}:
  1,Alice,admin
  2,Bob,user
```

### Arrays of Arrays
```
matrix[2]:
  - [3]: 1,2,3
  - [3]: 4,5,6
```

### Mixed Arrays
```
items[3]:
  - 42
  - name: widget
  - hello
```

### Delimiter Variations
```
# Tab-delimited
data[2	]{id	name}:
  1	Alice
  2	Bob

# Pipe-delimited
tags[3|]: a|b|c
```

## API Reference

### Types

- **`JsonValue`** — Union type representing JSON values (null, bool, integer, float, string, array, object)
- **`JsonArray`** — `ArrayList(JsonValue)`
- **`JsonObject`** — `StringArrayHashMap(JsonValue)` with preserved insertion order
- **`Delimiter`** — `.comma`, `.tab`, `.pipe`
- **`ToonError`** — Error type for encoding/decoding failures

### Functions

- **`encode(allocator, value, options)`** — Encode JsonValue to TOON string
- **`decode(allocator, input, options)`** — Decode TOON string to JsonValue
- **`encodeDefault(allocator, value)`** — Encode with default options
- **`decodeDefault(allocator, input)`** — Decode with default options

### JsonValue Methods

- **`initNull()`, `initBool(b)`, `initInteger(i)`, `initFloat(f)`, `initString(s)`** — Create primitives
- **`initArray(allocator)`, `initObject(allocator)`** — Create containers
- **`clone(allocator)`** — Deep copy
- **`deinit(allocator)`** — Free memory
- **`eql(other)`** — Deep equality comparison
- **`parseJson(allocator, json_str)`** — Parse from JSON string
- **`toJsonString(allocator)`** — Serialize to JSON string

## Building & Testing

```bash
# Build library
zig build

# Run unit tests
zig build test

# Run fixture tests (requires test fixtures)
zig build test-fixtures

# Run all tests
zig build test-all
```

## Specification Compliance

This implementation targets **TOON Specification v3.0** and implements:

- ✅ Canonical number formatting (no exponent, no trailing zeros)
- ✅ String escaping (only `\\`, `\"`, `\n`, `\r`, `\t`)
- ✅ Quoting rules per §7.2
- ✅ Key encoding per §7.3
- ✅ Object encoding with preserved key order
- ✅ Primitive arrays (inline)
- ✅ Tabular arrays with field lists
- ✅ Arrays of arrays (expanded)
- ✅ Mixed arrays (expanded)
- ✅ Objects as list items per §10
- ✅ Delimiter handling (comma, tab, pipe)
- ✅ Strict mode validation
- ✅ Key folding (encoder)
- ✅ Path expansion (decoder)

## Resources

- [TOON Format Website](https://toonformat.dev)
- [TOON Specification](https://github.com/toon-format/spec)
- [Reference Test Suite](https://github.com/toon-format/spec/tree/main/tests)

## Contributing

Contributions are welcome! Please ensure:

1. All tests pass (`zig build test-all`)
2. Code follows Zig style conventions
3. New features include tests
4. Spec compliance is maintained

## License

MIT License — see [LICENSE](LICENSE) for details.
