/// KDL 2.0.0 Comptime Generic Decoder
///
/// Parse KDL directly into Zig structs using comptime introspection.
/// Follows the `std.json` pattern for a familiar API.
///
/// ## Thread Safety
///
/// Decoding is **NOT** thread-safe for a single output struct. Each decode
/// call maintains mutable parser state. For concurrent parsing, use separate
/// output structs and source buffers.
///
/// ## Memory Ownership
///
/// When `copy_strings` is true (default), all strings are copied using the
/// provided allocator. When false, strings may reference the source buffer
/// directly—ensure the source outlives the struct.
///
/// ## Struct Field Mapping
///
/// - Top-level nodes map to struct fields by name
/// - Node arguments map to `__args: []T` field (if present)
/// - Node properties map to struct fields by property key
/// - Child nodes map to nested struct fields or `__children: []T`
///
/// ## Type Coercion
///
/// - Integers: KDL integers → Zig integer types (with range checking)
/// - Floats: KDL floats → Zig float types
/// - Strings: KDL strings → `[]const u8` (optionally borrowed or copied)
/// - Booleans: `#true`/`#false` → `bool`
/// - Optionals: `#null` → `null`, otherwise parsed value
/// - Enums: string matching enum field names
///
/// ## Usage
///
/// ```zig
/// const MyConfig = struct {
///     name: []const u8,
///     count: i32 = 0,
/// };
///
/// var config: MyConfig = .{};
/// try kdl.decode(&config, allocator, source, .{});
/// ```
const std = @import("std");
const Allocator = std.mem.Allocator;
const types = @import("types.zig");
const Value = types.Value;
const TypedValue = types.TypedValue;
const Property = types.Property;
const Node = types.Node;
const tokenizer_mod = @import("tokenizer.zig");
const Tokenizer = tokenizer_mod.Tokenizer;
const Token = tokenizer_mod.Token;
const TokenType = tokenizer_mod.TokenType;
const strings = @import("strings.zig");
const numbers = @import("numbers.zig");

/// Parse error types
pub const ParseError = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidString,
    InvalidEscape,
    DuplicateProperty,
    NestingTooDeep,
    OutOfMemory,
    TypeMismatch,
    MissingField,
    UnknownField,
    InvalidEnumValue,
};

/// Options for parsing behavior
pub const ParseOptions = struct {
    /// How to handle duplicate fields
    duplicate_field_behavior: enum { use_first, @"error", use_last } = .use_last,
    /// Whether to ignore unknown fields in structs
    ignore_unknown_fields: bool = true,
    /// Whether to always copy strings (true) or borrow when possible (false).
    /// Default true ensures safety; false allows zero-copy optimizations but requires
    /// the source buffer to outlive the struct.
    copy_strings: bool = true,
    /// Maximum nesting depth for children blocks.
    /// Protects against stack overflow from deeply nested documents.
    /// Set to `null` for unlimited (use with caution).
    max_depth: ?u16 = 256,
};

/// Parse KDL source into a caller-owned value.
/// The output is overwritten; callers should ensure existing allocations
/// are freed or zero-initialized before calling.
pub fn decode(
    out: anytype,
    allocator: Allocator,
    source: []const u8,
    options: ParseOptions,
) ParseError!void {
    const T = @typeInfo(@TypeOf(out)).pointer.child;
    var parser = Parser.init(allocator, source, options);
    try parser.parseInto(T, out);
}

