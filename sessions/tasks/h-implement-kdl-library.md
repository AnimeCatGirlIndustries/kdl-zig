---
name: h-implement-kdl-library
branch: feature/h-implement-kdl-library
status: pending
created: 2026-01-03
---

# Implement KDL 2.0.0 Library

## Problem/Goal
Complete the KDL 2.0.0 library implementation with parser, serializer, and public API. The library should:
- Parse KDL documents into an AST with effective resource usage (pass struct, populate correctly)
- Serialize AST back to KDL text
- Handle errors gracefully
- Match the KDL 2.0.0 spec: https://kdl.dev/spec/
- Pass all official tests: https://github.com/kdl-org/kdl/tree/main/tests

## Success Criteria
- [ ] Parser converts tokenized input to complete AST
- [ ] Serializer outputs valid KDL from AST
- [ ] Public API: parse to AST directly
- [ ] Public API: comptime generic struct population (like std.json)
- [ ] Graceful error handling with clear messages
- [ ] Passes all official KDL test suite cases
- [ ] Spec-compliant (KDL 2.0.0)

## Context Manifest

### How the Existing Tokenizer Works

The KDL tokenizer (`src/tokenizer.zig`) is a zero-allocation, streaming lexer that converts KDL 2.0.0 source text into a sequence of tokens. It operates on a `[]const u8` source buffer and produces `Token` structs that reference slices back into the original source, meaning it does not allocate memory during tokenization.

When `Tokenizer.init(source)` is called, the tokenizer initializes with the source buffer at index 0, line 1, column 1. It immediately checks for and skips a UTF-8 BOM (bytes 0xEF, 0xBB, 0xBF) if present at the start. The tokenizer maintains state through these fields:
- `source: []const u8` - the input buffer
- `index: usize` - current byte position
- `line: u32` and `column: u32` - 1-indexed position tracking
- `seen_bom: bool` - whether BOM was skipped

The `next()` method is the core API. Each call:
1. Skips whitespace and comments via `skipWhitespaceAndComments()`
2. Checks for EOF (returns `.eof` token)
3. Examines the current character and dispatches to appropriate handlers

The tokenizer handles these token types (defined in `TokenType` enum):
- **Identifiers and strings**: `.identifier`, `.quoted_string`, `.raw_string`, `.multiline_string`
- **Numbers**: `.integer`, `.float`, `.hex_integer`, `.octal_integer`, `.binary_integer`
- **Keywords**: `.keyword_true`, `.keyword_false`, `.keyword_null`, `.keyword_inf`, `.keyword_neg_inf`, `.keyword_nan`
- **Punctuation**: `.open_paren`, `.close_paren`, `.open_brace`, `.close_brace`, `.equals`, `.semicolon`
- **Special**: `.slashdash`, `.newline`, `.eof`, `.invalid`

The `Token` struct contains:
```zig
pub const Token = struct {
    type: TokenType,
    text: []const u8,  // Slice into source - the raw token text
    line: u32,         // 1-indexed
    column: u32,       // 1-indexed
};
```

**Critical tokenizer behaviors for the parser:**

1. **Whitespace handling**: The tokenizer skips whitespace (tab, space, Unicode spaces) and comments between tokens automatically in `skipWhitespaceAndComments()`. Newlines are NOT skipped - they are returned as `.newline` tokens because they are semantically significant in KDL (node terminators).

2. **Comment handling**: Single-line comments (`//`) are skipped entirely (but the following newline is preserved). Multi-line comments (`/* */`) support nesting and are skipped. Slashdash (`/-`) is returned as a token for the parser to handle.

3. **Line continuation**: Backslash followed by whitespace and newline is handled during whitespace skipping via `trySkipLineContinuation()`. This allows nodes to span multiple lines.

4. **String tokenization**: The tokenizer returns the RAW text including quotes and escape sequences. For `"hello\nworld"`, the token text is literally `"hello\nworld"` - the parser must process escapes. For raw strings like `#"text"#`, the text includes the delimiters.

