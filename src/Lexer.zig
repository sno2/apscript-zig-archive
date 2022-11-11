const std = @import("std");
const ast = @import("ast.zig");

const Lexer = @This();

buffer: []const u8,
start: u32,
offset: u32,
token: T = undefined,
codepoint: i16,
is_newline_before: bool = false,

pub fn init(buffer: []const u8) Lexer {
    return .{
        .buffer = buffer,
        .start = 0,
        .offset = 0,
        .codepoint = buffer[0],
    };
}

pub fn span(lex: *Lexer) ast.Span {
    return .{
        .start = lex.start,
        .end = lex.offset,
    };
}

pub const T = enum {
    t_eof,
    t_ident,
    t_func,
    t_eq,
    t_neq,
    t_lt,
    t_gt,
    t_lte,
    t_gte,
    t_not,
    t_and,
    t_or,
    t_if,
    t_else,
    t_repeat,
    t_times,
    t_until,
    t_lbrack,
    t_rbrack,
    t_lparen,
    t_rparen,
    t_lbrace,
    t_rbrace,
    t_comma,
    t_assign,
    t_minus,
    t_plus,
    t_asterisk,
    t_slash,
    t_mod,
    t_for,
    t_each,
    t_in,
    t_procedure,
    t_return,
    t_true,
    t_false,
    t_number,
    t_string,
    t_bad_string,

    pub fn symbol(self: T) []const u8 {
        return switch (self) {
            .t_eof => "the end of the file",
            .t_ident => "an identifier",
            .t_func => "a function call token",
            .t_eq => "an equal sign '='",
            .t_neq => "a not equal sign '!='",
            .t_lt => "a less than sign '<'",
            .t_gt => "a greater than sign '>'",
            .t_lte => "a less than or equal to sign '<='",
            .t_gte => "a greater to or equal to sign '>='",
            .t_not => "the negation symbol",
            .t_and => "the and symbol",
            .t_or => "the or symbol",
            .t_if => "the if keyword",
            .t_else => "the else keyword",
            .t_repeat => "the repeat keyword",
            .t_times => "the times keyword",
            .t_until => "the until keyword",
            .t_lbrack => "an opening bracket '['",
            .t_rbrack => "a closing bracket ']'",
            .t_lparen => "an opening parenthesis '('",
            .t_rparen => "a closing parenthesis ')'",
            .t_lbrace => "an opening bracket '['",
            .t_rbrace => "a closing bracket ']'",
            .t_comma => "a comma ','",
            .t_assign => "an assignment token '->'",
            .t_minus => "a minus sign '-'",
            .t_plus => "a plus sign '+'",
            .t_asterisk => "an asterisk '*'",
            .t_slash => "a slash '/'",
            .t_mod => "a modulus sign",
            .t_for => "the for keyword",
            .t_each => "the each keyword",
            .t_in => "the in keyword",
            .t_procedure => "the procedure keyword",
            .t_return => "the return keyword",
            .t_true => "the true keyword",
            .t_false => "the false keyword",
            .t_number => "a number",
            .t_string => "a string literal",
            .t_bad_string => "a non-terminating string",
        };
    }

    /// The token's left bindings power.
    pub fn lbp(self: T) u8 {
        return switch (self) {
            .t_slash, .t_asterisk, .t_mod => 5,
            .t_plus, .t_minus => 4,
            .t_eq, .t_neq, .t_gt, .t_lt, .t_gte, .t_lte => 3,
            .t_and => 2,
            .t_or => 1,
            else => 255,
        };
    }

    pub const KeywordMap = std.ComptimeStringMap(T, .{
        .{ "TRUE", .t_true },
        .{ "true", .t_true },
        .{ "FALSE", .t_false },
        .{ "false", .t_false },
        .{ "FOR", .t_for },
        .{ "for", .t_for },
        .{ "EACH", .t_each },
        .{ "each", .t_each },
        .{ "IN", .t_in },
        .{ "in", .t_in },
        .{ "PROCEDURE", .t_procedure },
        .{ "procedure", .t_procedure },
        .{ "RETURN", .t_return },
        .{ "return", .t_return },
        .{ "REPEAT", .t_repeat },
        .{ "repeat", .t_repeat },
        .{ "TIMES", .t_times },
        .{ "times", .t_times },
        .{ "UNTIL", .t_until },
        .{ "until", .t_until },
        .{ "IF", .t_if },
        .{ "if", .t_if },
        .{ "ELSE", .t_else },
        .{ "else", .t_else },
        .{ "MOD", .t_mod },
        .{ "mod", .t_mod },
        .{ "AND", .t_and },
        .{ "and", .t_and },
        .{ "NOT", .t_not },
        .{ "not", .t_not },
        .{ "OR", .t_or },
        .{ "or", .t_or },
    });
};