// Internal Parser State
const Parser = struct {
    tokenizer: Tokenizer,
    current: Token,
    allocator: Allocator,
    options: ParseOptions,
    depth: u16 = 0,

    pub fn init(allocator: Allocator, source: []const u8, options: ParseOptions) Parser {
        var tokenizer = Tokenizer.init(source);
        const first_token = tokenizer.next();
        return .{
            .tokenizer = tokenizer,
            .current = first_token,
            .allocator = allocator,
            .options = options,
        };
    }

    fn checkAndEnterChildren(self: *Parser) ParseError!void {
        if (self.options.max_depth) |max| {
            if (self.depth >= max) {
                return ParseError.NestingTooDeep;
            }
        }
        self.depth += 1;
    }

    fn exitChildren(self: *Parser) void {
        self.depth -= 1;
    }

    fn advance(self: *Parser) void {
        self.current = self.tokenizer.next();
    }

    fn skipNodeSpace(self: *Parser) void {
        while (self.current.type == .newline) {
            self.advance();
        }
    }

    // --- Core Parsing Logic ---

    pub fn parseInto(self: *Parser, comptime T: type, out: *T) ParseError!void {
        const info = @typeInfo(T);
        switch (info) {
            .@"struct" => try self.parseStruct(T, out),
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    // Top-level slice: parse all nodes as list of items
                    // We need to re-assign the slice to point to new allocated memory
                    // out is *[]T, so out.* is []T
                    try self.parseNodesAsSlice(ptr.child, out);
                } else {
                    return ParseError.TypeMismatch;
                }
            },
            else => return ParseError.TypeMismatch,
        }
    }

    fn parseStruct(self: *Parser, comptime T: type, out: *T) ParseError!void {
        // Top-level struct parser (consumes stream of nodes)
        // Matches nodes to struct fields.
        const fields = std.meta.fields(T);
        var fields_set = [_]bool{false} ** fields.len;

        while (self.current.type != .eof) {
            if (self.current.type == .newline or self.current.type == .semicolon) {
                self.advance();
                continue;
            }

            if (self.current.type == .slashdash) {
                self.advance();
                self.skipNodeSpace();
                try self.consumeNode(true); // discard
                continue;
            }

            // Parse Node Name
            const node_name = try self.parseNodeName();
            
            // Match against fields
            var found = false;
            inline for (fields, 0..) |field, i| {
                if (std.mem.eql(u8, node_name, field.name)) {
                    found = true;
                    if (fields_set[i]) {
                        switch (self.options.duplicate_field_behavior) {
                            .use_first => {
                                // Consume and discard duplicate
                                try self.consumeNode(true); 
                                break;
                            },
                            .@"error" => return ParseError.DuplicateProperty,
                            .use_last => {
                                // Overwrite
                                try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                            },
                        }
                    } else {
                        try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                        fields_set[i] = true;
                    }
                    break;
                }
            }

            if (!found) {
                if (!self.options.ignore_unknown_fields) {
                    return ParseError.UnknownField;
                }
                // Discard unknown node content (args, props, children)
                try self.consumeNode(false); // false because name already consumed
            }
        }
    }

    fn parseNodeBodyInto(self: *Parser, comptime T: type, out: *T) ParseError!void {
        // We have consumed the node name. Now we are at args/props.
        // T is the type of the field that matched the node name.

        const info = @typeInfo(T);
        switch (info) {
            .@"struct" => try self.parseNodeAsStruct(T, out),
            .optional => |opt| {
                // Parse into a temporary, then assign to optional on success.
                // This avoids leaving the optional in a partially-initialized state on error.
                var temp: opt.child = if (@typeInfo(opt.child) == .@"struct") .{} else undefined;
                try self.parseNodeBodyInto(opt.child, &temp);
                out.* = temp;
            },
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child != u8) {
                    // It's a list of nodes `[]Child`.
                    // Since `parseStruct` calls us for EACH node match, we APPEND to this slice.
                    var item: ptr.child = if (@typeInfo(ptr.child) == .@"struct") .{} else undefined;
                    try self.parseNodeBodyInto(ptr.child, &item);
                    try self.appendToSlice(ptr.child, out, item);
                } else {
                     // String (`[]u8`) or single value pointer?
                     // Treat as simple value (first argument)
                     try self.parseSimpleValue(T, out);
                }
            },
             // Simple types: int, float, bool, enum, string
            .int, .float, .bool, .@"enum" => try self.parseSimpleValue(T, out),
            else => return ParseError.TypeMismatch,
        }
    }


    /// Append an item to a slice field.
    /// Uses ArrayList growth strategy for O(1) amortized appends.
    fn appendToSlice(self: *Parser, comptime Elem: type, slice_ptr: *[]Elem, item: Elem) ParseError!void {
        var list = std.ArrayListUnmanaged(Elem){
            .items = slice_ptr.*,
            .capacity = slice_ptr.*.len, // Slice length is our known capacity
        };
        list.append(self.allocator, item) catch return ParseError.OutOfMemory;
        slice_ptr.* = list.items;
    }

    // --- Revised ParseNodeBodyInto ---
    
    // We already consumed Node Name.
    // parseNodeBodyInto for Struct:
    // 1. Parse Args/Props.
    // 2. Parse Children.

    // Note: `parseNodeAsStruct` in previous file handled `__args` and `__children`.
    // And mapped Props -> fields.
    // And mapped Children -> fields.

    // Re-implementation of `parseNodeAsStruct`
    fn parseNodeAsStruct(self: *Parser, comptime T: type, out: *T) ParseError!void {
        const fields = std.meta.fields(T);
        var fields_set = [_]bool{false} ** fields.len;
        
        // 1. Process Args and Properties
        while (true) {
            if (self.current.type == .newline or
                self.current.type == .semicolon or
                self.current.type == .eof or
                self.current.type == .open_brace or
                self.current.type == .close_brace)
            {
                break;
            }
            
            if (self.current.type == .slashdash) {
                self.advance();
                self.skipNodeSpace();
                // Discard next arg/prop
                const dummy = try self.parseArgOrProp(false); 
                _ = dummy;
                continue;
            }

            // We need to distinguish Arg vs Prop.
            // Prop starts with `key=`. 
            // Check current token.
            
            // Check for type annotation (can be on arg or prop value)
            var type_annotation: ?[]const u8 = null;
            if (self.current.type == .open_paren) {
                type_annotation = try self.parseTypeAnnotation();
            }

            // We can't easily know if it's a property key or a value just by looking at first token
            // unless we peek.
            // BUT, property key MUST be identifier/string.
            // And followed by `=`.
            // If we parse a Value, we consume it.
            
            // Look ahead logic:
            // Tokenizer doesn't support lookahead.
            // But we can check if `first_token` is string-like.
            // If so, check if next token is `.equals`.
            // If yes, it's a property key.
            // If no, it's a value (argument).
            
            // Wait, `Parser` in `parser.zig` does:
            // `parseValue`.
            // Check if current is `.equals`.
            // If so, treats parsed value as Key.
            
            const first_val = try self.parseValue();
            
            if (self.current.type == .equals) {
                // It is a Property!
                if (type_annotation != null) return ParseError.UnexpectedToken; // Type annot on key invalid
                self.advance(); // consume =
                
                // Parse prop value
                 var prop_val_type_annot: ?[]const u8 = null;
                if (self.current.type == .open_paren) {
                    prop_val_type_annot = try self.parseTypeAnnotation();
                }
                const prop_val = try self.parseValue();
                
                // Key must be string
                const key = switch (first_val) {
                    .string => |s| s.raw,
                    else => return ParseError.UnexpectedToken,
                };
                
                // Match key to field
                var found = false;
                inline for (fields, 0..) |field, i| {
                    if (std.mem.eql(u8, key, field.name)) {
                        found = true;
                        if (fields_set[i]) {
                            switch (self.options.duplicate_field_behavior) {
                                .use_first => {}, // Ignore
                                .@"error" => return ParseError.DuplicateProperty,
                                .use_last => {
                                    // Overwrite
                                    try self.assignValue(field.type, &@field(out, field.name), prop_val);
                                },
                            }
                        } else {
                            try self.assignValue(field.type, &@field(out, field.name), prop_val);
                            fields_set[i] = true;
                        }
                        break;
                    }
                }
                if (!found and !self.options.ignore_unknown_fields) {
                    return ParseError.UnknownField;
                }

            } else {
                // It is an Argument!
                // `first_val` is the value. `type_annotation` applies.
                
                if (@hasField(T, "__args")) {
                    const ArgsFieldType = @TypeOf(@field(out, "__args"));
                    const ArgElemType = std.meta.Elem(ArgsFieldType);
                    // Append to __args - initialize with default if struct, otherwise zero
                    var parsed_arg: ArgElemType = if (@typeInfo(ArgElemType) == .@"struct") .{} else std.mem.zeroes(ArgElemType);
                    try self.assignValue(ArgElemType, &parsed_arg, first_val);
                    try self.appendToSlice(ArgElemType, &@field(out, "__args"), parsed_arg);
                }
            }
        }
        
        // 2. Process Children Block
        if (self.current.type == .open_brace) {
            try self.checkAndEnterChildren();
            defer self.exitChildren();
            self.advance(); // consume {
            
            while (self.current.type != .close_brace and self.current.type != .eof) {
                if (self.current.type == .newline or self.current.type == .semicolon) {
                    self.advance();
                    continue;
                }
                
                if (self.current.type == .slashdash) {
                    self.advance();
                    self.skipNodeSpace();
                    try self.consumeNode(true);
                    continue;
                }
                
                // Child Node
                const child_name = try self.parseNodeName();
                
                // Check __children
                var handled = false;
                if (@hasField(T, "__children")) {
                     // Parse as Node and append to __children
                     // Use `consumeNode` but capture it? 
                     // Or recursive `parseNode` from `parser.zig` logic?
                     // We don't want `parser.zig` Node. We want `T`'s child type.
                     // Usually `__children` is `[]Node` (from types.zig).
                     // If so, we need to construct a Node.
                     // This means `parseAsInto` DOES need to construct AST nodes if `__children` is used.
                     // But only then.
                     
                     // Check type of `__children`.
                     const ChildrenType = @TypeOf(@field(out, "__children"));
                     const ChildType = std.meta.Elem(ChildrenType); // likely types.Node
                     
                     // If ChildType is types.Node, we need `parser.zig` logic...
                     // Or we can manually construct Node.
                     // Let's support it via `consumeNode` variant that returns Node.
                     const node = try self.parseFullNode(child_name);
                     try self.appendToSlice(ChildType, &@field(out, "__children"), node);
                     handled = true;
                }

                // Match against fields (nested nodes)
                var found = false;
                inline for (fields, 0..) |field, i| {
                    if (std.mem.eql(u8, child_name, field.name)) {
                        found = true;
                         if (fields_set[i]) {
                             switch (self.options.duplicate_field_behavior) {
                                 .use_first => { try self.consumeNode(false); }, // Consume child node
                                 .@"error" => return ParseError.DuplicateProperty,
                                 .use_last => {
                                     // Overwrite
                                     try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                                 },
                             }
                         } else {
                             try self.parseNodeBodyInto(field.type, &@field(out, field.name));
                             fields_set[i] = true;
                         }
                         break;
                    }
                }
                
                if (!found) {
                     // Check __children (fallback)
                     if (@hasField(T, "__children") and !handled) {
                         // Parse into __children list
                         const ChildrenType = @TypeOf(@field(out, "__children"));
                         const ChildType = std.meta.Elem(ChildrenType);

                         var child_val: ChildType = if (@typeInfo(ChildType) == .@"struct") .{} else undefined;
                         try self.parseNodeBodyInto(ChildType, &child_val);
                         try self.appendToSlice(ChildType, &@field(out, "__children"), child_val);
                         handled = true;
                     }
                     
                     if (!handled) {
                        if (!self.options.ignore_unknown_fields) return ParseError.UnknownField;
                        try self.consumeNode(false); // false because name already consumed
                     }
                }
            }
            if (self.current.type == .close_brace) {
                self.advance();
            } else {
                return ParseError.UnexpectedEof;
            }
        }
    }
    
    // Assigns a `Value` (parsed from token) to a struct field of type `Target`.
    fn assignValue(self: *Parser, comptime Target: type, out: *Target, val: Value) ParseError!void {
        const info = @typeInfo(Target);
        switch (info) {
            .int => switch (val) {
                .integer => |i| out.* = std.math.cast(Target, i) orelse return ParseError.TypeMismatch,
                else => return ParseError.TypeMismatch,
            },
            .float => switch (val) {
                .float => |f| out.* = @floatCast(f.value),
                .integer => |i| out.* = @floatFromInt(i),
                .positive_inf => out.* = std.math.inf(Target),
                .negative_inf => out.* = -std.math.inf(Target),
                .nan_value => out.* = std.math.nan(Target),
                else => return ParseError.TypeMismatch,
            },
            .bool => switch (val) {
                .boolean => |b| out.* = b,
                else => return ParseError.TypeMismatch,
            },
            .pointer => |ptr| {
                 if (ptr.size == .slice and ptr.child == u8) {
                     switch (val) {
                         .string => |s| {
                             // s.raw is either borrowed from source or allocated by processString.
                             // If it's borrowed AND we want copy, duplicate.
                             // If it's allocated, we own it (via allocator).
                             // Since we don't know if s.raw is borrowed or allocated easily here (Value struct doesn't say),
                             // we rely on `parseValue` behavior.
                             // `parseValue` delegates to `strings` which takes `allocator`.
                             // If `strings` returns allocated, we are good.
                             // If `strings` returns borrowed, we might need to dupe.
                             
                             // Problem: `Value` stores `[]const u8`.
                             // `parseValue` used `self.allocator` (user provided).
                             // If `processString` allocated, it used user allocator. Safe.
                             // If `processString` borrowed, it points to source.
                             
                             if (self.options.copy_strings) {
                                 // We need to ensure it's a copy.
                                 // Check if pointer is inside source?
                                 // But `Parser` struct doesn't hold source ref easily accessible (it's in tokenizer).
                                 // Use tokenizer.source.
                                 const src = self.tokenizer.source;
                                 const s_start = @intFromPtr(s.raw.ptr);
                                 const src_start = @intFromPtr(src.ptr);
                                 const src_end = src_start + src.len;
                                 
                                 if (s_start >= src_start and s_start < src_end) {
                                     // It is borrowed. Duplicate it.
                                     out.* = self.allocator.dupe(u8, s.raw) catch return ParseError.OutOfMemory;
                                 } else {
                                     // It is already allocated (presumably).
                                     out.* = s.raw;
                                 }
                             } else {
                                 out.* = s.raw;
                             }
                         },
                         else => return ParseError.TypeMismatch,
                     }
                 } else {
                     return ParseError.TypeMismatch;
                 }
            },
            .optional => |opt| {
                switch (val) {
                    .null_value => out.* = null,
                    else => {
                        // Parse into temporary, then assign to avoid partial initialization on error
                        var temp: opt.child = if (@typeInfo(opt.child) == .@"struct") .{} else std.mem.zeroes(opt.child);
                        try self.assignValue(opt.child, &temp, val);
                        out.* = temp;
                    },
                }
            },
            .@"enum" => |e| {
                 switch (val) {
                    .string => |s| {
                        inline for (e.fields) |field| {
                            if (std.mem.eql(u8, s.raw, field.name)) {
                                out.* = @enumFromInt(field.value);
                                return;
                            }
                        }
                        return ParseError.InvalidEnumValue;
                    },
                    else => return ParseError.TypeMismatch,
                 }
            },
            else => return ParseError.TypeMismatch,
        }
    }
    
    // Parse a Simple Value (arg 0 of node) into T
    fn parseSimpleValue(self: *Parser, comptime T: type, out: *T) ParseError!void {
        // We are at Node Args.
        // Expect 1 arg.
        // Loop args/props until end, but only use first arg.
        var assigned = false;
        
        while (true) {
             if (self.current.type == .newline or
                self.current.type == .semicolon or
                self.current.type == .eof or
                self.current.type == .open_brace or
                self.current.type == .close_brace)
            {
                break;
            }
            
            if (self.current.type == .slashdash) {
                 self.advance();
                 self.skipNodeSpace();
                 _ = try self.parseArgOrProp(true);
                 continue;
            }
            
            const item = try self.parseArgOrProp(false);
            switch (item) {
                .argument => |val| {
                    if (!assigned) {
                        try self.assignValue(T, out, val.value);
                        assigned = true;
                    }
                },
                .property => {}, // Ignore properties on simple value?
            }
        }
        
        // Children on simple value?
        if (self.current.type == .open_brace) {
             // Consume and ignore? Or Error?
             // "missing field" logic implies we just needed the value.
             try self.consumeChildrenBlock(); 
        }
        
        if (!assigned) return ParseError.MissingField;
    }
    
    // --- Low Level Parsing Helpers ---

    fn parseNodeName(self: *Parser) ParseError![]const u8 {
         if (self.current.type == .open_paren) {
             _ = try self.parseTypeAnnotation();
         }
         return self.parseStringValue();
    }
    
    fn parseTypeAnnotation(self: *Parser) ParseError![]const u8 {
        self.advance(); // (
        const type_name = try self.parseStringValue();
        if (self.current.type != .close_paren) return ParseError.UnexpectedToken;
        self.advance(); // )
        return type_name;
    }
    
    fn parseStringValue(self: *Parser) ParseError![]const u8 {
        const token = self.current;
        self.advance();
        return switch (token.type) {
            .identifier => token.text,
            .quoted_string => strings.processQuotedString(self.allocator, token.text) catch return ParseError.InvalidString,
            .raw_string => strings.processRawString(self.allocator, token.text) catch return ParseError.InvalidString,
            .multiline_string => strings.processMultilineString(self.allocator, token.text) catch return ParseError.InvalidString,
            else => ParseError.UnexpectedToken,
        };
    }

    fn parseValue(self: *Parser) ParseError!Value {
         const token = self.current;
         self.advance();
         return switch (token.type) {
             .identifier => Value{ .string = .{ .raw = token.text } },
             .quoted_string => Value{ .string = .{ .raw = try strings.processQuotedString(self.allocator, token.text) } },
             .raw_string => Value{ .string = .{ .raw = try strings.processRawString(self.allocator, token.text) } },
             .multiline_string => Value{ .string = .{ .raw = try strings.processMultilineString(self.allocator, token.text) } },
             .integer => Value{ .integer = try numbers.parseDecimalInteger(self.allocator, token.text) },
             .float => Value{ .float = blk: {
                 const res = try numbers.parseFloat(self.allocator, token.text);
                 break :blk .{ .value = res.value, .original = res.original };
             }},
             .hex_integer => Value{ .integer = try numbers.parseRadixInteger(self.allocator, token.text, 2, 16) },
             .octal_integer => Value{ .integer = try numbers.parseRadixInteger(self.allocator, token.text, 2, 8) },
             .binary_integer => Value{ .integer = try numbers.parseRadixInteger(self.allocator, token.text, 2, 2) },
             .keyword_true => Value{ .boolean = true },
             .keyword_false => Value{ .boolean = false },
             .keyword_null => Value{ .null_value = {} },
             .keyword_inf => Value{ .positive_inf = {} },
             .keyword_neg_inf => Value{ .negative_inf = {} },
             .keyword_nan => Value{ .nan_value = {} },
             else => ParseError.UnexpectedToken,
         };
    }

    const ArgOrProp = union(enum) {
        argument: TypedValue,
        property: Property,
    };

    fn parseArgOrProp(self: *Parser, discard: bool) ParseError!ArgOrProp {
        // Discard mode: consume tokens but don't allocate/parse deeply if possible.
        // For now, normal parse then discard is fine.
        
        var type_annot: ?[]const u8 = null;
        if (self.current.type == .open_paren) {
            type_annot = try self.parseTypeAnnotation();
        }
        
        const first_val = try self.parseValue();
        
        if (self.current.type == .equals) {
             // Property
             if (type_annot != null) return ParseError.UnexpectedToken;
             self.advance(); // =
             
             var val_annot: ?[]const u8 = null;
             if (self.current.type == .open_paren) {
                 val_annot = try self.parseTypeAnnotation();
             }
             const val = try self.parseValue();
             
             if (discard) return .{ .argument = undefined }; // dummy
             
             const key = switch (first_val) {
                 .string => |s| s.raw,
                 else => return ParseError.UnexpectedToken,
             };
             
             return .{ .property = .{ .name = key, .value = val, .type_annotation = val_annot } };
        } else {
             // Argument
             if (discard) return .{ .argument = undefined };
             
             return .{ .argument = .{ .value = first_val, .type_annotation = type_annot } };
        }
    }

    fn consumeNode(self: *Parser, name_consumed: bool) ParseError!void {
        if (!name_consumed) {
             _ = try self.parseNodeName();
        }
        
        // Consume args/props
        while (true) {
             if (self.current.type == .newline or
                self.current.type == .semicolon or
                self.current.type == .eof or
                self.current.type == .open_brace or
                self.current.type == .close_brace)
            {
                break;
            }
            if (self.current.type == .slashdash) {
                 self.advance();
                 self.skipNodeSpace();
                 _ = try self.parseArgOrProp(true);
                 continue;
            }
            _ = try self.parseArgOrProp(true);
        }
        
        if (self.current.type == .open_brace) {
             try self.consumeChildrenBlock();
        }
    }
    
    fn consumeChildrenBlock(self: *Parser) ParseError!void {
        try self.checkAndEnterChildren();
        defer self.exitChildren();
        self.advance(); // {
        while (self.current.type != .close_brace and self.current.type != .eof) {
            if (self.current.type == .newline or self.current.type == .semicolon) {
                self.advance();
                continue;
            }
            if (self.current.type == .slashdash) {
                self.advance();
                self.skipNodeSpace();
                try self.consumeNode(true);
                continue;
            }
            try self.consumeNode(false);
        }
        if (self.current.type == .close_brace) self.advance();
    }
    
    fn parseNodesAsSlice(self: *Parser, comptime T: type, out: *[]T) ParseError!void {
         var list: std.ArrayListUnmanaged(T) = .{};
         // We iterate nodes in the stream.
         while (self.current.type != .eof) {
             if (self.current.type == .newline or self.current.type == .semicolon) {
                 self.advance();
                 continue;
             }
             if (self.current.type == .slashdash) {
                 self.advance();
                 self.skipNodeSpace();
                 try self.consumeNode(true);
                 continue;
             }
             
             // Parse into T
             // We need to parse the node name first?
             // If T is struct, it expects Node Name to match?
             // But here we are parsing "Any Node" into T.
             // Unlike `parseStruct` which filters by name, `parseNodesAsSlice` (top level)
             // just consumes whatever nodes come and parses them into T.
             
             // Issue: `parseNodeBodyInto` assumes Name is consumed. 
             // But `parseNodeAsStruct` logic (nested) relied on Name matching.
             
             // If T is a struct representing a Node:
             // It likely has a field for the Name?
             // KDL structs usually imply the struct IS the node contents.
             // The Name itself is often implicit or matched.
             // If we want to capture the Name, we need a special field `__name`?
             
             // Current `parseAsInto([]Item)` test:
             // `item 1; item 2;`
             // struct Item { __args: []i32 }
             // The name "item" is NOT in the struct.
             
             // So: consume name, ignore it (or verify it?), parse body into T.
             _ = try self.parseNodeName();

             // Initialize with defaults if struct, otherwise zero
             var item: T = if (@typeInfo(T) == .@"struct") .{} else std.mem.zeroes(T);
             try self.parseNodeBodyInto(T, &item);
             try list.append(self.allocator, item);
         }
         out.* = try list.toOwnedSlice(self.allocator);
    }
    
    // Helper to reconstruct full Node AST (for __children fallback)
    fn parseFullNode(self: *Parser, name: []const u8) ParseError!Node {
         // Create Node
         var args: std.ArrayListUnmanaged(TypedValue) = .{};
         var props: std.ArrayListUnmanaged(Property) = .{};
         var children: std.ArrayListUnmanaged(Node) = .{};
         
         // Parse Args/Props
         while (true) {
             if (self.current.type == .newline or
                self.current.type == .semicolon or
                self.current.type == .eof or
                self.current.type == .open_brace or
                self.current.type == .close_brace) break;

             if (self.current.type == .slashdash) {
                 self.advance();
                 self.skipNodeSpace();
                 _ = try self.parseArgOrProp(true);
                 continue;
             }
             
             const item = try self.parseArgOrProp(false);
             switch (item) {
                 .argument => |a| try args.append(self.allocator, a),
                 .property => |p| try props.append(self.allocator, p),
             }
         }
         
         if (self.current.type == .open_brace) {
             try self.checkAndEnterChildren();
             defer self.exitChildren();
             self.advance();
             while (self.current.type != .close_brace and self.current.type != .eof) {
                 if (self.current.type == .newline or self.current.type == .semicolon) {
                     self.advance();
                     continue;
                 }
                 if (self.current.type == .slashdash) {
                     self.advance();
                     self.skipNodeSpace();
                     try self.consumeNode(true);
                     continue;
                 }
                 const child_name = try self.parseNodeName();
                 const child = try self.parseFullNode(child_name);
                 try children.append(self.allocator, child);
             }
             if (self.current.type == .close_brace) self.advance();
         }

         return Node{
             .name = name,
             .arguments = try args.toOwnedSlice(self.allocator),
             .properties = try props.toOwnedSlice(self.allocator),
             .children = try children.toOwnedSlice(self.allocator),
         };
    }
};

