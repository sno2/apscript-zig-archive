const std = @import("std");
const Lexer = @import("Lexer.zig");
const Parser = @import("Parser.zig");
const VM = @import("VM.zig");

pub fn main() !void {
    var stderr = std.io.getStdErr();
    var stderr_writer = stderr.writer();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();
    var allocator = arena.allocator();
    var arg_iter = std.process.ArgIterator.initWithAllocator(allocator) catch unreachable;

    _ = arg_iter.next() orelse {};
    const path = if (arg_iter.next()) |path| path else {
        @panic("Expected a file path.");
    };

    const path_full = std.fs.path.resolve(allocator, &.{path}) catch unreachable;
    const file = std.fs.openFileAbsolute(path_full, .{}) catch |e| {
        std.log.err("Failed to open file: {}", .{e});
        std.process.exit(1);
    };
    const input = file.readToEndAlloc(allocator, 4096) catch unreachable;

    var p = Parser.init(allocator, input);
    p.lex.next();
    var scope = p.parseScope(true) catch {
        for (p.errors.items) |e| {
            try stderr_writer.writeAll("error: ");
            try e.format(stderr_writer);
            try stderr_writer.print("    -> {s}\n", .{input[e.span.start..e.span.end]});
        }
        std.process.exit(1);
    };

    var vm = VM.init(gpa.allocator(), input);
    var exception = allocator.alloc(VM.Exception, 1) catch unreachable;

    _ = vm.evalScope(scope, &exception[0]) orelse {
        try stderr_writer.print("error: {s}\n", .{exception[0].message});
        try stderr_writer.print("    -> {s}\n", .{vm.buffer[exception[0].span.start..exception[0].span.end]});
        std.process.exit(1);
    };
}
