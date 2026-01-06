/// KDL 2.0.0 Parser and Serializer for Zig
///
/// A robust, idiomatic KDL 2.0.0 library providing:
/// - **DOM API**: Parse KDL into traversable documents (`Document`, `Node`)
/// - **Comptime Decoding**: Parse directly into Zig structs (like `std.json`)
/// - **Serialization**: Convert structs or documents back to KDL text
/// - **Streaming**: SAX-style event iterator for large files
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
// Core Types (from stream_types)
// =============================================================================

const stream_types_mod = @import("stream_types.zig");

/// A complete KDL document with SoA-based storage.
pub const Document = stream_types_mod.StreamDocument;

/// String reference into the document's string pool.
pub const StringRef = stream_types_mod.StringRef;

/// Handle to a node in the document.
pub const NodeHandle = stream_types_mod.NodeHandle;

/// A KDL value (string, integer, float, boolean, null, inf, nan).
pub const Value = stream_types_mod.StreamValue;

/// A value with an optional type annotation.
pub const TypedValue = stream_types_mod.StreamTypedValue;

/// A property (key=value pair) on a node.
pub const Property = stream_types_mod.StreamProperty;

// =============================================================================
// DOM Parser
// =============================================================================

const stream_parser_mod = @import("stream_parser.zig");

/// The parser type (for advanced usage).
pub const Parser = stream_parser_mod.StreamParser;

/// Parse KDL source into a Document AST.
pub const parse = stream_parser_mod.parse;

/// Parse KDL source with custom options.
pub const parseWithOptions = stream_parser_mod.parseWithOptions;

/// Options for DOM parsing.
pub const ParseOptions = stream_parser_mod.ParseOptions;

/// Find partition boundaries for parallel parsing.
pub const findNodeBoundaries = stream_parser_mod.findNodeBoundaries;

/// Merge multiple Documents into one.
pub const mergeDocuments = stream_parser_mod.mergeDocuments;

// =============================================================================
// Serialization
// =============================================================================

const stream_serializer_mod = @import("stream_serializer.zig");

/// Options for serialization (indentation, etc.).
pub const SerializeOptions = stream_serializer_mod.Options;

/// Serialize a Document to a writer.
pub const serialize = stream_serializer_mod.serialize;

/// Serialize a Document to an allocated string.
pub const serializeToString = stream_serializer_mod.serializeToString;

// =============================================================================
// Comptime Generic API (like std.json)
// =============================================================================

const decoder_mod = @import("stream_decoder.zig");
const encoder_mod = @import("stream_encoder.zig");

/// Decode KDL source directly into a Zig struct.
pub const decode = decoder_mod.decode;

/// Options for comptime decoding.
pub const DecodeOptions = decoder_mod.ParseOptions;

/// Encode a Zig struct to KDL format.
pub const encode = encoder_mod.encode;

/// Options for comptime encoding.
pub const EncodeOptions = encoder_mod.EncodeOptions;

// =============================================================================
// Streaming Iterator API (SAX-style)
// =============================================================================

const stream_iterator_mod = @import("stream_iterator.zig");
const virtual_document_mod = @import("virtual_document.zig");

/// True streaming iterator (SAX-style) - processes without building DOM.
pub const StreamIterator = stream_iterator_mod.StreamIterator;

/// Events emitted by the stream iterator.
pub const StreamIteratorEvent = stream_iterator_mod.Event;

/// Options for stream iterator parsing.
pub const StreamIteratorOptions = stream_iterator_mod.ParseOptions;

/// Virtual document for zero-copy multi-chunk iteration.
pub const VirtualDocument = virtual_document_mod.VirtualDocument;

/// Handle to a node in a virtual document.
pub const VirtualNodeHandle = virtual_document_mod.VirtualNodeHandle;

// =============================================================================
// Low-Level/Advanced APIs
// =============================================================================

const stream_tokenizer_mod = @import("stream_tokenizer.zig");

/// Token types produced by the lexer.
pub const TokenType = stream_tokenizer_mod.TokenType;

/// A single token from the lexer.
pub const Token = stream_tokenizer_mod.StreamToken;

/// The streaming tokenizer (for advanced usage).
pub const Tokenizer = stream_tokenizer_mod.StreamingTokenizer;

/// Unicode character classification utilities.
pub const unicode = @import("unicode.zig");

/// String processing utilities (escapes, multiline, etc.).
pub const strings = @import("strings.zig");

/// Number parsing utilities.
pub const numbers = @import("numbers.zig");

/// Value builder utilities for escape processing.
pub const value_builder = @import("value_builder.zig");

// =============================================================================
// Module Tests
// =============================================================================

test {
    _ = unicode;
    _ = strings;
    _ = numbers;
    _ = stream_types_mod;
    _ = stream_parser_mod;
    _ = stream_serializer_mod;
    _ = stream_iterator_mod;
    _ = virtual_document_mod;
    _ = decoder_mod;
    _ = encoder_mod;
    _ = value_builder;
}
