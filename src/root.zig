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
const stream_mod = @import("stream");
const util_mod = @import("util");
const simd_mod = @import("simd");

// =============================================================================
// Core Types (from stream_types)
// =============================================================================

const stream_types_mod = stream_mod.stream_types;

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

const stream_parser_mod = stream_mod.stream_parser;

/// The parser type (for advanced usage).
pub const Parser = stream_parser_mod.StreamParser;

/// Parse KDL source into a Document AST.
pub const parse = stream_parser_mod.parse;

/// Parse KDL source with custom options.
pub const parseWithOptions = stream_parser_mod.parseWithOptions;

/// Options for DOM parsing.
pub const ParseOptions = stream_parser_mod.ParseOptions;

/// Strategy for parsing (streaming vs structural index).
pub const ParseStrategy = stream_parser_mod.ParseStrategy;

/// Parse KDL source from a reader.
pub const parseReader = stream_parser_mod.parseReader;

/// Parse KDL source from a reader with custom options.
pub const parseReaderWithOptions = stream_parser_mod.parseReaderWithOptions;

/// Find partition boundaries for parallel parsing.
pub const findNodeBoundaries = stream_parser_mod.findNodeBoundaries;

/// Merge multiple Documents into one.
pub const mergeDocuments = stream_parser_mod.mergeDocuments;

// =============================================================================
// Serialization
// =============================================================================

const stream_serializer_mod = stream_mod.stream_serializer;

/// Options for serialization (indentation, etc.).
pub const SerializeOptions = stream_serializer_mod.Options;

/// Serialize a Document to a writer.
pub const serialize = stream_serializer_mod.serialize;

/// Serialize a Document to an allocated string.
pub const serializeToString = stream_serializer_mod.serializeToString;

// =============================================================================
// Comptime Generic API (like std.json)
// =============================================================================

const decoder_mod = stream_mod.stream_decoder;
const encoder_mod = stream_mod.stream_encoder;

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

const stream_iterator_mod = stream_mod.stream_iterator;
const virtual_document_mod = stream_mod.virtual_document;
const index_parser_mod = simd_mod.index_parser;
const stream_kernel_mod = stream_mod.stream_kernel;

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

/// Index-based parser (experimental SIMD Stage 2)
pub const IndexParser = index_parser_mod.IndexParser;
/// Index-based parser module (experimental SIMD Stage 2)
pub const index_parser = index_parser_mod;

/// Stream kernel event type (zero-copy views).
pub const StreamKernelEvent = stream_kernel_mod.Event;
/// Stream kernel string view kind.
pub const StreamKernelStringKind = stream_kernel_mod.StringKind;
/// Stream kernel string view type.
pub const StreamKernelStringView = stream_kernel_mod.StringView;
/// Stream kernel value view type.
pub const StreamKernelValue = stream_kernel_mod.ValueView;
/// Stream kernel parse options.
pub const StreamKernelOptions = stream_kernel_mod.ParseOptions;
/// Stream kernel parser (zero-copy events).
pub const parseWithKernel = stream_kernel_mod.parseWithKernel;
/// Stream kernel parser for readers.
pub const parseReaderWithKernel = stream_kernel_mod.parseReaderWithKernel;
/// StreamDocument sink for kernel parsing.
pub const StreamDocumentKernel = stream_kernel_mod.StreamDocumentKernel;

// =============================================================================
// Low-Level/Advanced APIs
// =============================================================================

const stream_tokenizer_mod = stream_mod.stream_tokenizer;

/// Token types produced by the lexer.
pub const TokenType = stream_tokenizer_mod.TokenType;

/// A single token from the lexer.
pub const Token = stream_tokenizer_mod.StreamToken;

/// The streaming tokenizer (for advanced usage).
pub const Tokenizer = stream_tokenizer_mod.StreamingTokenizer;

/// SIMD-accelerated primitives.
pub const simd = simd_mod;

/// Unicode character classification utilities.
pub const unicode = util_mod.unicode;

/// String processing utilities (escapes, multiline, etc.).
pub const strings = util_mod.strings;

/// Number parsing utilities.
pub const numbers = util_mod.numbers;

/// Value builder utilities for escape processing.
pub const value_builder = stream_mod.value_builder;

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
    _ = simd_mod;
    _ = index_parser_mod;
}
