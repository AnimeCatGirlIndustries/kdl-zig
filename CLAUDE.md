# zig-kdl Development Guide

A robust, idiomatic KDL 2.0.0 parser and serializer for Zig.

## Quick Reference

### Build Commands

```bash
zig build test              # Run all tests (unit + integration)
zig build test-unit         # Run unit tests only
zig build test-integration  # Run integration tests (336 official KDL spec tests)
zig build example           # Run tokenizer demo
zig build bench -Doptimize=ReleaseFast  # Run benchmarks
zig build fuzz -- --fuzz    # Run fuzzer (requires Zig 0.14+)
```

### Module Structure

| Module | Purpose |
|--------|---------|
| `src/root.zig` | Public API - all exports |
| `src/parser.zig` | DOM parser (source -> Document AST) |
| `src/serializer.zig` | DOM serializer (Document -> KDL text) |
| `src/decoder.zig` | Comptime decoder (source -> Zig structs) |
| `src/encoder.zig` | Comptime encoder (Zig structs -> KDL text) |
| `src/pull.zig` | Pull/SAX-style streaming parser |
| `src/tokenizer.zig` | Lexer (source -> tokens) |
| `src/types.zig` | Core types: Document, Node, Value, Property |
| `src/strings.zig` | String utilities (escapes, multiline dedent) |
| `src/numbers.zig` | Number parsing (radix, underscores) |
| `src/unicode.zig` | Unicode character classification |
| `src/formatting.zig` | Serialization formatting utilities |

### Test Organization

- `tests/kdl-spec/` - Official KDL test suite (cloned from kdl-org/kdl)
- `tests/parser/` - Parser unit tests
- `tests/fuzz.zig` - Fuzz testing harness
- `build/tests.zig` - Test registration and configuration
- `benches/` - Performance benchmarks
- `examples/` - Usage examples (tokenizer demo)

### Key Design Decisions

1. **Arena Allocator for AST** - All parsing allocations use an arena owned by the Document
2. **Zero-Copy Tokenization** - Tokenizer returns slices into the source buffer
3. **UTF-8 Decoding Required** - Character classification functions expect Unicode codepoints, not bytes
4. **Thread-Safe Number Parsing** - Uses ArrayList with passed allocator, not static buffers
5. **Configurable Limits** - `max_depth` (default 256) and `max_size` (default 256 MiB) protect against malicious input
6. **Thread Safety** - Parser instances are NOT thread-safe; create separate instances for concurrent parsing

### API Overview

The library provides three parsing approaches:

1. **DOM API**: `kdl.parse(allocator, source)` returns a traversable `Document`
2. **Comptime Decoding**: `kdl.decode(&struct, allocator, source, .{})` populates structs directly
3. **Pull Parser**: `kdl.PullParser.init(allocator, source)` provides streaming events

Serialization:

1. **DOM Serialization**: `kdl.serialize(doc, writer, .{})` for Document AST
2. **Comptime Encoding**: `kdl.encode(struct_value, writer, .{})` for Zig structs

## cc-sessions Integration

@sessions/CLAUDE.sessions.md

This file provides instructions for Claude Code for working in the cc-sessions framework.
