const std = @import("std");
const Lexer = @import("Lexer.zig");
const T = Lexer.T;
const ast = @import("ast.zig");
const Span = ast.Span;
const E = ast.E;
const S = ast.S;

const Parser = @This();

allocator: std.mem.Allocator,
lex: Lexer,
scratch_exprs: std.MultiArrayList(E) = .{},
statements: std.MultiArrayList(S) = .{},
lbp: u8 = 0,
errors: std.ArrayListUnmanaged(Error) = .{},

pub const Error = struct {
    span: Span,
    data: Data,
    context: ?Context = null,

    pub const Data = union(enum) {
        invalid_return_outside_of_procedure,
        invalid_procedure_not_top_level,
        expected_token: struct {
            expected: T,
            got: T,
        },
    };

    pub const Context = union(enum) {
        expr: E.Tag,
        stmt: S.Tag,
        custom: []const u8,

        pub fn from(context: anytype) ?Context {
            const D = @TypeOf(context);
            const data: std.builtin.Type = @typeInfo(D);

            if (data == .EnumLiteral) {
                if (@hasField(E.Tag, @tagName(context))) {
                    return Context{ .expr = context };
                }

                if (@hasField(S.Tag, @tagName(context))) {
                    return Context{ .stmt = context };
                }
            }

            if (data == .Pointer) {
                return Context{ .custom = context };
            }

            return context;
        }
    };

    pub fn format(self: Error, writer: anytype) !void {
        switch (self.data) {
            .expected_token => |data| try writer.print("Expected {s} but found {s}", .{ data.expected.symbol(), data.got.symbol() }),
            .invalid_return_outside_of_procedure => try writer.writeAll("Invalid return statement outside of procedure definition"),
            .invalid_procedure_not_top_level => try writer.writeAll("Procedure definitions must be defined at the top-level"),
        }
        if (self.context) |ctx| {
            switch (ctx) {
                .stmt => |tag| try writer.print(" when parsing {s}", .{S.symbol(tag)}),
                .expr => |tag| try writer.print(" when parsing {s}", .{E.symbol(tag)}),
                .custom => |s| try writer.print(" when parsing {s}", .{s}),
            }
        }
        try writer.writeAll(".\n");
    }
};

const ParseError = error{ParseError};

fn eat(p: *Parser, token: T, context: anytype) !void {
    if (p.lex.token != token) {
        try p.fail(Error{
            .span = p.lex.span(),
            .data = .{ .expected_token = .{ .expected = token, .got = p.lex.token } },
            .context = Error.Context.from(context),
        });
    }
    p.lex.next();
}

inline fn eatSpan(p: *Parser, token: T, context: anytype) !Span {
    const sp = p.lex.span();
    try p.eat(token, context);
    return sp;
}

fn fail(p: *Parser, e: Error) !void {
    @setCold(true);
    p.errors.append(p.allocator, e) catch unreachable;
    return error.ParseError;
}

pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
    return .{
        .lex = Lexer.init(input),
        .allocator = allocator,
    };
}

/// Null-denotion Pratt Parser implementation.
inline fn nud(p: *Parser) !E {
    switch (p.lex.token) {
        .t_string => return p.parsePrimaryExpr(.e_string),
        .t_number => return p.parsePrimaryExpr(.e_number),
        .t_ident => return p.parsePrimaryExpr(.e_ident),
        .t_lbrack => return p.parsePrimaryExpr(.e_array),
        .t_true => return p.parsePrimaryExpr(.e_true),
        .t_false => return p.parsePrimaryExpr(.e_false),

        .t_plus => {
            const start = p.lex.start;
            p.lex.next();
            var value = p.allocator.alloc(E.Data.UnaryOp, 1) catch unreachable;
            value[0] = .{ .value = try p.parseExpr() };
            return E{
                .span = .{ .start = start, .end = p.lex.start },
                .data = .{ .e_unary_pos = &value[0] },
            };
        },

        .t_minus => {
            const start = p.lex.start;
            p.lex.next();
            var value = p.allocator.alloc(E.Data.UnaryOp, 1) catch unreachable;
            value[0] = .{ .value = try p.parseExpr() };
            return E{
                .span = .{ .start = start, .end = p.lex.start },
                .data = .{ .e_unary_neg = &value[0] },
            };
        },
        .t_lparen => {
            p.lex.next();

            const value = try p.parseExpr();

            try p.eat(.t_rparen, null);

            return value;
        },
        else => |t| std.debug.panic("Unsupported: {}\n", .{t}),
    }
}

