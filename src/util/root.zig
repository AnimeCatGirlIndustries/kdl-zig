//! Utility module root.
//!
//! Re-exports shared helpers for stable module imports.

pub const constants = @import("constants.zig");
pub const formatting = @import("formatting.zig");
pub const grammar = @import("grammar.zig");
pub const boundaries = @import("boundaries.zig");
pub const numbers = @import("numbers.zig");
pub const strings = @import("strings.zig");
pub const unicode = @import("unicode.zig");

test {
    _ = constants;
    _ = formatting;
    _ = grammar;
    _ = numbers;
    _ = strings;
    _ = unicode;
}
