//! Streaming module root.
//!
//! Re-exports stream components for stable module imports.

pub const stream_types = @import("types");
pub const stream_tokenizer = @import("stream_tokenizer.zig");
pub const stream_parser = @import("stream_parser.zig");
pub const stream_iterator = @import("stream_iterator.zig");
pub const stream_serializer = @import("stream_serializer.zig");
pub const stream_decoder = @import("stream_decoder.zig");
pub const stream_encoder = @import("stream_encoder.zig");
pub const stream_kernel = @import("stream_kernel.zig");
pub const stream_events = @import("events");
pub const virtual_document = @import("virtual_document.zig");
pub const value_builder = @import("values");

test {
    _ = stream_types;
    _ = stream_tokenizer;
    _ = stream_parser;
    _ = stream_iterator;
    _ = stream_serializer;
    _ = stream_decoder;
    _ = stream_encoder;
    _ = stream_kernel;
    _ = stream_events;
    _ = virtual_document;
    _ = value_builder;
}