fn adjustBinding(p: *Parser) void {
    p.lbp = p.lex.token.lbp();
}

/// Assumes the `foo(` has already been parsed.
inline fn parseFnCallBody(p: *Parser) ![]E {
    var arguments = std.ArrayListUnmanaged(E){};

    while (true) {
        switch (p.lex.token) {
            .t_rparen => break,
            else => {
                arguments.append(p.allocator, try p.parseExpr()) catch unreachable;
                switch (p.lex.token) {
                    .t_comma => p.lex.next(),
                    else => break,
                }
            },
        }
    }

    try p.eat(.t_rparen, Error.Context{ .expr = .e_fn_call });

    return arguments.toOwnedSlice(p.allocator);
}

/// Parses a primary expression (ident, function call, number, string, array literal).
inline fn parsePrimaryExpr(p: *Parser, comptime known_e: E.Tag) !E {
    switch (comptime known_e) {
        .e_true => {
            const span = p.lex.span();
            p.lex.next();
            return E{ .span = span, .data = .{ .e_true = {} } };
        },
        .e_false => {
            const span = p.lex.span();
            p.lex.next();
            return E{ .span = span, .data = .{ .e_false = {} } };
        },
        .e_number => {
            const span = p.lex.span();
            p.lex.next();
            return E{ .span = span, .data = .{ .e_number = {} } };
        },
        .e_string => {
            const span = p.lex.span();
            p.lex.next();
            return E{ .span = span, .data = .{ .e_string = {} } };
        },
        .e_ident => {
            const ident = p.lex.span();
            p.lex.next();

            if (p.lex.token != .t_lparen) return E{
                .span = ident,
                .data = .{ .e_ident = {} },
            };
            p.lex.next();

            var data = p.allocator.alloc(E.Data.FnCall, 1) catch unreachable;
            data[0] = .{ .name = ident, .arguments = try p.parseFnCallBody() };

            return E{ .span = .{ .start = ident.start, .end = p.lex.start }, .data = .{ .e_fn_call = &data[0] } };
        },
        .e_fn_call => {
            const ident = p.lex.span();

            var data = p.allocator.alloc(E.Data.FnCall, 1) catch unreachable;
            data[0] = .{ .name = ident, .arguments = try p.parseFnCallBody() };

            return E{ .span = .{ .start = ident.start, .end = p.lex.start }, .data = .{ .e_fn_call = &data[0] } };
        },
        .e_array => {
            const start = p.lex.start;
            p.lex.next();

            var values = std.ArrayListUnmanaged(E){};
            while (p.lex.token != .t_rbrack) {
                values.append(p.allocator, try p.parseExpr()) catch unreachable;
                switch (p.lex.token) {
                    .t_comma => p.lex.next(),
                    .t_rbrack => break,
                    else => |t| std.debug.panic("idk: {}\n", .{t}),
                }
            }

            p.lex.next();
            var data = p.allocator.alloc(E.Data.Array, 1) catch unreachable;
            data[0] = .{ .values = values.toOwnedSlice(p.allocator) };

            return E{
                .span = .{ .start = start, .end = p.lex.start },
                .data = .{ .e_array = &data[0] },
            };
        },
        else => unreachable,
    }
}

const Denotation = enum {
    left,
    right,
};

/// Left-denotation Pratt Parser implementation.
inline fn led(p: *Parser, lhs: E) !?E {
    switch (p.lex.token) {
        .t_plus => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_add = &value[0] },
            };
        },
        .t_minus => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_sub = &value[0] },
            };
        },
        .t_asterisk => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_mul = &value[0] },
            };
        },
        .t_slash => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_div = &value[0] },
            };
        },
        .t_mod => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_mod = &value[0] },
            };
        },
        .t_eq => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_eq = &value[0] },
            };
        },
        .t_neq => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_neq = &value[0] },
            };
        },
        .t_gt => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_gt = &value[0] },
            };
        },
        .t_lt => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_lt = &value[0] },
            };
        },
        .t_gte => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_gte = &value[0] },
            };
        },
        .t_lte => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_lte = &value[0] },
            };
        },
        .t_and => {
            p.adjustBinding();
            p.lex.next();
            const rhs = try p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_and = &value[0] },
            };
        },
        else => return null,
    }
}

