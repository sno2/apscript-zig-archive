const std = @import("std");

/// A reference to some text from the source.
pub const Span = struct {
    start: u32,
    end: u32,
};

/// Statement
pub const S = struct {
    span: Span,
    data: Data,

    pub const Data = union(enum) {
        s_assign: *Assign,
        s_expr: *E,
        s_procedure: *Procedure,
        s_return: *Return,
        s_if: *If,
        s_repeat_n: *RepeatN,
        s_repeat_until: *RepeatUntil,

        pub const Assign = struct {
            name: Span,
            value: E,
        };

        pub const Procedure = struct {
            name: Span,
            arguments: []Span,
            scope: []S,
        };

        pub const Return = struct {
            value: E,
        };

        pub const If = struct {
            condition: E,
            scope: []S,
            @"else": ?[]S,
        };

        pub const RepeatN = struct {
            count: E,
            scope: []S,
        };

        pub const RepeatUntil = struct {
            condition: E,
            scope: []S,
        };

        comptime {
            if (@sizeOf(Data) != @sizeOf(*const u8) * 2) {
                @compileError(std.fmt.comptimePrint("{} != {}", .{ @sizeOf(Data), @sizeOf(*const u8) * 2 }));
            }
        }
    };
};

/// Expression
pub const E = struct {
    span: Span,
    data: Data,

    pub const Tag = enum(u8) {
        e_bin_add,
        e_bin_sub,
        e_bin_mul,
        e_bin_div,
        e_bin_eq,
        e_bin_neq,
        e_bin_gt,
        e_bin_lt,
        e_bin_gte,
        e_bin_lte,

        e_unary_pos,
        e_unary_neg,

        e_fn_call,
        e_ident,
        e_array,
        e_number,
        e_string,
        e_true,
        e_false,
    };

    pub const Data = union(Tag) {
        e_bin_add: *BinaryOp,
        e_bin_sub: *BinaryOp,
        e_bin_mul: *BinaryOp,
        e_bin_div: *BinaryOp,
        e_bin_eq: *BinaryOp,
        e_bin_neq: *BinaryOp,
        e_bin_gt: *BinaryOp,
        e_bin_lt: *BinaryOp,
        e_bin_gte: *BinaryOp,
        e_bin_lte: *BinaryOp,

        e_unary_pos: *UnaryOp,
        e_unary_neg: *UnaryOp,

        e_fn_call: *FnCall,
        e_ident,
        e_array: *Array,
        e_number,
        e_string,
        e_true,
        e_false,

        pub const BinaryOp = struct {
            lhs: E,
            rhs: E,
        };

        pub const UnaryOp = struct {
            value: E,
        };

        pub const FnCall = struct {
            name: Span,
            arguments: []E,
        };

        pub const Array = struct {
            values: []E,
        };

        comptime {
            if (@sizeOf(@This()) != @sizeOf(*const u8) * 2) {
                @compileError("Should be the size of two pointers.");
            }
        }
    };
};
