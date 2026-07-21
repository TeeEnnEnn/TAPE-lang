const std = @import("std");
const Entities = @import("entities.zig");
const Chunk = @import("chunk.zig");
const BasicGarbageCollector = @import("../memory/basic_garbage_collector.zig");
const ManagedAllocator = @import("../memory/managed_allocator.zig");
const Workspace = @import("../compiler/workspace.zig").Workspace;
const TapeValue = Entities.Value;
const Opcode = Chunk.Opcode;

pub const VMConfig = struct {
    stack_size: usize = 2048,
    max_frame_count: usize = 128,
    globals_size: usize = 1024,
};

pub const BuiltinFunctions = struct {};

pub const InterpretResult = enum {
    Ok,
    Error,
};

pub const RuntimePanic = error{ StackOverflow, StackUnderflow, DivisionByZero, ArgumentCountMismatch, CorruptedState, NegativeDenominator };

/// Represents the virtual machine - the orchestrator of execution.
pub const VM = struct {
    base_allocator: std.mem.Allocator,
    config: VMConfig,
    workspace: *Workspace,
    isolates: std.ArrayList(*Isolate),

    pub fn init(config: VMConfig, workspace: *Workspace, base_allocator: std.mem.Allocator) !*VM {
        const vm = try base_allocator.create(VM);
        vm.* = VM{
            .base_allocator = base_allocator,
            .config = config,
            .workspace = workspace,
            .isolates = .empty,
        };
        return vm;
    }

    pub fn deinit(self: *VM) void {
        for (self.isolates.items) |isolate| {
            isolate.deinit();
        }
        self.isolates.deinit(self.base_allocator);
        self.base_allocator.destroy(self);
    }

    pub fn new_isolate(self: *VM) !*Isolate {
        const isolate = try Isolate.init(self, self.base_allocator, .{});
        try self.isolates.append(self.base_allocator, isolate);
        return isolate;
    }
};

