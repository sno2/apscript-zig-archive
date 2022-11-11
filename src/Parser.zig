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

pub fn init(allocator: std.mem.Allocator, input: []const u8) Parser {
    return .{
        .lex = Lexer.init(input),
        .allocator = allocator,
    };
}

/// Null-denotion Pratt Parser implementation.
inline fn nud(p: *Parser) E {
    switch (p.lex.token) {
        .t_string => return p.parsePrimaryExpr(.e_string),
        .t_number => return p.parsePrimaryExpr(.e_number),
        .t_ident => return p.parsePrimaryExpr(.e_ident),
        .t_lbrack => return p.parsePrimaryExpr(.e_array),
        .t_true => return p.parsePrimaryExpr(.e_true),
        .t_false => return p.parsePrimaryExpr(.e_false),

        .t_plus => {
            const span = .{ .start = p.lex.start, .end = p.lex.offset };
            p.lex.next();
            var value = p.allocator.alloc(E.Data.UnaryOp, 1) catch unreachable;
            value[0] = .{ .value = p.parseExpr() };
            return .{
                .span = span,
                .data = .{ .e_unary_pos = &value[0] },
            };
        },

        .t_minus => {
            const span = .{ .start = p.lex.start, .end = p.lex.offset };
            p.lex.next();
            var value = p.allocator.alloc(E.Data.UnaryOp, 1) catch unreachable;
            value[0] = .{ .value = p.parseExpr() };
            return .{
                .span = span,
                .data = .{ .e_unary_neg = &value[0] },
            };
        },
        else => |t| std.debug.panic("Unsupported: {}\n", .{t}),
    }
}

fn adjustBinding(p: *Parser) void {
    p.lbp = p.lex.token.lbp();
}

/// Assumes the `foo(` has already been parsed.
inline fn parseFnCallBody(p: *Parser) []E {
    var arguments = std.ArrayListUnmanaged(E){};

    while (true) {
        switch (p.lex.token) {
            .t_rparen => break,
            else => {
                arguments.append(p.allocator, p.parseExpr()) catch unreachable;
                switch (p.lex.token) {
                    .t_comma => p.lex.next(),
                    else => break,
                }
            },
        }
    }

    if (p.lex.token != .t_rparen) @panic("Expected closing parenthesis for function call.");
    p.lex.next();

    return arguments.toOwnedSlice(p.allocator);
}

