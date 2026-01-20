# Add toon-zig: Zig implementation of TOON

## Summary

A spec-compliant Zig library for encoding and decoding TOON format.

**Repository:** https://github.com/copyleftdev/toon-zig

## Features

- Full TOON v3.0 specification compliance
- Encoder (JSON → TOON) with configurable delimiters
- Decoder (TOON → JSON) with strict mode validation
- Zero dependencies, pure Zig
- Memory safe with explicit allocator management
- Key folding and path expansion support

## Requirements

- Zig 0.14.0+

## Quick Example

```zig
const toon = @import("toon");

// Encode
const encoded = try toon.encode(allocator, value, .{});

// Decode
var decoded = try toon.decode(allocator, input, .{});
defer decoded.deinit(allocator);
```

## Testing

- Unit tests for encoder/decoder
- Fixture-based tests using reference test suite
- Property-based chaos testing
- Edge case fuzz tests

## License

MIT
