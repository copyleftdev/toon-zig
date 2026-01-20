# Contributing to toon-zig

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/toon-zig.git`
3. Create a feature branch: `git checkout -b feature/your-feature`

## Prerequisites

- Zig 0.14.0+

## Building & Testing

```bash
zig build              # Build library
zig build test         # Unit tests
zig build test-fuzz    # Edge case tests
zig build test-chaos   # Property-based chaos tests
zig build test-all     # All tests
```

## Code Style

Follow Zig philosophy:
- Self-documenting code, minimal comments
- Small focused functions
- Explicit error handling
- Tests for new functionality

## Pull Requests

1. All tests pass (`zig build test-all`)
2. No memory leaks (uses testing allocator)
3. Follows existing patterns
4. Includes tests for new features

## Specification

Follows [TOON Spec v3.0](https://github.com/toon-format/spec). Reference test suite in `tests/fixtures/`.

## License

Contributions licensed under MIT.