/// Parses a primary expression (ident, function call, number, string, array literal).
inline fn parsePrimaryExpr(p: *Parser, comptime known_e: E.Tag) E {
    switch (comptime known_e) {
        .e_true => {
            const span = p.lex.span();
            p.lex.next();
            return .{ .span = span, .data = .{ .e_true = {} } };
        },
        .e_false => {
            const span = p.lex.span();
            p.lex.next();
            return .{ .span = span, .data = .{ .e_false = {} } };
        },
        .e_number => {
            const span = p.lex.span();
            p.lex.next();
            return .{ .span = span, .data = .{ .e_number = {} } };
        },
        .e_string => {
            const span = p.lex.span();
            p.lex.next();
            return .{ .span = span, .data = .{ .e_string = {} } };
        },
        .e_ident => {
            const ident = p.lex.span();
            p.lex.next();

            if (p.lex.token != .t_lparen) return .{
                .span = ident,
                .data = .{ .e_ident = {} },
            };
            p.lex.next();

            var data = p.allocator.alloc(E.Data.FnCall, 1) catch unreachable;
            data[0] = .{ .name = ident, .arguments = p.parseFnCallBody() };

            return .{ .span = .{ .start = ident.start, .end = p.lex.start }, .data = .{ .e_fn_call = &data[0] } };
        },
        .e_fn_call => {
            const ident = p.lex.span();

            var data = p.allocator.alloc(E.Data.FnCall, 1) catch unreachable;
            data[0] = .{ .name = ident, .arguments = p.parseFnCallBody() };

            return .{ .span = .{ .start = ident.start, .end = p.lex.start }, .data = .{ .e_fn_call = &data[0] } };
        },
        .e_array => {
            const start = p.lex.start;
            p.lex.next();

            var values = std.ArrayListUnmanaged(E){};
            while (p.lex.token != .t_rbrack) {
                values.append(p.allocator, p.parseExpr()) catch unreachable;
                switch (p.lex.token) {
                    .t_comma => p.lex.next(),
                    .t_rbrack => break,
                    else => |t| std.debug.panic("idk: {}\n", .{t}),
                }
            }

            p.lex.next();
            var data = p.allocator.alloc(E.Data.Array, 1) catch unreachable;
            data[0] = .{ .values = values.toOwnedSlice(p.allocator) };

            return .{
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
inline fn led(p: *Parser, lhs: E) ?E {
    switch (p.lex.token) {
        .t_plus => {
            p.adjustBinding();
            p.lex.next();
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
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
            const rhs = p.parseExpr();
            var value = p.allocator.alloc(E.Data.BinaryOp, 1) catch unreachable;
            value[0] = .{ .lhs = lhs, .rhs = rhs };
            return E{
                .span = .{ .start = lhs.span.start, .end = rhs.span.end },
                .data = .{ .e_bin_lte = &value[0] },
            };
        },
        else => return null,
    }
}

pub fn parseExpr(p: *Parser) E {
    var lhs = p.nud();
    while (p.lex.token.lbp() != 255) {
        lhs = p.led(lhs) orelse break;
    }
    p.lbp = 0;
    return lhs;
}

pub fn parseStatement(p: *Parser, comptime start_token: T) S {
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
                    data[0].fn_call = .{ .name = ident, .arguments = p.parseFnCallBody() };
                    data[0].expr = .{
                        .span = .{ .start = ident.start, .end = p.lex.start },
                        .data = .{ .e_fn_call = &data[0].fn_call },
                    };

                    return .{ .span = .{ .start = ident.start, .end = p.lex.start }, .data = .{ .s_expr = &data[0].expr } };
                },
                .t_assign => {
                    p.lex.next();
                    const value = p.parseExpr();
                    const data = p.allocator.alloc(S.Data.Assign, 1) catch unreachable;
                    data[0] = .{ .name = ident, .value = value };
                    return .{
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
            const e = p.parseExpr();
            const data = p.allocator.alloc(S.Data.Return, 1) catch unreachable;
            data[0] = .{ .value = e };
            return .{
                .span = .{ .start = start, .end = e.span.end },
                .data = .{ .s_return = &data[0] },
            };
        },
        .t_procedure => {
            const start = p.lex.start;
            p.lex.next();

            const name = switch (p.lex.token) {
                .t_ident => p.lex.span(),
                else => @panic("Expected procedure name."),
            };
            p.lex.next();

            switch (p.lex.token) {
                .t_lparen => p.lex.next(),
                else => @panic("Expected procedure arguments start."),
            }

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

            if (p.lex.token != .t_rparen) {
                @panic("Expected closing parenthesis to close the procedure arguments.");
            }
            p.lex.next();

            if (p.lex.token != .t_lbrace) {
                @panic("Expected an opening curly brace to start the procedure body.");
            }
            p.lex.next();

            const scope = p.parseScope(false);

            if (p.lex.token != .t_rbrace) {
                @panic("Expected a clsoing curly brace to end the procedure body.");
            }
            p.lex.next();

            const data = p.allocator.alloc(S.Data.Procedure, 1) catch unreachable;
            data[0] = .{ .name = name, .arguments = arguments.toOwnedSlice(p.allocator), .scope = scope };

            return .{
                .span = .{ .start = start, .end = p.lex.start },
                .data = .{ .s_procedure = &data[0] },
            };
        },
        .t_if => {
            const start = p.lex.start;
            p.lex.next();

            if (p.lex.token != .t_lparen) {
                @panic("Expected an opening parenthesis for the if statement condition.");
            }
            p.lex.next();

            const condition = p.parseExpr();

            if (p.lex.token != .t_rparen) {
                @panic("Expected a closing parenthesis for the if statement condition.");
            }
            p.lex.next();

            if (p.lex.token != .t_lbrace) {
                @panic("Expected an opening curly brace for the if statement body.");
            }
            p.lex.next();

            const scope = p.parseScope(false);

            if (p.lex.token != .t_rbrace) {
                @panic("Expected a closing curly brace for the if statement body.");
            }
            const end0 = p.lex.offset;
            p.lex.next();

            switch (p.lex.token) {
                .t_else => {
                    p.lex.next();
                    const data = p.allocator.alloc(S.Data.If, 1) catch unreachable;

                    if (p.lex.token != .t_lbrace) @panic(".");
                    p.lex.next();
                    const inner = p.parseScope(false);
                    if (p.lex.token != .t_rbrace) @panic(".");
                    const end = p.lex.offset;
                    p.lex.next();
                    data[0] = .{ .condition = condition, .scope = scope, .@"else" = inner };

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

                if (p.lex.token != .t_lparen) @panic(".");
                p.lex.next();

                const condition = p.parseExpr();

                if (p.lex.token != .t_rparen) @panic(".");
                p.lex.next();

                if (p.lex.token != .t_lbrace) @panic(".");
                p.lex.next();

                const scope = p.parseScope(false);

                if (p.lex.token != .t_rbrace) @panic(".");
                const end = p.lex.offset;
                p.lex.next();

                const data = p.allocator.alloc(S.Data.RepeatUntil, 1) catch unreachable;
                data[0] = .{ .condition = condition, .scope = scope };

                return S{
                    .span = .{ .start = start, .end = end },
                    .data = .{ .s_repeat_until = &data[0] },
                };
            }

            const count = p.parseExpr();

            if (p.lex.token != .t_times) @panic(".");
            p.lex.next();

            if (p.lex.token != .t_lbrace) @panic(".");
            p.lex.next();

            const scope = p.parseScope(false);

            if (p.lex.token != .t_rbrace) @panic(".");
            const end = p.lex.offset;
            p.lex.next();

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

pub fn parseScope(p: *Parser, is_top_level: bool) []S {
    var statements = std.ArrayListUnmanaged(S){};

    while (true) {
        statements.append(p.allocator, switch (p.lex.token) {
            .t_ident => p.parseStatement(.t_ident),
            .t_number => p.parseStatement(.t_number),
            .t_string => p.parseStatement(.t_string),
            .t_return => blk: {
                if (is_top_level) {
                    @panic("Invalid return statement.");
                }
                break :blk p.parseStatement(.t_return);
            },
            .t_procedure => blk: {
                if (!is_top_level) {
                    @panic("Invalid procedure statement.");
                }
                break :blk p.parseStatement(.t_procedure);
            },
            .t_if => p.parseStatement(.t_if),
            .t_repeat => p.parseStatement(.t_repeat),
            .t_rbrace => if (!is_top_level) break else std.debug.panic("Unsupported: {}\n", .{p.lex.token}),
            .t_eof => break,
            else => |t| std.debug.panic("Unsupported: {}\n", .{t}),
        }) catch unreachable;
    }

    return statements.toOwnedSlice(p.allocator);
}