5. **Number tokenization**: Numbers include sign if present. `+42` returns text `"+42"`. The tokenizer categorizes by radix (`.hex_integer` for `0xFF`, etc.) but does not parse the numeric value.

6. **Keyword detection**: KDL 2.0 keywords require `#` prefix. `#true` returns `.keyword_true`, but bare `true` returns `.identifier`.

### Unicode Module (`src/unicode.zig`)

The unicode module provides character classification functions per the KDL spec:

- `isWhitespace(c: u21)` - Non-newline whitespace (Tab, Space, various Unicode spaces)
- `isNewline(c: u21)` - CR, LF, NEL, VT, FF, LS, PS
- `isDisallowed(c: u21)` - Control chars, surrogates, direction control, BOM
- `isIdentifierStart(c: u21)` - Can start an identifier (not digit, not punctuation)
- `isIdentifierChar(c: u21)` - Can continue an identifier
- `isDigit(c)`, `isHexDigit(c)`, `isOctalDigit(c)`, `isBinaryDigit(c)`
- `decodeUtf8(bytes)` - Decode UTF-8 to codepoint with length

### AST Types (`src/types.zig`)

The types module defines the AST structures that the parser will produce:

```zig
pub const Value = union(enum) {
    string: StringValue,
    integer: i128,
    float: f64,
    boolean: bool,
    null_value: void,
    positive_inf: void,
    negative_inf: void,
    nan_value: void,

    pub const StringValue = struct {
        raw: []const u8,
        type_annotation: ?[]const u8 = null,
    };
};

pub const TypedValue = struct {
    value: Value,
    type_annotation: ?[]const u8 = null,
};

pub const Property = struct {
    name: []const u8,
    value: Value,
    type_annotation: ?[]const u8 = null,
};

pub const Node = struct {
    name: []const u8,
    type_annotation: ?[]const u8 = null,
    arguments: []TypedValue,
    properties: []Property,
    children: []Node,

    pub fn deinit(self: *Node, allocator: Allocator) void { ... }
};

pub const Document = struct {
    nodes: []Node,
    allocator: Allocator,

    pub fn deinit(self: *Document) void { ... }
    pub fn getNode(self: Document, name: []const u8) ?*const Node { ... }
    pub fn getNodes(self: Document, allocator: Allocator, name: []const u8) ![]const *const Node { ... }
};

pub const ParseError = struct {
    message: []const u8,
    line: u32,
    column: u32,
    byte_offset: usize,
};
```

**Design decisions in types.zig:**
- `Value.integer` uses `i128` to handle the full range of KDL integers
- `Value.float` uses `f64` for IEEE 754 double precision
- Strings store the raw text - escape processing is deferred
- Node arguments are `[]TypedValue` - ordered list
- Node properties are `[]Property` - KDL spec says order should not be relied upon, but duplicates must be resolved (rightmost wins)
- Each `Node` has a `deinit` method that recursively frees children
- `Document` owns its allocator reference for cleanup

### Public API Module (`src/root.zig`)

This is the library's public interface, exporting:
```zig
// Types
pub const Value = types.Value;
pub const TypedValue = types.TypedValue;
pub const Property = types.Property;
pub const Node = types.Node;
pub const Document = types.Document;
pub const ParseError = types.ParseError;

// Tokenizer (for advanced users)
pub const TokenType = tokenizer_mod.TokenType;
pub const Token = tokenizer_mod.Token;
pub const Tokenizer = tokenizer_mod.Tokenizer;

pub const unicode = @import("unicode.zig");
```

### Build System (`build.zig` and `build/tests.zig`)

The project uses a structured test registration system:

```zig
// build/tests.zig defines test specifications
pub const TestSpec = struct {
    name: []const u8,
    area: Area,  // enum { tokenizer, parser, serializer, integration }
    path: []const u8,
    module: bool = true,  // Whether to import kdl module
    membership: Membership = .{},
};
```

Tests are organized by area with `test-unit` and `test-integration` steps. New parser/serializer tests should be added to the `specs` array in `build/tests.zig`.

The KDL module is available as `@import("kdl")` in tests.