/// Represents an isolate, which is a self-contained execution context.
pub const Isolate = struct {
    vm: *VM,
    gc: *BasicGarbageCollector.BasicGarbageCollector,
    base_allocator: std.mem.Allocator,

    builtin_functions: BuiltinFunctions,
    string_intern: std.StringHashMap(*Entities.ObjectString),
    isolate_closure: *Entities.ObjectClosure,

    stack: [*]TapeValue,
    stack_top_index: usize,
    frames: [*]Entities.CallFrame,
    frame_count: usize,
    // TODO: ideally this should come from the compiler so we don't waste memory
    globals: [*]TapeValue,
    globals_count: usize,

    pub fn init(vm: *VM, base_allocator: std.mem.Allocator, builtin_functions: BuiltinFunctions) !*Isolate {
        const isolate = try base_allocator.create(Isolate);
        isolate.vm = vm;
        isolate.base_allocator = base_allocator;
        isolate.builtin_functions = builtin_functions;
        isolate.isolate_closure = undefined;

        isolate.gc = try BasicGarbageCollector.BasicGarbageCollector.init(base_allocator, isolate, mark_roots);

        isolate.stack = @ptrCast(@alignCast(try base_allocator.alloc(TapeValue, vm.config.stack_size)));
        isolate.stack_top_index = 0;
        isolate.frames = @ptrCast(@alignCast(try base_allocator.alloc(Entities.CallFrame, vm.config.max_frame_count)));
        isolate.frame_count = 0;
        isolate.globals = @ptrCast(@alignCast(try base_allocator.alloc(TapeValue, vm.config.globals_size)));
        isolate.globals_count = 0;

        return isolate;
    }

    pub fn deinit(self: *Isolate) void {
        _ = self;
        // TODO:
    }

    fn mark_roots(ptr: *anyopaque, gc: *BasicGarbageCollector.BasicGarbageCollector) void {
        const isolate: *Isolate = @ptrCast(@alignCast(ptr));

        for (isolate.stack[0..isolate.stack_top_index]) |value| {
            Entities.mark_value(gc, value) catch {
                isolate.vm.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .severity = .Error, .message = "Failed to mark value", .stage = .Execution, .file_path = "", .hint = "This is an internal error. Please report it to the TAPE-lang team." }) catch {};
            };
        }
        // mark globals
        for (0..isolate.globals_count) |index| {
            Entities.mark_value(gc, isolate.globals[index]) catch {
                isolate.vm.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .severity = .Error, .message = "Failed to mark value", .stage = .Execution, .file_path = "", .hint = "This is an internal error. Please report it to the TAPE-lang team." }) catch {};
            };
        }
    }

    pub fn push_value(self: *Isolate, value: TapeValue) !void {
        if (self.stack_top_index >= self.vm.config.stack_size) {
            return error.StackOverflow;
        }
        self.stack[self.stack_top_index] = value;
        self.stack_top_index += 1;
    }

    pub fn pop_value(self: *Isolate) !TapeValue {
        if (self.stack_top_index == 0) {
            return error.StackUnderflow;
        }
        self.stack_top_index -= 1;
        return self.stack[self.stack_top_index];
    }

    pub fn peek_value(self: *Isolate, offset: usize) !TapeValue {
        if (offset >= self.stack_top_index) {
            return error.StackUnderflow;
        }
        return self.stack[self.stack_top_index - 1 - offset];
    }

    pub fn call(self: *Isolate, closure: *Entities.ObjectClosure, arg_count: usize) !void {
        if (arg_count != closure.function.arity) {
            return RuntimePanic.ArgumentCountMismatch;
        }
        if (self.frame_count + 1 >= self.vm.config.max_frame_count) {
            return RuntimePanic.StackOverflow;
        }
        self.frame_count += 1;
        const frame = &self.frames[self.frame_count - 1];
        frame.closure = closure;
        frame.ip = 0;
        // the closure is at self.stack_top_index
        frame.slot_start = self.stack_top_index - arg_count;
    }

    pub fn execute(self: *Isolate) RuntimePanic!InterpretResult {
        try self.push_value(TapeValue{ .object = &self.isolate_closure.header });
        try self.call(self.isolate_closure, 0);
        return try self.execution_loop();
    }

    pub fn execution_loop(self: *Isolate) RuntimePanic!InterpretResult {
        var frame = &self.frames[self.frame_count - 1];

        while (true) {
            const instruction: Opcode = @enumFromInt(frame.closure.function.chunk.code.items[frame.ip]);
            frame.ip += 1;

            switch (instruction) {
                .OP_RETURN => {
                    const result = try self.pop_value();
                    Entities.print_value(result);
                    // close_upvalues
                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        return InterpretResult.Ok;
                    }

                    try self.push_value(result);
                    frame = &self.frames[self.frame_count - 1];
                },

                .OP_CONSTANT => {
                    const constant = frame.read_constant();
                    try self.push_value(constant);
                },

                .OP_NIL => {
                    try self.push_value(.nil);
                },

                .OP_TRUE => {
                    try self.push_value(.{ .boolean = true });
                },

                .OP_FALSE => {
                    try self.push_value(.{ .boolean = false });
                },

                .OP_NEGATE_INT => {
                    const value = try self.pop_value();
                    // wrap on overflow
                    try self.push_value(.{ .int = -%value.int });
                },

                .OP_NEGATE_FLOAT => {
                    const value = try self.pop_value();
                    try self.push_value(.{ .float = -value.float });
                },

                .OP_LOGICAL_NOT => {
                    const value = try self.pop_value();
                    try self.push_value(.{ .boolean = !value.boolean });
                },

                .OP_BITWISE_AND => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(TapeValue{ .int = a.int & b.int });
                },
                .OP_BITWISE_NOT => {
                    const v = try self.pop_value();
                    try self.push_value(TapeValue{ .int = ~v.int });
                },
                .OP_BITWISE_OR => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(TapeValue{ .int = a.int | b.int });
                },
                .OP_BITWISE_XOR => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(TapeValue{ .int = a.int ^ b.int });
                },
                .OP_LEFT_SHIFT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(TapeValue{ .int = a.int << @intCast(b.int) });
                },
                .OP_RIGHT_SHIFT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(TapeValue{ .int = a.int >> @intCast(b.int) });
                },

                .OP_EQUAL => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = Entities.equals(a, b) });
                },

                .OP_NOT_EQUAL => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = !Entities.equals(a, b) });
                },

                .OP_GREATER_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.int > b.int });
                },
                .OP_LESS_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.int < b.int });
                },
                .OP_GREATER_EQUAL_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.int >= b.int });
                },
                .OP_LESS_EQUAL_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.int <= b.int });
                },

                .OP_GREATER_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.float > b.float });
                },
                .OP_LESS_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.float < b.float });
                },
                .OP_GREATER_EQUAL_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.float >= b.float });
                },
                .OP_LESS_EQUAL_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = a.float <= b.float });
                },

                .OP_GREATER_INT_FLOAT => {
                    const b = try self.pop_value(); // f64
                    const a = try self.pop_value(); // i64
                    const a_f128 = @as(f128, @floatFromInt(a.int));
                    const b_f128 = @as(f128, b.float);
                    try self.push_value(.{ .boolean = a_f128 > b_f128 });
                },
                .OP_LESS_INT_FLOAT => {
                    const b = try self.pop_value(); // f64
                    const a = try self.pop_value(); // i64
                    const a_f128 = @as(f128, @floatFromInt(a.int));
                    const b_f128 = @as(f128, b.float);
                    try self.push_value(.{ .boolean = a_f128 < b_f128 });
                },
                .OP_GREATER_EQUAL_INT_FLOAT => {
                    const b = try self.pop_value(); // f64
                    const a = try self.pop_value(); // i64
                    const a_f128 = @as(f128, @floatFromInt(a.int));
                    const b_f128 = @as(f128, b.float);
                    try self.push_value(.{ .boolean = a_f128 >= b_f128 });
                },
                .OP_LESS_EQUAL_INT_FLOAT => {
                    const b = try self.pop_value(); // f64
                    const a = try self.pop_value(); // i64
                    const a_f128 = @as(f128, @floatFromInt(a.int));
                    const b_f128 = @as(f128, b.float);
                    try self.push_value(.{ .boolean = a_f128 <= b_f128 });
                },

                .OP_GREATER_FLOAT_INT => {
                    const b = try self.pop_value(); // i64
                    const a = try self.pop_value(); // f64
                    const a_f128 = @as(f128, a.float);
                    const b_f128 = @as(f128, @floatFromInt(b.int));
                    try self.push_value(.{ .boolean = a_f128 > b_f128 });
                },
                .OP_LESS_FLOAT_INT => {
                    const b = try self.pop_value(); // i64
                    const a = try self.pop_value(); // f64
                    const a_f128 = @as(f128, a.float);
                    const b_f128 = @as(f128, @floatFromInt(b.int));
                    try self.push_value(.{ .boolean = a_f128 < b_f128 });
                },
                .OP_GREATER_EQUAL_FLOAT_INT => {
                    const b = try self.pop_value(); // i64
                    const a = try self.pop_value(); // f64
                    const a_f128 = @as(f128, a.float);
                    const b_f128 = @as(f128, @floatFromInt(b.int));
                    try self.push_value(.{ .boolean = a_f128 >= b_f128 });
                },
                .OP_LESS_EQUAL_FLOAT_INT => {
                    const b = try self.pop_value(); // i64
                    const a = try self.pop_value(); // f64
                    const a_f128 = @as(f128, a.float);
                    const b_f128 = @as(f128, @floatFromInt(b.int));
                    try self.push_value(.{ .boolean = a_f128 <= b_f128 });
                },

                .OP_ADD_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .int = a.int +% b.int });
                },
                .OP_SUB_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .int = a.int -% b.int });
                },
                .OP_MUL_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .int = a.int *% b.int });
                },
                .OP_DIV_INT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    if (b.int == 0) return RuntimePanic.DivisionByZero;
                    if (a.int == std.math.minInt(i64) and b.int == -1) {
                        try self.push_value(.{ .int = std.math.minInt(i64) }); // wrapping division behavior
                        continue;
                    }
                    try self.push_value(.{ .int = @divTrunc(a.int, b.int) });
                },

                // --- ARITHMETIC FLOAT ---
                .OP_ADD_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .float = a.float + b.float });
                },
                .OP_SUB_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .float = a.float - b.float });
                },
                .OP_MUL_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .float = a.float * b.float });
                },
                .OP_DIV_FLOAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    if (b.float == 0.0) return RuntimePanic.DivisionByZero;
                    try self.push_value(.{ .float = a.float / b.float });
                },

                // --- MIXED ARITHMETIC ---
                .OP_ADD_INT_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // int
                    try self.push_value(.{ .float = @as(f64, @floatFromInt(a.int)) + b.float });
                },
                .OP_ADD_FLOAT_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = a.float + @as(f64, @floatFromInt(b.int)) });
                },
                .OP_SUB_INT_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // int
                    try self.push_value(.{ .float = @as(f64, @floatFromInt(a.int)) - b.float });
                },
                .OP_SUB_FLOAT_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = a.float - @as(f64, @floatFromInt(b.int)) });
                },
                .OP_MUL_INT_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // int
                    try self.push_value(.{ .float = @as(f64, @floatFromInt(a.int)) * b.float });
                },
                .OP_MUL_FLOAT_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = a.float * @as(f64, @floatFromInt(b.int)) });
                },
                .OP_DIV_INT_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // int
                    try self.push_value(.{ .float = @as(f64, @floatFromInt(a.int)) / b.float });
                },
                .OP_DIV_FLOAT_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = a.float / @as(f64, @floatFromInt(b.int)) });
                },

                .OP_EXPONENT_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // int
                    try self.push_value(.{ .int = std.math.pow(i64, a.int, b.int) });
                },
                .OP_EXPONENT_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = std.math.pow(f64, a.float, b.float) });
                },
                .OP_EXPONENT_INT_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // int
                    try self.push_value(.{ .float = std.math.pow(f64, @floatFromInt(a.int), b.float) });
                },
                .OP_EXPONENT_FLOAT_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = std.math.pow(f64, a.float, @floatFromInt(b.int)) });
                },

                .OP_MOD_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // int
                    if (b.int == 0) {
                        return error.DivisionByZero;
                    }
                    try self.push_value(.{ .int = @mod(a.int, b.int) });
                },
                .OP_MOD_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = try std.math.mod(f64, a.float, b.float) });
                },
                .OP_MOD_INT_FLOAT => {
                    const b = try self.pop_value(); // float
                    const a = try self.pop_value(); // int
                    try self.push_value(.{ .float = try std.math.mod(f64, @floatFromInt(a.int), b.float) });
                },
                .OP_MOD_FLOAT_INT => {
                    const b = try self.pop_value(); // int
                    const a = try self.pop_value(); // float
                    try self.push_value(.{ .float = try std.math.mod(f64, a.float, @floatFromInt(b.int)) });
                },

                .OP_POP => {
                    const v = try self.pop_value();
                    // for debugging
                    Entities.print_value(v);
                    std.debug.print("\n", .{});
                },

                .OP_POP_N => {
                    const pop_count = frame.read_u16();
                    self.stack_top_index -= pop_count;
                },

                .OP_LOAD_GLOBAL => {
                    const index = frame.read_u16();
                    try self.push_value(self.globals[index]);
                },
                .OP_STORE_GLOBAL => {
                    const index = frame.read_u16();
                    self.globals[index] = try self.peek_value(0);
                },
                .OP_STORE_LOCAL => {
                    const index = frame.read_u16();
                    self.stack[frame.slot_start + index] = try self.peek_value(0);
                },
                .OP_LOAD_LOCAL => {
                    const index = frame.read_u16();
                    try self.push_value(self.stack[frame.slot_start + index]);
                },
                .OP_JUMP => {
                    const offset = frame.read_u16();
                    frame.ip += offset;
                },
                .OP_JUMP_IF_FALSE => {
                    const offset = frame.read_u16();
                    if (Entities.is_falsy(try self.peek_value(0))) {
                        frame.ip += offset;
                    }
                },
                .OP_JUMP_IF_NIL => {
                    const offset = frame.read_u16();
                    const value = try self.peek_value(0);
                    switch (value) {
                        .nil => {
                            frame.ip += offset;
                        },
                        else => {},
                    }
                },
                .OP_LOOP => {
                    const offset = frame.read_u16();
                    frame.ip -= offset;
                },
                .OP_CALL => {},
                .OP_CLOSURE => {},
            }
        }
    }
};
