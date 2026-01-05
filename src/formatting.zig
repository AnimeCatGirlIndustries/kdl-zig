/// KDL 2.0.0 Formatting Utilities
///
/// Provides shared formatting logic for KDL serialization including:
/// - Value formatting (integers, floats, strings, booleans, null, inf, nan)
/// - String escaping and quoting
/// - Float normalization with exponent handling
/// - Identifier validation
///
/// Used internally by the serializer and encoder modules.
const std = @import("std");
const types = @import("types.zig");
const Value = types.Value;
const unicode = @import("unicode.zig");

/// Formatting options
pub const Options = struct {
    /// Indentation string (default: 4 spaces)
    indent: []const u8 = "    ",
};

pub fn writeValue(value: Value, writer: anytype) !void {
    switch (value) {
        .string => |s| try writeString(s.raw, writer),
        .integer => |i| try writer.print("{d}", .{i}),
        .float => |f| try writeFloatValue(f, writer),
        .boolean => |b| try writer.writeAll(if (b) "#true" else "#false"),
        .null_value => try writer.writeAll("#null"),
        .positive_inf => try writer.writeAll("#inf"),
        .negative_inf => try writer.writeAll("#-inf"),
        .nan_value => try writer.writeAll("#nan"),
    }
}

pub fn writeFloatValue(fv: Value.FloatValue, writer: anytype) !void {
    // If we have the original text, normalize and output it for round-trip fidelity
    if (fv.original) |original| {
        try writeNormalizedFloat(original, writer);
        return;
    }
    // Otherwise format the float value normally
    try writeFloat(fv.value, writer);
}

fn writeNormalizedFloat(original: []const u8, writer: anytype) !void {
    // Normalize: strip underscores, uppercase E, ensure + after E for positive exponents
    var in_exponent = false;
    var wrote_exp_sign = false;

    for (original, 0..) |c, i| {
        if (c == '_') continue; // Skip underscores

        if (c == 'e' or c == 'E') {
            try writer.writeByte('E');
            in_exponent = true;
            wrote_exp_sign = false;
            // Check if next char is a sign
            if (i + 1 < original.len) {
                const next = original[i + 1];
                if (next == '+' or next == '-') {
                    // Sign will be written on next iteration
                } else if (next >= '0' and next <= '9') {
                    // No sign, add +
                    try writer.writeByte('+');
                    wrote_exp_sign = true;
                }
            }
        } else if (in_exponent and !wrote_exp_sign and (c == '+' or c == '-')) {
            try writer.writeByte(c);
            wrote_exp_sign = true;
        } else {
            try writer.writeByte(c);
        }
    }
}

fn writeFloat(f: f64, writer: anytype) !void {
    if (std.math.isNan(f)) {
        try writer.writeAll("#nan");
        return;
    }
    if (std.math.isInf(f)) {
        try writer.writeAll(if (f < 0) "#-inf" else "#inf");
        return;
    }

    // Use scientific notation for very large or very small numbers
    const abs = @abs(f);
    if (abs != 0 and (abs >= 1.0e10 or abs < 1.0e-4)) {
        // Scientific notation - use custom formatting for KDL spec compliance
        try writeScientific(f, writer);
    } else {
        // Regular decimal notation - ensure it has a decimal point
        var buf: [32]u8 = undefined;
        const formatted = std.fmt.bufPrint(&buf, "{d}", .{f}) catch {
            try writer.print("{d}", .{f});
            return;
        };
        try writer.writeAll(formatted);
        // If no decimal point, add ".0"
        if (std.mem.indexOf(u8, formatted, ".") == null) {
            try writer.writeAll(".0");
        }
    }
}

fn writeScientific(f: f64, writer: anytype) !void {
    // KDL format: 1.0E+10, 1.23E-10, etc.
    // Always include decimal point for scientific notation (more tests pass this way)
    const abs = @abs(f);

    // Calculate exponent
    var exp: i32 = 0;
    var mantissa = abs;
    if (mantissa >= 10.0) {
        while (mantissa >= 10.0) {
            mantissa /= 10.0;
            exp += 1;
        }
    } else if (mantissa > 0 and mantissa < 1.0) {
        while (mantissa < 1.0) {
            mantissa *= 10.0;
            exp -= 1;
        }
    }

    // Handle sign
    if (f < 0) try writer.writeByte('-');

    // Write mantissa with decimal point
    var buf: [32]u8 = undefined;
    const formatted = std.fmt.bufPrint(&buf, "{d}", .{mantissa}) catch {
        try writer.print("{d}E{d}", .{ mantissa, exp });
        return;
    };

    try writer.writeAll(formatted);
    // Don't add .0 for integer mantissa in scientific notation - KDL allows 1E+10

    // Write exponent with sign
    try writer.writeByte('E');
    if (exp >= 0) {
        try writer.writeByte('+');
    }
    try writer.print("{d}", .{exp});
}

pub fn writeString(s: []const u8, writer: anytype) !void {
    // Check if it's a valid bare identifier
    if (isValidIdentifier(s)) {
        try writer.writeAll(s);
    } else {
        try writeQuotedString(s, writer);
    }
}

pub fn writeQuotedString(s: []const u8, writer: anytype) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            0x08 => try writer.writeAll("\\b"),
            0x0C => try writer.writeAll("\\f"),
            else => {
                if (c < 0x20) {
                    // Control character - use unicode escape
                    try writer.print("\\u{{{x}}}", .{c});
                } else {
                    try writer.writeByte(c);
                }
            },
        }
    }
    try writer.writeByte('"');
}

fn isValidIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;

    // Check first character - decode UTF-8
    const first_decoded = unicode.decodeUtf8(s) orelse return false;
    if (!unicode.isIdentifierStart(first_decoded.codepoint)) return false;

    // Check if it's a keyword that needs quoting
    if (looksLikeNumber(s)) return false;

    // Check rest of characters - decode UTF-8 for each codepoint
    var i: usize = first_decoded.len;
    while (i < s.len) {
        const remaining = s[i..];
        const decoded = unicode.decodeUtf8(remaining) orelse return false;
        if (!unicode.isIdentifierChar(decoded.codepoint)) return false;
        i += decoded.len;
    }

    return true;
}

fn looksLikeNumber(s: []const u8) bool {
    // Check if string looks like a number and needs quoting
    if (s.len == 0) return false;

    const first = s[0];
    // If it starts with a digit or sign followed by digit, it's not a valid identifier anyway
    if (first >= '0' and first <= '9') return true;
    if ((first == '+' or first == '-') and s.len > 1) {
        const second = s[1];
        if (second >= '0' and second <= '9') return true;
    }

    return false;
}