### KDL 2.0.0 Grammar Requirements for Parser

Based on the official KDL 2.0.0 specification, the parser must handle:

**Document Structure:**
- A document is zero or more nodes separated by newlines, semicolons, and whitespace
- Nodes may have: name, type annotation, arguments, properties, children block
- Type annotations use `(type)` syntax before nodes, arguments, or property values

**Node Syntax:**
```
node := base-node node-terminator
base-node := slashdash? type? node-space* string
    (node-space* (node-space | slashdash) node-prop-or-arg)*
    (node-space* slashdash node-children)*
    (node-space* node-children)?
    node-space*
node-terminator := single-line-comment | newline | ';' | eof
```

**Key parsing rules:**
1. Node names are strings (identifier, quoted, or raw)
2. Arguments and properties can be interspersed in any order
3. Properties have form `key=value` with no whitespace around `=`
4. Properties with duplicate keys: rightmost wins
5. Children blocks use `{ }` and can contain nested nodes
6. Slashdash (`/-`) comments out the next element (node, arg, property, or children block)

**Value Types:**
- Strings: identifier, quoted (`"..."`), raw (`#"..."#`), multiline (`"""..."""`)
- Numbers: decimal, hex (`0x`), octal (`0o`), binary (`0b`), with optional sign and underscores
- Keywords: `#true`, `#false`, `#null`, `#inf`, `#-inf`, `#nan`

**String Escape Sequences (for quoted/multiline strings):**
- `\n`, `\r`, `\t`, `\\`, `\"`, `\b`, `\f`, `\s` (space)
- `\u{XXXX}` - Unicode escape (1-6 hex digits)
- `\` followed by whitespace/newline - whitespace escape (discarded)

**Multiline String Dedent Rules:**
- First line must be immediately after opening `"""`
- Final line contains only whitespace before closing `"""`
- All content lines must share the exact whitespace prefix of the final line
- Whitespace-only lines can have any whitespace and represent empty lines
- Newlines normalized to LF

### Serializer Requirements

The serializer must convert AST back to valid KDL text. Based on the test suite's expected output format:

1. Remove all comments
2. One node per line (no multi-line nodes with line continuations)
3. Order: `identifier <values> <properties> <children>`
4. Properties in **alphabetical order** (spec says order shouldn't be relied on, tests require alpha)
5. Strings as regular strings with escapes (convert raw strings)
6. Bare identifiers when valid, quoted otherwise
7. Numbers in simplest decimal form (convert hex/octal/binary to decimal)
8. 4-space indentation for children
9. Escape sequences for literal newlines in strings

### std.json API Pattern for Comptime Struct Population

The Zig standard library's `std.json` provides the pattern to follow:

```zig
// Parse to typed struct
pub fn parseFromSlice(
    comptime T: type,
    allocator: Allocator,
    s: []const u8,
    options: ParseOptions,
) ParseError(Scanner)!Parsed(T)

// Returned wrapper with memory management
pub fn Parsed(comptime T: type) type {
    return struct {
        arena: *ArenaAllocator,
        value: T,
        pub fn deinit(self: @This()) void { ... }
    };
}

// Options for parsing behavior
pub const ParseOptions = struct {
    duplicate_field_behavior: enum { use_first, @"error", use_last } = .@"error",
    ignore_unknown_fields: bool = false,
    max_value_len: ?usize = null,
    allocate: ?AllocWhen = null,
};
```

The `innerParse` function uses `@typeInfo(T)` to introspect the target type and recursively parse:
- Booleans from `#true`/`#false`
- Integers/floats from number tokens
- Optionals from `#null` or value
- Enums from strings matching variant names
- Structs from node properties (field name = property key)
- Arrays from multiple arguments or child nodes

Types can implement custom parsing via `jsonParse(allocator, source, options)` method.

### Official Test Suite Structure

The KDL test suite at `https://github.com/kdl-org/kdl/tree/main/tests/test_cases`:
- `input/` - KDL documents to parse
- `expected_kdl/` - Expected re-serialized output
- Files ending in `_fail` should fail parsing
- Tests verify round-trip: parse then serialize should match expected output

