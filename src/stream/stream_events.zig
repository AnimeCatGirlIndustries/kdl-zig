/// Streaming event types with zero-copy string views.
///
/// String views are borrowed from the parser's input buffer and are only
/// guaranteed to remain valid until the next event is emitted.
/// Sinks that need longer-lived data must copy.

/// String token kind for stream events.
pub const StringKind = enum {
    identifier,
    quoted_string,
    raw_string,
    multiline_string,
};

/// View of a string token in the source.
pub const StringView = struct {
    text: []const u8,
    kind: StringKind,
};

/// Value representation for streaming events.
pub const ValueView = union(enum) {
    string: StringView,
    integer: i128,
    float: struct {
        value: f64,
        original: []const u8,
    },
    boolean: bool,
    null_value: void,
    positive_inf: void,
    negative_inf: void,
    nan_value: void,
};

/// Events emitted by the stream kernel.
pub const Event = union(enum) {
    start_node: struct {
        name: StringView,
        type_annotation: ?StringView = null,
    },
    end_node,
    argument: struct {
        value: ValueView,
        type_annotation: ?StringView = null,
    },
    property: struct {
        name: StringView,
        value: ValueView,
        type_annotation: ?StringView = null,
    },
};
