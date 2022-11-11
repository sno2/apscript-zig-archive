const std = @import("std");
const ast = @import("ast.zig");
const E = ast.E;
const S = ast.S;
const Span = ast.Span;
const Parser = @import("Parser.zig");

const VM = @This();

// We could optimize this using tagged pointers, but it wouldn't affect
// performance that much.
pub const Value = union(Tag) {
    v_bool: bool,
    v_number: f32,
    v_array: []Value,
    v_string_ref: []const u8,
    v_fn: *S,
    v_builtin_fn: Builtin.FakeRef,

    fn format(self: Value, writer: anytype, vm: *VM) !void {
        switch (self) {
            .v_bool => |b| try writer.writeAll(if (b) "TRUE" else "FALSE"),
            .v_array => |arr| {
                try writer.writeAll("[");

                if (arr.len > 0) {
                    for (arr[0 .. arr.len - 1]) |itm| {
                        itm.format(writer, vm) catch unreachable;
                        try writer.writeAll(", ");
                    }
                    arr[arr.len - 1].format(writer, vm) catch unreachable;
                }

                try writer.writeAll("]");
            },
            .v_string_ref => |s| try writer.writeAll(s),
            .v_number => |n| try writer.print("{d}", .{n}),
            .v_builtin_fn => |ref| try writer.print("<builtin {s}>", .{Builtin.getName(@ptrCast(Builtin.Ref, ref))}),
            .v_fn => |ref| try writer.print("<proc {s}>", .{vm.buffer[ref.data.s_procedure.name.start..ref.data.s_procedure.name.end]}),
        }
    }

    pub const Tag = enum(u8) {
        v_bool,
        v_number,
        v_array,
        v_string_ref,
        v_fn,
        v_builtin_fn,
    };

    pub inline fn fromFloat(f: f32) Value {
        return Value{ .v_number = f };
    }

    pub inline fn fromBool(b: bool) Value {
        return Value{ .v_bool = b };
    }

    /// Converts a value to a number. On error, does not specify the span.
    pub fn toNumber(value: Value, exception: ExceptionRef) ?Value {
        return switch (value) {
            .v_number => value,
            else => {
                exception.* = Exception{
                    .message = "Failed to convert value to number.",
                    .span = undefined,
                };
                return null;
            },
        };
    }

    /// Converts a value to a number. On error, does not specify the span.
    pub fn toBool(value: Value, exception: ExceptionRef) ?bool {
        return switch (value) {
            .v_bool => |b| b,
            else => {
                exception.* = Exception{
                    .message = "Failed to convert value to a boolean.",
                    .span = undefined,
                };
                return null;
            },
        };
    }

    pub inline fn isTrue(value: Value) bool {
        return switch (value) {
            .v_bool => |b| b,
            else => false,
        };
    }
};

allocator: std.mem.Allocator,
state: State,
buffer: []const u8,
xoshiro: std.rand.Xoshiro256,

