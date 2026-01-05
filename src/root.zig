/// KDL 2.0.0 Parser and Serializer for Zig
///
/// A robust, idiomatic KDL 2.0.0 library providing:
/// - **DOM API**: Parse KDL into traversable documents (`Document`, `Node`)
/// - **Comptime Decoding**: Parse directly into Zig structs (like `std.json`)
/// - **Serialization**: Convert structs or documents back to KDL text
/// - **Pull Parser**: SAX-style streaming for large files or custom logic
///
/// ## Quick Start
///
/// ```zig
/// const kdl = @import("kdl");
///
/// // Parse to document
/// var doc = try kdl.parse(allocator, source);
/// defer doc.deinit();
///
/// // Or decode directly into a struct
/// var config: MyConfig = .{};
/// try kdl.decode(&config, allocator, source, .{});
/// ```
///
/// See https://kdl.dev/ for the KDL 2.0.0 language specification.
const std = @import("std");

// =============================================================================
// Core Types
// =============================================================================

const types = @import("types.zig");

/// A KDL value (string, integer, float, boolean, null, inf, nan).
pub const Value = types.Value;

/// A value with an optional type annotation.
pub const TypedValue = types.TypedValue;

/// A property (key=value pair) on a node.
pub const Property = types.Property;

/// A KDL node with name, arguments, properties, and children.
pub const Node = types.Node;

/// A complete KDL document containing top-level nodes.
pub const Document = types.Document;

// =============================================================================
// DOM Parser
// =============================================================================

const parser_mod = @import("parser.zig");

/// The internal parser type (for advanced usage).
pub const Parser = parser_mod.Parser;

/// Parse KDL source into a Document AST.
pub const parse = parser_mod.parse;

/// Parse KDL source with custom options.
pub const parseWithOptions = parser_mod.parseWithOptions;

/// Options for DOM parsing.
pub const ParseOptions = parser_mod.ParseOptions;

// =============================================================================
// Serialization
// =============================================================================

const serializer_mod = @import("serializer.zig");

/// Options for serialization (indentation, etc.).
pub const SerializeOptions = serializer_mod.Options;

/// Serialize a Document to a writer.
pub const serialize = serializer_mod.serialize;

/// Serialize a Document to an allocated string.
pub const serializeToString = serializer_mod.serializeToString;

// =============================================================================
// Comptime Generic API (like std.json)
// =============================================================================

const decoder_mod = @import("decoder.zig");

/// Decode KDL source directly into a Zig struct.
pub const decode = decoder_mod.decode;

/// Options for comptime decoding.
pub const DecodeOptions = decoder_mod.ParseOptions;

const encoder_mod = @import("encoder.zig");

/// Encode a Zig struct to KDL format.
pub const encode = encoder_mod.encode;

/// Options for comptime encoding.
pub const EncodeOptions = encoder_mod.EncodeOptions;

// =============================================================================
// Pull Parser (Streaming/SAX-style)
// =============================================================================

const pull_mod = @import("pull.zig");

/// Streaming parser that emits events (start_node, argument, property, end_node).
pub const PullParser = pull_mod.Parser;

/// Event types emitted by the pull parser.
pub const PullEvent = pull_mod.Event;

/// Options for pull parser behavior.
pub const PullParseOptions = pull_mod.ParseOptions;

/// Options for initializing a pull parser from a reader.
pub const PullReaderOptions = pull_mod.ReaderOptions;

// =============================================================================
// Low-Level/Advanced APIs
// =============================================================================

const tokenizer_mod = @import("tokenizer.zig");

/// Token types produced by the lexer.
pub const TokenType = tokenizer_mod.TokenType;

/// A single token from the lexer.
pub const Token = tokenizer_mod.Token;

/// The lexer/tokenizer (for advanced usage).
pub const Tokenizer = tokenizer_mod.Tokenizer;

/// Unicode character classification utilities.
pub const unicode = @import("unicode.zig");

/// String processing utilities (escapes, multiline, etc.).
pub const strings = @import("strings.zig");

/// Number parsing utilities.
pub const numbers = @import("numbers.zig");

// =============================================================================
// Module Tests
// =============================================================================

test {
    _ = unicode;
    _ = strings;
    _ = numbers;
    _ = types;
    _ = tokenizer_mod;
    _ = parser_mod;
    _ = serializer_mod;
    _ = decoder_mod;
    _ = encoder_mod;
    _ = pull_mod;
}
