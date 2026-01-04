/// KDL 2.0.0 - A document language for configuration files
///
/// This library provides parsing and serialization of KDL documents.
/// See https://kdl.dev/ for the language specification.

const std = @import("std");

// Internal modules
const types = @import("types.zig");
const tokenizer_mod = @import("tokenizer.zig");
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

// Run all module tests
test {
    _ = unicode;
    _ = types;
    _ = tokenizer_mod;
}