// ... Tests (same as before) ...

test "decode simple struct" {

    const Config = struct {

        name: []const u8 = "",

        count: i32 = 0,

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var result: Config = .{};

    try decode(&result, arena.allocator(),

        \\name "test"

        \\count 42

    , .{});



    try std.testing.expectEqualStrings("test", result.name);

    try std.testing.expectEqual(@as(i32, 42), result.count);

}



test "decode copies bare identifier strings" {

    const Config = struct {

        name: []const u8 = "",

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var source: [10]u8 = "name value".*;

    var result: Config = .{};

    try decode(&result, arena.allocator(), source[0..], .{});



    source[5] = 'X';

    try std.testing.expectEqualStrings("value", result.name);

}



test "decode float values" {

    const Config = struct {

        number: f64 = 0,

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var result: Config = .{};

    try decode(&result, arena.allocator(),

        \\number 1.5e2

    , .{});



    try std.testing.expectApproxEqAbs(@as(f64, 150.0), result.number, 0.0001);

}



test "decode nested struct" {

    const Inner = struct {

        value: i32 = 0,

    };



    const Outer = struct {

        inner: ?Inner = null,

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var result: Outer = .{};

    try decode(&result, arena.allocator(),

        \\inner {

        \\    value 123

        \\}

    , .{});



    try std.testing.expectEqual(@as(i32, 123), result.inner.?.value);

}



test "decode with properties" {

    const Person = struct {

        name: []const u8 = "",

        age: i32 = 0,

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var result: Person = .{};

    try decode(&result, arena.allocator(),

        \\name "Alice"

        \\age 30

    , .{});



    try std.testing.expectEqualStrings("Alice", result.name);

    try std.testing.expectEqual(@as(i32, 30), result.age);

}



test "decode optional fields" {

    const Config = struct {

        required: i32 = 0,

        optional: ?i32 = null,

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var result: Config = .{};

    try decode(&result, arena.allocator(),

        \\required 42

    , .{});



    try std.testing.expectEqual(@as(i32, 42), result.required);

    try std.testing.expectEqual(@as(?i32, null), result.optional);

}



test "decode array of nodes" {

    const Item = struct {

        __args: []i32 = &.{},

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var result: []Item = &[_]Item{};

    try decode(&result, arena.allocator(),

        \\item 1

        \\item 2

        \\item 3

    , .{});



    try std.testing.expectEqual(@as(usize, 3), result.len);

}



test "decode boolean values" {

    const Config = struct {

        enabled: bool = false,

        disabled: bool = true,

    };



    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);

    defer arena.deinit();



    var result: Config = .{};

    try decode(&result, arena.allocator(),

        \\enabled #true

        \\disabled #false

    , .{});



    try std.testing.expect(result.enabled);

    try std.testing.expect(!result.disabled);

}