Test names suggest coverage areas: `all_escapes.kdl`, `arg_type.kdl`, `binary.kdl`, `block_comment.kdl`, `multiline_string.kdl`, `slashdash_*.kdl`, etc.

### Implementation Strategy

**Phase 2: Parser (tokens to AST)**

The parser should:
1. Accept a `Tokenizer` or source `[]const u8`
2. Use an arena allocator for all AST allocations
3. Build `Document` containing `[]Node`
4. Handle slashdash by parsing but discarding the commented element
5. Track and report errors with line/column from tokens

Key functions needed:
```zig
pub fn parse(allocator: Allocator, source: []const u8) !Document
pub fn parseTokens(allocator: Allocator, tokenizer: *Tokenizer) !Document
```

**Phase 3: Serializer (AST to text)**

The serializer should:
1. Accept a `Document` and output to a writer or return `[]u8`
2. Handle proper escaping and formatting
3. Follow test suite conventions for reproducible output

```zig
pub fn serialize(document: Document, writer: anytype) !void
pub fn serializeToString(allocator: Allocator, document: Document) ![]u8
```

**Phase 4: Comptime Generic API**

Following `std.json` pattern:
```zig
pub fn parseAs(comptime T: type, allocator: Allocator, source: []const u8, options: ParseOptions) !Parsed(T)
```

This requires mapping KDL semantics to Zig types:
- Node arguments -> tuple or array fields
- Node properties -> struct fields by name
- Node children -> nested struct or array of structs
- Type annotations -> could filter which nodes map to which fields

### File Locations for Implementation

- Parser: `src/parser.zig` (new file)
- Serializer: `src/serializer.zig` (new file)
- Public API extensions: `src/root.zig` (add exports)
- Parser tests: `tests/parser/` (new directory)
- Serializer tests: `tests/serializer/` (new directory)
- Integration tests (official suite): `tests/integration/` (new directory)
- Test registration: `build/tests.zig` (add new specs)

### Technical Reference Details

#### Tokenizer Interface

```zig
// Create tokenizer
var tokenizer = Tokenizer.init(source: []const u8);

// Get next token (call repeatedly until .eof)
const token: Token = tokenizer.next();

// Token fields
token.type    // TokenType enum
token.text    // []const u8 slice into source
token.line    // u32, 1-indexed
token.column  // u32, 1-indexed
```

#### Error Handling Pattern

From `ParseError` in types.zig:
```zig
pub const ParseError = struct {
    message: []const u8,
    line: u32,
    column: u32,
    byte_offset: usize,
};
```

The parser should return errors that can construct meaningful `ParseError` values with location info from the offending token.

#### Memory Management Pattern

Use arena allocator for all AST allocations:
```zig
var arena = std.heap.ArenaAllocator.init(allocator);
errdefer arena.deinit();

// All parsing allocations use arena.allocator()
const nodes = try arena.allocator().alloc(Node, count);

// Return Document that owns the arena
return Document{
    .nodes = nodes,
    .allocator = arena.allocator(),
    // Store arena reference for deinit
};
```

#### String Processing Utilities Needed

The parser needs functions to:
1. Remove quotes from quoted strings (`"hello"` -> `hello`)
2. Process escape sequences (`hello\nworld` -> `hello` + newline + `world`)
3. Handle raw string delimiters (`#"text"#` -> `text`)
4. Dedent multiline strings per the spec

#### Number Parsing

Convert token text to numeric values:
- Strip underscores: `1_000_000` -> `1000000`
- Handle radix prefixes: `0xFF` -> 255, `0o77` -> 63, `0b1010` -> 10
- Parse floats with exponents: `1.5e10`, `2.5E-3`
- Handle signed numbers: `-42`, `+42`

Use `std.fmt.parseInt` and `std.fmt.parseFloat` after preprocessing.

## User Notes
<!-- Any specific notes or requirements from the developer -->

## Work Log
<!-- Updated as work progresses -->
- [2026-01-03] Task created