pub fn parseExpr(p: *Parser) ParseError!E {
    var lhs = try p.nud();
    while (p.lex.token.lbp() != 255) {
        lhs = (try p.led(lhs)) orelse break;
    }
    p.lbp = 0;
    return lhs;
}

pub fn parseStatement(p: *Parser, comptime start_token: T) !S {
    switch (comptime start_token) {
        .t_ident => {
            const ident = p.lex.span();
            p.lex.next();
            switch (p.lex.token) {
                .t_lparen => {
                    p.lex.next();
                    var data = p.allocator.alloc(struct {
                        fn_call: E.Data.FnCall,
                        expr: E,
                    }, 1) catch unreachable;
                    data[0].fn_call = .{ .name = ident, .arguments = try p.parseFnCallBody() };
                    data[0].expr = .{
                        .span = .{ .start = ident.start, .end = p.lex.start },
                        .data = .{ .e_fn_call = &data[0].fn_call },
                    };

                    return S{ .span = .{ .start = ident.start, .end = p.lex.start }, .data = .{ .s_expr = &data[0].expr } };
                },
                .t_assign => {
                    p.lex.next();
                    const value = try p.parseExpr();
                    const data = p.allocator.alloc(S.Data.Assign, 1) catch unreachable;
                    data[0] = .{ .name = ident, .value = value };
                    return S{
                        .span = .{ .start = ident.start, .end = value.span.end },
                        .data = .{ .s_assign = &data[0] },
                    };
                },
                else => |t| std.debug.panic("Unsupported: {}\n", .{t}),
            }
        },
        .t_return => {
            const start = p.lex.start;
            p.lex.next();
            const e = try p.parseExpr();
            const data = p.allocator.alloc(S.Data.Return, 1) catch unreachable;
            data[0] = .{ .value = e };
            return S{
                .span = .{ .start = start, .end = e.span.end },
                .data = .{ .s_return = &data[0] },
            };
        },
        .t_procedure => {
            const start = p.lex.start;
            p.lex.next();

            const name = try p.eatSpan(.t_ident, .s_procedure);

            try p.eat(.t_lparen, .s_procedure);

            var arguments = std.ArrayListUnmanaged(Span){};

            while (true) {
                switch (p.lex.token) {
                    .t_ident => {
                        arguments.append(p.allocator, p.lex.span()) catch {};
                        p.lex.next();
                        if (p.lex.token != .t_comma) break;
                        p.lex.next();
                    },
                    else => break,
                }
            }

            try p.eat(.t_rparen, .s_procedure);
            try p.eat(.t_lbrace, .s_procedure);

            const scope = try p.parseScope(false);

            try p.eat(.t_rbrace, .s_procedure);

            const data = p.allocator.alloc(S.Data.Procedure, 1) catch unreachable;
            data[0] = .{ .name = name, .arguments = arguments.toOwnedSlice(p.allocator), .scope = scope };

            return S{
                .span = .{ .start = start, .end = p.lex.start },
                .data = .{ .s_procedure = &data[0] },
            };
        },
        .t_if => {
            const start = p.lex.start;
            p.lex.next();

            try p.eat(.t_lparen, .s_if);

            const condition = try p.parseExpr();

            try p.eat(.t_rparen, .s_if);
            try p.eat(.t_lbrace, .s_if);

            const scope = try p.parseScope(false);

            const end0 = p.lex.offset;
            try p.eat(.t_rbrace, .s_if);

            switch (p.lex.token) {
                .t_else => {
                    p.lex.next();

                    var else_ifs = std.ArrayListUnmanaged(S.Data.If.ElseIf){};
                    var final_else: ?[]S = null;
                    var end: u32 = 0;

                    while (true) {
                        switch (p.lex.token) {
                            .t_if => {
                                p.lex.next();

                                try p.eat(.t_lparen, "an else if statement");

                                const condition_inner = try p.parseExpr();

                                try p.eat(.t_rparen, "an else if statement");
                                try p.eat(.t_lbrace, "an else if statement");

                                const scope_inner = try p.parseScope(false);

                                end = p.lex.offset;
                                try p.eat(.t_rbrace, "an else if statement");

                                else_ifs.append(p.allocator, .{
                                    .condition = condition_inner,
                                    .scope = scope_inner,
                                }) catch unreachable;

                                if (p.lex.token != .t_else) break;
                                p.lex.next();
                            },
                            .t_lbrace => {
                                p.lex.next();

                                const inner = try p.parseScope(false);

                                end = p.lex.offset;
                                try p.eat(.t_rbrace, "an else statement");

                                final_else = inner;
                                break;
                            },
                            else => break,
                        }
                    }

                    var data = p.allocator.alloc(S.Data.If, 1) catch unreachable;
                    data[0] = .{
                        .condition = condition,
                        .scope = scope,
                        .else_ifs = else_ifs.toOwnedSlice(p.allocator),
                        .@"else" = final_else,
                    };

                    return S{
                        .span = .{ .start = start, .end = end },
                        .data = .{ .s_if = &data[0] },
                    };
                },
                else => {
                    const data = p.allocator.alloc(S.Data.If, 1) catch unreachable;
                    data[0] = .{ .condition = condition, .scope = scope, .@"else" = null };

                    return S{
                        .span = .{ .start = start, .end = end0 },
                        .data = .{ .s_if = &data[0] },
                    };
                },
            }
        },
        .t_repeat => {
            const start = p.lex.start;
            p.lex.next();

            if (p.lex.token == .t_until) {
                p.lex.next();

                try p.eat(.t_lparen, .s_repeat_until);

                const condition = try p.parseExpr();

                try p.eat(.t_rparen, .s_repeat_until);
                try p.eat(.t_lbrace, .s_repeat_until);

                const scope = try p.parseScope(false);

                const end = p.lex.offset;
                try p.eat(.t_rbrace, .s_repeat_until);

                const data = p.allocator.alloc(S.Data.RepeatUntil, 1) catch unreachable;
                data[0] = .{ .condition = condition, .scope = scope };

                return S{
                    .span = .{ .start = start, .end = end },
                    .data = .{ .s_repeat_until = &data[0] },
                };
            }

            const count = try p.parseExpr();

            try p.eat(.t_times, .s_repeat_n);
            try p.eat(.t_lbrace, .s_repeat_n);

            const scope = try p.parseScope(false);

            const end = p.lex.offset;
            try p.eat(.t_rbrace, .s_repeat_n);

            const data = p.allocator.alloc(S.Data.RepeatN, 1) catch unreachable;
            data[0] = .{ .count = count, .scope = scope };

            return S{
                .span = .{ .start = start, .end = end },
                .data = .{ .s_repeat_n = &data[0] },
            };
        },
        else => |t| std.debug.panic("unknown: {}", .{t}),
    }
}

