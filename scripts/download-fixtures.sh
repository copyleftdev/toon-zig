#!/bin/bash
# Download official TOON test fixtures from the spec repository

set -e

SPEC_REPO="https://raw.githubusercontent.com/toon-format/spec/main/tests/fixtures"
FIXTURES_DIR="tests/fixtures"

echo "Downloading TOON test fixtures..."

# Encode fixtures
mkdir -p "$FIXTURES_DIR/encode"
for file in primitives objects arrays-primitive arrays-tabular arrays-nested arrays-objects delimiters whitespace options key-folding; do
    echo "  Downloading encode/$file.json..."
    curl -sL "$SPEC_REPO/encode/$file.json" -o "$FIXTURES_DIR/encode/$file.json" 2>/dev/null || echo "    (not found)"
done

# Decode fixtures
mkdir -p "$FIXTURES_DIR/decode"
for file in primitives numbers objects arrays-primitive arrays-tabular arrays-nested delimiters whitespace root-form validation-errors indentation-errors blank-lines path-expansion; do
    echo "  Downloading decode/$file.json..."
    curl -sL "$SPEC_REPO/decode/$file.json" -o "$FIXTURES_DIR/decode/$file.json" 2>/dev/null || echo "    (not found)"
done

echo "Done!"