fn getIdent(lex: *Lexer) T {
    const ident = lex.buffer[lex.start..lex.offset];

    if (T.KeywordMap.get(ident)) |t| {
        return t;
    }

    return .t_ident;
}

pub fn step(lex: *Lexer) void {
    lex.offset += 1;
    lex.codepoint = if (lex.offset > lex.buffer.len - 1) -1 else @intCast(i16, lex.buffer[lex.offset]);
}

inline fn consumeStringBody(lex: *Lexer, comptime ending: i16) void {
    while (true) {
        switch (lex.codepoint) {
            -1 => {
                lex.token = .t_bad_string;
                break;
            },
            ending => {
                lex.step();
                break;
            },
            '\\' => {
                lex.step();
                if (lex.codepoint != -1) lex.step();
            },
            else => lex.step(),
        }
    }
}

inline fn consumeIdent(lex: *Lexer) void {
    while (true) {
        switch (lex.codepoint) {
            'a'...'z', 'A'...'Z', '$', '_', '0'...'9' => lex.step(),
            else => break,
        }
    }
    lex.token = lex.getIdent();
}

inline fn consumeNumber(lex: *Lexer, comptime seen_decimal: bool) void {
    while (true) {
        switch (lex.codepoint) {
            '0'...'9' => lex.step(),
            '.' => if (seen_decimal) break else {
                lex.step();
                return lex.consumeNumber(true);
            },
            else => break,
        }
    }
}

pub fn next(lex: *Lexer) void {
    lex.is_newline_before = false;
    while (true) {
        switch (lex.codepoint) {
            '\n' => {
                lex.is_newline_before = true;
                lex.step();
            },
            ' ', '\t', '\r' => lex.step(),
            '#' => while (true) {
                lex.step();
                switch (lex.codepoint) {
                    '\n', -1 => break,
                    else => {},
                }
            },
            else => break,
        }
    }
    lex.start = lex.offset;

    switch (lex.codepoint) {
        -1 => {
            lex.token = .t_eof;
        },
        '\'' => {
            lex.step();
            lex.token = .t_string;
            lex.consumeStringBody('\'');
        },
        '"' => {
            lex.step();
            lex.token = .t_string;
            lex.consumeStringBody('"');
        },
        '<' => {
            lex.step();
            switch (lex.codepoint) {
                '-' => {
                    lex.step();
                    lex.token = .t_assign;
                },
                else => lex.token = .t_lt,
            }
        },
        '>' => {
            lex.step();
            lex.token = .t_gt;
        },
        '=' => {
            lex.step();
            lex.token = .t_eq;
        },
        '%' => {
            lex.step();
            lex.token = .t_mod;
        },
        '+' => {
            lex.step();
            lex.token = .t_plus;
        },
        '-' => {
            lex.step();
            lex.token = .t_minus;
        },
        '*' => {
            lex.step();
            lex.token = .t_asterisk;
        },
        '/' => {
            lex.step();
            lex.token = .t_slash;
        },
        '(' => {
            lex.step();
            lex.token = .t_lparen;
        },
        ')' => {
            lex.step();
            lex.token = .t_rparen;
        },
        '[' => {
            lex.step();
            lex.token = .t_lbrack;
        },
        ']' => {
            lex.step();
            lex.token = .t_rbrack;
        },
        '{' => {
            lex.step();
            lex.token = .t_lbrace;
        },
        '}' => {
            lex.step();
            lex.token = .t_rbrace;
        },
        '!' => {
            lex.step();
            switch (lex.codepoint) {
                '=' => {
                    lex.step();
                    lex.token = .t_neq;
                },
                else => @panic("."),
            }
        },
        ',' => {
            lex.step();
            lex.token = .t_comma;
        },
        'a'...'z', 'A'...'Z', '$', '_' => {
            lex.step();
            lex.consumeIdent();
        },
        '.' => {
            lex.step();
            lex.token = .t_number;
            lex.consumeNumber(true);
        },
        '0'...'9' => {
            lex.step();
            lex.token = .t_number;
            lex.consumeNumber(false);
        },
        else => |c| std.debug.panic("Unknown character: {}", .{c}),
    }
}