pub fn parseScope(p: *Parser, is_top_level: bool) ParseError![]S {
    var statements = std.ArrayListUnmanaged(S){};

    while (true) {
        statements.append(p.allocator, switch (p.lex.token) {
            .t_ident => try p.parseStatement(.t_ident),
            .t_number => try p.parseStatement(.t_number),
            .t_string => try p.parseStatement(.t_string),
            .t_return => blk: {
                const value = try p.parseStatement(.t_return);
                if (is_top_level) {
                    try p.fail(Error{
                        .span = value.span,
                        .data = .{ .invalid_return_outside_of_procedure = {} },
                    });
                }
                break :blk value;
            },
            .t_procedure => blk: {
                if (!is_top_level) {
                    try p.fail(Error{
                        // TODO: might want to test a better span for this
                        .span = p.lex.span(),
                        .data = .{ .invalid_procedure_not_top_level = {} },
                    });
                }
                break :blk try p.parseStatement(.t_procedure);
            },
            // TODO: proper RETURN prevention in these conditional blocks
            .t_if => try p.parseStatement(.t_if),
            .t_repeat => try p.parseStatement(.t_repeat),
            .t_rbrace => if (!is_top_level) break else std.debug.panic("Unsupported: {}\n", .{p.lex.token}),
            .t_eof => break,
            else => |t| std.debug.panic("Unsupported: {} at {d}\n", .{ t, p.lex.offset }),
        }) catch unreachable;
    }

    return statements.toOwnedSlice(p.allocator);
}