pub const Builtin = struct {
    // This is a workaround due to a circular dependency bug in Zig.
    pub const Ref = std.meta.FnPtr(fn (*VM, []Value, ExceptionRef) ?Value);
    pub const FakeRef = std.meta.FnPtr(fn () void);

    pub fn getName(ref: Builtin.Ref) []const u8 {
        return switch (ref) {
            random => "RANDOM",
            display => "DISPLAY",
            append => "APPEND",
            else => unreachable,
        };
    }

    fn assert(_: *VM, args: []Value, exception: ExceptionRef) ?Value {
        if (args.len == 0 or !args[0].isTrue()) {
            exception.* = Exception{
                .message = "Expected argument to be true.",
                .span = undefined,
            };
            return null;
        }
        return Value.fromFloat(0);
    }

    fn input(vm: *VM, args: []Value, _: ExceptionRef) ?Value {
        var stdout = std.io.getStdOut();
        var writer = stdout.writer();

        if (args.len != 0) {
            args[0].format(writer, vm) catch unreachable;
            for (args[1..]) |arg| {
                writer.writeAll(" ") catch unreachable;
                arg.format(writer, vm) catch unreachable;
            }
            writer.writeAll(" ") catch unreachable;
        } else {
            stdout.writeAll("Input: ") catch unreachable;
        }

        var stdin = std.io.getStdIn();

        var i = stdin.reader().readUntilDelimiterOrEofAlloc(
            vm.allocator,
            '\n',
            1024,
        ) catch {
            return Value{ .v_string_ref = "" };
        } orelse {
            return Value{ .v_string_ref = "" };
        };

        if (@import("builtin").target.os.tag == .windows) {
            i = i[0 .. i.len - 1];
        }

        const float = std.fmt.parseFloat(f32, i) catch {
            return Value{ .v_string_ref = i };
        };

        return Value{
            .v_number = float,
        };
    }

    fn display(vm: *VM, args: []Value, _: ExceptionRef) ?Value {
        var stdout = std.io.getStdOut();
        var writer = stdout.writer();

        if (args.len != 0) {
            args[0].format(writer, vm) catch unreachable;
            for (args[1..]) |arg| {
                writer.writeAll(" ") catch unreachable;
                arg.format(writer, vm) catch unreachable;
            }
        }

        writer.writeAll("\n") catch unreachable;

        return Value.fromFloat(0);
    }

    fn length(_: *VM, args: []Value, exception: ExceptionRef) ?Value {
        if (args.len == 0 or args[0] != .v_array) {
            exception.* = Exception{
                .message = "Expected a single list argument.",
                .span = undefined,
            };
            return null;
        }

        return Value.fromFloat(@intToFloat(f32, args[0].v_array.len));
    }

    fn random(vm: *VM, args: []Value, exception: ExceptionRef) ?Value {
        if (args.len < 2) {
            exception.* = Exception{
                .message = "Expected two number arguments.",
                .span = undefined,
            };
            return null;
        }

        const start = switch (args[0]) {
            .v_number => |n| n,
            else => {
                exception.* = Exception{
                    .message = "Expected the first argument to be a number.",
                    .span = undefined,
                };
                return null;
            },
        };

        const end = switch (args[1]) {
            .v_number => |n| n,
            else => {
                exception.* = Exception{
                    .message = "Expected the second argument to be a number.",
                    .span = undefined,
                };
                return null;
            },
        };

        return Value.fromFloat(@intToFloat(f32, vm.xoshiro.random().uintAtMost(u32, @floatToInt(u32, end - start))) + start);
    }

    fn append(vm: *VM, args: []Value, exception: ExceptionRef) ?Value {
        if (args.len < 2) {
            exception.* = Exception{
                .message = "Expected a list and value argument.",
                .span = undefined,
            };
            return null;
        }

        const list = switch (args[0]) {
            .v_array => |a| a,
            else => {
                exception.* = Exception{
                    .message = "Expected the first argument to be a list.",
                    .span = undefined,
                };
                return null;
            },
        };

        var new_list = vm.allocator.alloc(Value, list.len + 1) catch unreachable;
        std.mem.copy(Value, new_list, list);
        new_list[list.len] = args[1];

        return Value.fromFloat(0);
    }
};

pub const Exception = struct {
    message: []const u8,
    span: Span,
};

pub const ExceptionRef = *Exception;

const State = std.StringHashMapUnmanaged(Value);

pub fn init(allocator: std.mem.Allocator, buffer: []const u8) VM {
    var state = State{};

    state.ensureTotalCapacity(allocator, 64) catch unreachable;

    state.putAssumeCapacityNoClobber("DISPLAY", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.display) });
    state.putAssumeCapacityNoClobber("display", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.display) });

    state.putAssumeCapacityNoClobber("LENGTH", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.length) });
    state.putAssumeCapacityNoClobber("length", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.length) });

    state.putAssumeCapacityNoClobber("RANDOM", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.random) });
    state.putAssumeCapacityNoClobber("random", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.random) });

    state.putAssumeCapacityNoClobber("INPUT", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.input) });
    state.putAssumeCapacityNoClobber("input", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.input) });

    state.putAssumeCapacityNoClobber("ASSERT", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.assert) });
    state.putAssumeCapacityNoClobber("assert", Value{ .v_builtin_fn = @ptrCast(Builtin.FakeRef, Builtin.assert) });

    var seed: u64 = 0;
    std.os.getrandom(std.mem.asBytes(&seed)) catch unreachable;

    return .{
        .allocator = allocator,
        .state = state,
        .buffer = buffer,
        .xoshiro = std.rand.Xoshiro256.init(seed),
    };
}

