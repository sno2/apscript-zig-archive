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

    pub const Tag = std.meta.Tag(Data);

    pub fn symbol(tag: Tag) []const u8 {
        return switch (tag) {
            .s_assign => "an assignment statement",
            .s_expr => "an expression statement",
            .s_procedure => "a procedure statement",
            .s_return => "a return statement",
            .s_if => "an if statement",
            .s_repeat_n => "a repeat statement",
            .s_repeat_until => "a repeat until statement",
        };
    }

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
            else_ifs: []ElseIf = &.{},
            @"else": ?[]S = null,

            pub const ElseIf = struct {
                condition: E,
                scope: []S,
            };
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

    pub const Tag = std.meta.Tag(Data);

    pub fn symbol(tag: Tag) []const u8 {
        return switch (tag) {
            .e_bin_add => "an addition operation",
            .e_bin_sub => "a subtraction operation",
            .e_bin_mul => "a multiplication operation",
            .e_bin_div => "a division operation",
            .e_bin_mod => "a modulus operation",
            .e_bin_eq => "an equals comparison",
            .e_bin_neq => "a not equals comparison",
            .e_bin_gt => "a greater than comparison",
            .e_bin_lt => "a less than comparison",
            .e_bin_gte => "a greater than or equal to comparison",
            .e_bin_lte => "a less than or equal to comparison",
            .e_bin_and => "an and comparison",

            .e_unary_pos => "a positive expression",
            .e_unary_neg => "a negation expression",

            .e_fn_call => "a function call",
            .e_ident => "an identifier",
            .e_array => "an array literal",
            .e_number => "a number literal",
            .e_string => "a string literal",
            .e_true => "true",
            .e_false => "false",
        };
    }

    pub const Data = union(enum) {
        e_bin_add: *BinaryOp,
        e_bin_sub: *BinaryOp,
        e_bin_mul: *BinaryOp,
        e_bin_div: *BinaryOp,
        e_bin_mod: *BinaryOp,
        e_bin_eq: *BinaryOp,
        e_bin_neq: *BinaryOp,
        e_bin_gt: *BinaryOp,
        e_bin_lt: *BinaryOp,
        e_bin_gte: *BinaryOp,
        e_bin_lte: *BinaryOp,
        e_bin_and: *BinaryOp,

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
