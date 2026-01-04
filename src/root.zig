/// KDL 2.0.0 - A document language for configuration files
///
/// This library provides parsing and serialization of KDL documents.
/// See https://kdl.dev/ for the language specification.

const std = @import("std");

// Internal modules
const types = @import("types.zig");
const tokenizer_mod = @import("tokenizer.zig");
const parser_mod = @import("parser.zig");
const serializer_mod = @import("serializer.zig");
pub const unicode = @import("unicode.zig");

// Public type exports
pub const Value = types.Value;
pub const TypedValue = types.TypedValue;
pub const Property = types.Property;
pub const Node = types.Node;
pub const Document = types.Document;
pub const ParseError = types.ParseError;

// Tokenizer exports (for internal use and advanced users)
pub const TokenType = tokenizer_mod.TokenType;
pub const Token = tokenizer_mod.Token;
pub const Tokenizer = tokenizer_mod.Tokenizer;

// Parser exports
pub const Parser = parser_mod.Parser;
pub const parse = parser_mod.parse;

// Serializer exports
pub const SerializeOptions = serializer_mod.Options;
pub const serialize = serializer_mod.serialize;
pub const serializeToString = serializer_mod.serializeToString;

// Comptime generic API exports
const parse_as_mod = @import("parse_as.zig");
pub const parseAs = parse_as_mod.parseAs;
pub const Parsed = parse_as_mod.Parsed;
pub const ParseAsOptions = parse_as_mod.ParseOptions;

// Run all module tests
test {
    _ = unicode;
    _ = types;
    _ = tokenizer_mod;
    _ = parser_mod;
    _ = serializer_mod;
    _ = parse_as_mod;
}
