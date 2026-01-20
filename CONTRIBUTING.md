# Contributing to toon-zig

Thank you for your interest in contributing to toon-zig! This document provides guidelines for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/toon-zig.git`
3. Create a feature branch: `git checkout -b feature/your-feature`

## Development

### Prerequisites

- Zig 0.13.0 or later

### Building

```bash
zig build
```

### Testing

```bash
# Run unit tests
zig build test

# Run round-trip tests
zig build test-roundtrip

# Run all tests
zig build test-all
```

## Contribution Guidelines

### Code Style

- Follow Zig's standard style conventions
- Use meaningful variable and function names
- Keep functions focused and small
- Add tests for new functionality

### Commit Messages

- Use clear, descriptive commit messages
- Start with a verb (Add, Fix, Update, Remove, etc.)
- Reference issues when applicable

### Pull Requests

1. Ensure all tests pass
2. Update documentation if needed
3. Add tests for new features
4. Keep PRs focused on a single change

## Specification Compliance

This implementation follows the [TOON Specification v3.0](https://github.com/toon-format/spec). When making changes:

- Ensure conformance with the spec
- Reference spec sections in comments where applicable
- Run the reference test suite if available

## Reporting Issues

- Check existing issues before creating a new one
- Provide clear reproduction steps
- Include Zig version and OS information
- Attach relevant error messages or logs

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