pub fn valueEq(_: *VM, lhs: Value, rhs: Value, exception: ExceptionRef) ?Value {
    if ((lhs == .v_array and rhs != .v_array) or (lhs != .v_array and rhs == .v_array)) {
        exception.* = Exception{
            .message = "Cannot compare array and non-array values.",
            .span = undefined,
        };
        return null;
    }

    if ((lhs == .v_string_ref and rhs != .v_string_ref) or (lhs != .v_string_ref and rhs == .v_string_ref)) {
        exception.* = Exception{
            .message = "Cannot compare string and non-string values.",
            .span = undefined,
        };
        return null;
    }

    return Value{
        .v_bool = switch (lhs) {
            .v_builtin_fn => |ptr| rhs == .v_builtin_fn and ptr == rhs.v_builtin_fn,
            .v_fn => |s| rhs == .v_fn and s == rhs.v_fn,
            .v_bool => |b| rhs == .v_bool and b == rhs.v_bool,
            .v_string_ref => std.mem.eql(u8, lhs.v_string_ref, rhs.v_string_ref),
            .v_number => |n| rhs == .v_number and n == rhs.v_number,
            .v_array => @panic("todo"),
        },
    };
}

pub fn evalExpr(vm: *VM, value: E, exception: ExceptionRef) ?Value {
    switch (value.data) {
        .e_true => return Value{ .v_bool = true },
        .e_false => return Value{ .v_bool = false },
        .e_ident => {
            const ident = vm.buffer[value.span.start..value.span.end];
            return vm.state.get(ident) orelse {
                exception.* = Exception{
                    .message = std.fmt.allocPrint(vm.allocator, "'{s}' is not defined.", .{ident}) catch unreachable,
                    .span = value.span,
                };
                return null;
            };
        },
        .e_number => {
            return Value{
                .v_number = std.fmt.parseFloat(f32, vm.buffer[value.span.start..value.span.end]) catch unreachable,
            };
        },
        .e_string => return Value{
            .v_string_ref = vm.buffer[value.span.start + 1 .. value.span.end - 1],
        },
        .e_unary_neg => |data| {
            const val = (vm.evalExpr(data.value, exception) orelse return null).toNumber(exception) orelse {
                exception.span = value.span;
                return null;
            };
            return Value.fromFloat(-val.v_number);
        },
        .e_unary_pos => |data| {
            const val = (vm.evalExpr(data.value, exception) orelse return null).toNumber(exception) orelse {
                exception.span = value.span;
                return null;
            };
            return Value.fromFloat(val.v_number);
        },
        // TODO: convert to 'inline' case once 'zig fmt' supports it
        .e_bin_add, .e_bin_sub, .e_bin_mul, .e_bin_div, .e_bin_mod => |data| {
            const n1 = switch (data.lhs.data) {
                .e_array, .e_string, .e_true, .e_false => {
                    exception.* = Exception{
                        .message = "Failed to apply math operator to non-number type.",
                        .span = value.span,
                    };
                    return null;
                },
                else => vm.evalExpr(data.lhs, exception) orelse return null,
            };

            const n2 = switch (data.rhs.data) {
                .e_array, .e_string, .e_true, .e_false => {
                    exception.* = Exception{
                        .message = "Failed to apply math operator to non-number type.",
                        .span = value.span,
                    };
                    return null;
                },
                else => vm.evalExpr(data.rhs, exception) orelse return null,
            };

            const nn1 = switch (n1) {
                .v_number => |n| n,
                else => {
                    exception.* = Exception{
                        .message = "Failed to apply math operator to non-number type.",
                        .span = value.span,
                    };
                    return null;
                },
            };

            const nn2 = switch (n2) {
                .v_number => |n| n,
                else => {
                    exception.* = Exception{
                        .message = "Failed to apply math operator to non-number type.",
                        .span = value.span,
                    };
                    return null;
                },
            };

            return Value.fromFloat(switch (value.data) {
                .e_bin_add => nn1 + nn2,
                .e_bin_sub => nn1 - nn2,
                .e_bin_mul => nn1 * nn2,
                .e_bin_div => nn1 / nn2,
                .e_bin_mod => blk: {
                    if (nn2 == 0) {
                        exception.* = Exception{
                            .message = "Failed to apply modulus operator with 0 divisor.",
                            .span = value.span,
                        };
                        return null;
                    }

                    if (nn2 < 0) {
                        break :blk -@mod(nn1, -nn2);
                    }

                    break :blk @mod(nn1, nn2);
                },
                else => unreachable,
            });
        },
        .e_bin_eq => |data| {
            const lhs = vm.evalExpr(data.lhs, exception) orelse return null;

            const rhs = vm.evalExpr(data.rhs, exception) orelse return null;

            return vm.valueEq(lhs, rhs, exception) orelse {
                exception.span = value.span;
                return null;
            };
        },
        .e_bin_neq => |data| {
            const lhs = vm.evalExpr(data.lhs, exception) orelse return null;

            const rhs = vm.evalExpr(data.rhs, exception) orelse return null;

            const eq = vm.valueEq(lhs, rhs, exception) orelse {
                exception.span = value.span;
                return null;
            };

            return Value.fromBool(!eq.v_bool);
        },
        .e_bin_gt => |data| {
            const lhs = (vm.evalExpr(data.lhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.lhs.span;
                return null;
            };

            const rhs = (vm.evalExpr(data.rhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.rhs.span;
                return null;
            };

            return Value.fromBool(lhs.v_number > rhs.v_number);
        },
        .e_bin_lt => |data| {
            const lhs = (vm.evalExpr(data.lhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.lhs.span;
                return null;
            };

            const rhs = (vm.evalExpr(data.rhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.rhs.span;
                return null;
            };

            return Value.fromBool(lhs.v_number < rhs.v_number);
        },
        .e_bin_gte => |data| {
            const lhs = (vm.evalExpr(data.lhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.lhs.span;
                return null;
            };

            const rhs = (vm.evalExpr(data.rhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.rhs.span;
                return null;
            };

            return Value.fromBool(lhs.v_number >= rhs.v_number);
        },
        .e_bin_lte => |data| {
            const lhs = (vm.evalExpr(data.lhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.lhs.span;
                return null;
            };

            const rhs = (vm.evalExpr(data.rhs, exception) orelse return null).toNumber(exception) orelse {
                exception.span = data.rhs.span;
                return null;
            };

            return Value.fromBool(lhs.v_number <= rhs.v_number);
        },
        .e_bin_and => |data| {
            const lhs = (vm.evalExpr(data.lhs, exception) orelse return null).toBool(exception) orelse {
                exception.span = data.lhs.span;
                return null;
            };

            if (!lhs) {
                return Value.fromBool(false);
            }

            const rhs = (vm.evalExpr(data.rhs, exception) orelse return null).toBool(exception) orelse {
                exception.span = data.rhs.span;
                return null;
            };

            return Value.fromBool(rhs);
        },
        .e_bin_or => |data| {
            const lhs = (vm.evalExpr(data.lhs, exception) orelse return null).toBool(exception) orelse {
                exception.span = data.lhs.span;
                return null;
            };

            if (lhs) {
                return Value.fromBool(true);
            }

            const rhs = (vm.evalExpr(data.rhs, exception) orelse return null).toBool(exception) orelse {
                exception.span = data.rhs.span;
                return null;
            };

            return Value.fromBool(rhs);
        },
        .e_fn_call => |d| {
            const ident = vm.buffer[d.name.start..d.name.end];

            const rfn = vm.state.get(ident) orelse {
                exception.* = Exception{
                    .message = "Variable is not defined.",
                    .span = d.name,
                };
                return null;
            };

            var args = vm.allocator.alloc(Value, d.arguments.len) catch unreachable;
            defer vm.allocator.free(args);

            for (d.arguments) |node, i| {
                args[i] = vm.evalExpr(node, exception) orelse return null;
            }

            switch (rfn) {
                .v_builtin_fn => |builtin| {
                    return @ptrCast(Builtin.Ref, builtin)(vm, args, exception) orelse {
                        exception.span = value.span;
                        return null;
                    };
                },
                .v_fn => |s| {
                    const data = s.data.s_procedure;
                    const start_cloning_at = blk: {
                        for (data.arguments) |v, i| {
                            if (vm.state.get(vm.buffer[v.start..v.end]) != null) {
                                break :blk i;
                            }
                        }
                        break :blk null;
                    };
                    // FIXME: this seems to all be wrong

                    const empty_copy = [0]Value{};
                    var copies = if (start_cloning_at == null) &empty_copy else vm.allocator.alloc(Value, data.arguments.len - start_cloning_at.?) catch unreachable;

                    if (start_cloning_at) |start| {
                        for (data.arguments[start..]) |v, i| {
                            copies[i - start] = vm.state.get(vm.buffer[v.start..v.end]) orelse unreachable;
                        }
                    }

                    for (data.arguments) |arg, i| {
                        vm.state.putAssumeCapacity(vm.buffer[arg.start..arg.end], args[i]);
                    }

                    const rt_value = vm.evalScope(data.scope, exception) orelse return null;

                    if (start_cloning_at) |start| {
                        for (data.arguments[start..]) |arg, i| {
                            vm.state.putAssumeCapacity(vm.buffer[arg.start..arg.end], copies[i - start]);
                        }
                    }

                    return rt_value;
                },
                else => {
                    exception.* = Exception{
                        .message = "Value is not callable.",
                        .span = d.name,
                    };
                    return null;
                },
            }
        },
        .e_array => |d| {
            var items = vm.allocator.alloc(Value, d.values.len) catch unreachable;

            for (d.values) |v, i| {
                items[i] = vm.evalExpr(v, exception) orelse return null;
            }

            return Value{ .v_array = items };
        },
    }
}

pub fn evalScope(vm: *VM, scope: []S, exception: ExceptionRef) ?Value {
    for (scope) |stmt, i| {
        switch (stmt.data) {
            .s_procedure => |d| {
                var result = vm.state.getOrPut(vm.allocator, vm.buffer[d.name.start..d.name.end]) catch unreachable;

                if (result.found_existing) {
                    exception.* = Exception{
                        .message = "Value is already defined.",
                        .span = d.name,
                    };
                    return null;
                }

                result.value_ptr.* = .{ .v_fn = &scope[i] };
            },
            .s_assign => |d| {
                const result = vm.state.getOrPut(vm.allocator, vm.buffer[d.name.start..d.name.end]) catch unreachable;

                if (result.found_existing) switch (result.value_ptr.*) {
                    .v_builtin_fn, .v_fn => {
                        exception.* = Exception{
                            .message = "Unable to assign to function reference.",
                            .span = stmt.span,
                        };
                        return null;
                    },
                    else => {},
                };

                result.value_ptr.* = vm.evalExpr(d.value, exception) orelse return null;
            },
            .s_expr => |e| {
                _ = vm.evalExpr(e.*, exception) orelse return null;
            },
            .s_return => |e| {
                return vm.evalExpr(e.value, exception);
            },
            .s_if => |s| blk: {
                const cond = vm.evalExpr(s.condition, exception) orelse return null;

                const value = switch (cond) {
                    .v_bool => |v| v,
                    else => {
                        exception.* = Exception{
                            .message = "Expected a boolean value for the if statement condition.",
                            .span = s.condition.span,
                        };
                        return null;
                    },
                };

                if (value) {
                    _ = vm.evalScope(s.scope, exception) orelse return null;
                    break :blk;
                }

                if (s.else_ifs.len != 0) {
                    for (s.else_ifs) |else_itm| {
                        const v_raw = vm.evalExpr(else_itm.condition, exception) orelse return null;
                        const v = v_raw.toBool(exception) orelse {
                            exception.span = else_itm.condition.span;
                            return null;
                        };

                        if (v) {
                            _ = vm.evalScope(else_itm.scope, exception) orelse return null;
                            break :blk;
                        }
                    }
                }

                if (s.@"else") |inner| {
                    _ = vm.evalScope(inner, exception) orelse return null;
                }
            },
            .s_repeat_n => |s| blk: {
                const count = vm.evalExpr(s.count, exception) orelse return null;
                var j = switch (count) {
                    .v_number => |f| if (f <= 0) break :blk else @floatToInt(u32, @trunc(f)),
                    else => {
                        exception.* = Exception{
                            .message = "Expected a number for the count.",
                            .span = s.count.span,
                        };
                        return null;
                    },
                };

                while (j > 0) : (j -= 1) {
                    _ = vm.evalScope(s.scope, exception) orelse return null;
                }
            },
            .s_repeat_until => |s| {
                while (!(vm.valueEq(vm.evalExpr(s.condition, exception) orelse return null, Value{ .v_bool = true }, exception) orelse return null).v_bool) {
                    _ = vm.evalScope(s.scope, exception) orelse return null;
                }
            },
        }
    }
    return Value.fromFloat(0);
}

pub fn parseAndEval(vm: *VM, input: []const u8, exception: ExceptionRef) ?void {
    const arena = std.heap.ArenaAllocator.init(vm.allocator);
    defer arena.deinit();

    var p = Parser.init(arena.allocator(), input);
    var scope = p.parseScope(true);
    vm.evalScope(scope, exception) orelse return null;
}
