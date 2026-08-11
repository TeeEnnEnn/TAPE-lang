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

pub const RuntimePanic = error{ StackOverflow, StackUnderflow, DivisionByZero, ArgumentCountMismatch, CorruptedState, NegativeDenominator, OutOfMemory, IndexOutOfBounds, KeyNotFound };

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

    function_constants: std.ArrayList(TapeValue),

    stack: [*]TapeValue,
    stack_top_index: usize,
    frames: [*]Entities.CallFrame,
    frame_count: usize,
    open_upvalues: ?*Entities.ObjectUpvalue,
    // TODO: ideally this should come from the compiler so we don't waste memory
    globals: [*]TapeValue,
    globals_count: usize,

    pub fn init(vm: *VM, base_allocator: std.mem.Allocator, builtin_functions: BuiltinFunctions) !*Isolate {
        const isolate = try base_allocator.create(Isolate);
        isolate.vm = vm;
        isolate.base_allocator = base_allocator;
        isolate.builtin_functions = builtin_functions;
        isolate.isolate_closure = undefined;
        isolate.string_intern = std.StringHashMap(*Entities.ObjectString).init(base_allocator);

        isolate.gc = try BasicGarbageCollector.BasicGarbageCollector.init(base_allocator, isolate, mark_roots, clean_string_intern);

        isolate.stack = @ptrCast(@alignCast(try base_allocator.alloc(TapeValue, vm.config.stack_size)));
        isolate.stack_top_index = 0;
        isolate.open_upvalues = null;
        isolate.frames = @ptrCast(@alignCast(try base_allocator.alloc(Entities.CallFrame, vm.config.max_frame_count)));
        isolate.frame_count = 0;
        isolate.globals = @ptrCast(@alignCast(try base_allocator.alloc(TapeValue, vm.config.globals_size)));
        isolate.globals_count = 0;
        isolate.function_constants = .empty;

        return isolate;
    }

    pub fn deinit(self: *Isolate) void {
        self.string_intern.deinit();
        self.gc.deinit();
        self.base_allocator.free(self.stack[0..self.vm.config.stack_size]);
        self.base_allocator.free(self.frames[0..self.vm.config.max_frame_count]);
        self.base_allocator.free(self.globals[0..self.vm.config.globals_size]);
        self.function_constants.deinit(self.base_allocator);
        self.base_allocator.destroy(self);
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
        // mark open upvalues
        var upvalue = isolate.open_upvalues;
        while (upvalue) |uv| {
            Entities.mark_value(gc, .{ .object = &uv.header }) catch {};
            upvalue = uv.next;
        }
    }

    fn clean_string_intern(ptr: *anyopaque, gc: *BasicGarbageCollector.BasicGarbageCollector) void {
        _ = gc;
        const isolate: *Isolate = @ptrCast(@alignCast(ptr));
        var keys_to_remove = std.ArrayList([]const u8).empty;
        defer keys_to_remove.deinit(isolate.base_allocator);

        var it = isolate.string_intern.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.*.header.marked) {
                keys_to_remove.append(isolate.base_allocator, entry.key_ptr.*) catch {};
            }
        }

        for (keys_to_remove.items) |key| {
            _ = isolate.string_intern.remove(key);
        }
    }

    pub fn push_value(self: *Isolate, value: TapeValue) !void {
        if (self.stack_top_index >= self.vm.config.stack_size) {
            return error.StackOverflow;
        }
        self.stack[self.stack_top_index] = value;
        self.stack_top_index += 1;
    }

    /// Returns the value at the top of the stack
    pub fn pop_value(self: *Isolate) !TapeValue {
        if (self.stack_top_index == 0) {
            return error.StackUnderflow;
        }
        self.stack_top_index -= 1;
        return self.stack[self.stack_top_index];
    }

    /// Gets the value on the stack at the given offset
    pub fn peek_value(self: *Isolate, offset: usize) !TapeValue {
        if (offset >= self.stack_top_index) {
            return error.StackUnderflow;
        }
        return self.stack[self.stack_top_index - 1 - offset];
    }

    /// Returns an upvalue pointing at the given stack slot, reusing an existing open
    /// upvalue so multiple closures capturing the same local share it. The open-upvalue
    /// list is kept sorted by descending stack address so that close_upvalues can stop
    /// scanning as soon as it reaches an upvalue below the boundary.
    pub fn capture_upvalue(self: *Isolate, local: *TapeValue) !*Entities.ObjectUpvalue {
        var previous: ?*Entities.ObjectUpvalue = null;
        var current = self.open_upvalues;
        while (current) |upvalue| {
            if (upvalue.location == local) return upvalue;
            if (@intFromPtr(upvalue.location) < @intFromPtr(local)) break;
            previous = current;
            current = upvalue.next;
        }

        const created = try Entities.new_upvalue_object(self, local);
        created.next = current;
        if (previous) |prev| {
            prev.next = created;
        } else {
            self.open_upvalues = created;
        }
        return created;
    }

    /// Closes every open upvalue whose stack location is at or above `last`, moving
    /// the captured value out of the stack and into the upvalue itself.
    pub fn close_upvalues(self: *Isolate, last: *TapeValue) void {
        while (self.open_upvalues) |upvalue| {
            if (@intFromPtr(upvalue.location) < @intFromPtr(last)) break;
            upvalue.closed_value = upvalue.location.*;
            upvalue.closed = true;
            upvalue.location = &upvalue.closed_value;
            self.open_upvalues = upvalue.next;
            upvalue.next = null;
        }
    }

    /// Checks if an index is within the given length
    fn checked_index(index: TapeValue, length: usize) RuntimePanic!usize {
        const raw_index = switch (index) {
            .int => |i| i,
            else => return RuntimePanic.CorruptedState,
        };
        if (raw_index < 0) return RuntimePanic.IndexOutOfBounds;

        const idx: usize = @intCast(raw_index);
        if (idx >= length) return RuntimePanic.IndexOutOfBounds;
        return idx;
    }

    /// Gets the utf8 codepoint in string at the given index
    fn stringCodePointSlice(string: *Entities.ObjectString, index: usize) RuntimePanic![]const u8 {
        if (index >= string.code_point_length) return RuntimePanic.IndexOutOfBounds;

        var byte_start: usize = 0;
        var current: usize = 0;
        while (current < index) : (current += 1) {
            const len = std.unicode.utf8ByteSequenceLength(string.chars[byte_start]) catch return RuntimePanic.CorruptedState;
            byte_start += len;
        }

        const len = std.unicode.utf8ByteSequenceLength(string.chars[byte_start]) catch return RuntimePanic.CorruptedState;
        return string.chars[byte_start .. byte_start + len];
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
                    std.debug.print("RETURN: ", .{});
                    Entities.print_value(result);
                    std.debug.print("\n", .{});
                    self.close_upvalues(&self.stack[frame.slot_start]);
                    self.stack_top_index = frame.slot_start - 1;
                    self.frame_count -= 1;
                    if (self.frame_count == 0) {
                        self.open_upvalues = null;
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
                    try self.push_value(.{ .boolean = Entities.values_equal(a, b) });
                },

                .OP_NOT_EQUAL => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();
                    try self.push_value(.{ .boolean = !Entities.values_equal(a, b) });
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

                .OP_STRING_CONCAT => {
                    const b = try self.pop_value();
                    const a = try self.pop_value();

                    const string_b: *Entities.ObjectString = Entities.object_as(Entities.ObjectString, b.object);
                    const string_a: *Entities.ObjectString = Entities.object_as(Entities.ObjectString, a.object);

                    const new_length = string_b.byte_length + string_a.byte_length;
                    const new_chars = try self.base_allocator.alloc(u8, new_length);
                    @memcpy(new_chars[0..string_a.byte_length], string_a.chars);
                    @memcpy(new_chars[string_a.byte_length..], string_b.chars);

                    const new_string = Entities.take_string(self, self.base_allocator, new_chars) catch {
                        return InterpretResult.Error;
                    };
                    try self.push_value(.{ .object = @ptrCast(new_string) });
                },

                .OP_POP => {
                    const v = try self.pop_value();
                    std.debug.print("POP: ", .{});
                    Entities.print_value(v);
                    std.debug.print("\n", .{});
                },

                .OP_POP_N => {
                    const pop_count = frame.read_u16();
                    if (pop_count > 0) {
                        self.close_upvalues(&self.stack[self.stack_top_index - pop_count]);
                    }
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

                .OP_JUMP_IF_ERROR => {
                    const offset = frame.read_u16();
                    const value = try self.peek_value(0);
                    switch (value) {
                        .error_ => {
                            frame.ip += offset;
                        },
                        else => {},
                    }
                },

                .OP_LOOP => {
                    const offset = frame.read_u16();
                    frame.ip -= offset;
                },

                .OP_ARRAY => {
                    const array_length = frame.read_u16();
                    const array_object = try Entities.new_array_object(self, array_length);

                    var i: usize = array_length;
                    while (i > 0) {
                        i -= 1;
                        array_object.elements[i] = try self.pop_value();
                    }
                    array_object.length = array_length;

                    try self.push_value(.{ .object = &array_object.header });
                },
                .OP_TUPLE => {
                    const tuple_length = frame.read_u16();
                    const tuple_object = try Entities.new_tuple_object(self, tuple_length);

                    var i: usize = tuple_length;
                    while (i > 0) {
                        i -= 1;
                        tuple_object.elements[i] = try self.pop_value();
                    }

                    try self.push_value(.{ .object = &tuple_object.header });
                },
                .OP_TABLE => {
                    const count = frame.read_u16();
                    const table_object = try Entities.new_table_object(self);
                    const table_value = TapeValue{ .object = &table_object.header };
                    try self.push_value(table_value);

                    const table_literal_start = self.stack_top_index - 1 - (@as(usize, count) * 2);
                    for (0..count) |i| {
                        const key = self.stack[table_literal_start + i];
                        const value = self.stack[table_literal_start + count + i];
                        _ = Entities.table_set(self, table_object, key, value) catch |err| switch (err) {
                            error.OutOfMemory => return RuntimePanic.OutOfMemory,
                            error.NonHashableElement => return RuntimePanic.CorruptedState,
                        };
                    }

                    self.stack[table_literal_start] = table_value;
                    self.stack_top_index = table_literal_start + 1;
                },
                .OP_INDEX_ARRAY => {
                    const index = try self.peek_value(0);
                    const collection = try self.peek_value(1);
                    const array: *Entities.ObjectArray = switch (collection) {
                        .object => |obj| switch (obj.object_type) {
                            .ObjectArray => @ptrCast(obj),
                            else => return RuntimePanic.CorruptedState,
                        },
                        else => return RuntimePanic.CorruptedState,
                    };
                    const idx = try checked_index(index, array.length);
                    const value = array.elements[idx];
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    try self.push_value(value);
                },
                .OP_INDEX_STRING => {
                    const index = try self.peek_value(0);
                    const collection = try self.peek_value(1);
                    const string: *Entities.ObjectString = switch (collection) {
                        .object => |obj| switch (obj.object_type) {
                            .ObjectString => @ptrCast(obj),
                            else => return RuntimePanic.CorruptedState,
                        },
                        else => return RuntimePanic.CorruptedState,
                    };
                    const idx = try checked_index(index, string.code_point_length);
                    const chars = try stringCodePointSlice(string, idx);
                    const result = Entities.copy_string(self, chars) catch |err| switch (err) {
                        error.OutOfMemory => return RuntimePanic.OutOfMemory,
                        else => return RuntimePanic.CorruptedState,
                    };
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    try self.push_value(.{ .object = @ptrCast(result) });
                },
                .OP_INDEX_TABLE => {
                    const key = try self.peek_value(0);
                    const collection = try self.peek_value(1);
                    const table: *Entities.ObjectTable = switch (collection) {
                        .object => |obj| switch (obj.object_type) {
                            .ObjectTable => @ptrCast(obj),
                            else => return RuntimePanic.CorruptedState,
                        },
                        else => return RuntimePanic.CorruptedState,
                    };
                    const value = (Entities.table_get(table, key) catch |err| switch (err) {
                        error.NonHashableElement => return RuntimePanic.CorruptedState,
                    }) orelse return RuntimePanic.KeyNotFound;
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    try self.push_value(value);
                },
                .OP_INDEX_TUPLE => {
                    const index = frame.read_u16();
                    const collection = try self.peek_value(0);
                    const tuple: *Entities.ObjectTuple = switch (collection) {
                        .object => |obj| switch (obj.object_type) {
                            .ObjectTuple => @ptrCast(obj),
                            else => return RuntimePanic.CorruptedState,
                        },
                        else => return RuntimePanic.CorruptedState,
                    };
                    if (index >= tuple.elements.len) return RuntimePanic.IndexOutOfBounds;
                    const value = tuple.elements[index];
                    _ = try self.pop_value();
                    try self.push_value(value);
                },
                .OP_CALL => {
                    const arg_count = frame.read_u16();
                    const callee = try self.peek_value(arg_count);
                    const closure: *Entities.ObjectClosure = switch (callee) {
                        .object => |obj| switch (obj.object_type) {
                            .ObjectClosure => @ptrCast(obj),
                            else => return RuntimePanic.CorruptedState, // not callable — type checker should have caught this
                        },
                        else => return RuntimePanic.CorruptedState,
                    };
                    try self.call(closure, arg_count);
                    frame = &self.frames[self.frame_count - 1]; // re-point at the new frame, same pattern OP_RETURN already uses
                },
                .OP_CLOSURE => {
                    const function_value = frame.read_constant();
                    const function: *Entities.ObjectFunction = switch (function_value) {
                        .object => |obj| switch (obj.object_type) {
                            .ObjectFunction => @ptrCast(obj),
                            else => return RuntimePanic.CorruptedState,
                        },
                        else => return RuntimePanic.CorruptedState,
                    };
                    const closure = try Entities.new_closure_object(self, function);
                    for (0..function.upvalue_count) |upvalue_slot| {
                        const captures_parent_local = frame.read_u8() != 0;
                        const parent_slot = frame.read_u16();
                        closure.upvalues[upvalue_slot] = if (captures_parent_local)
                            try self.capture_upvalue(&self.stack[frame.slot_start + parent_slot])
                        else
                            frame.closure.upvalues[parent_slot];
                    }
                    try self.push_value(.{ .object = &closure.header });
                },
                .OP_LOAD_FUNCTION_CONSTANT => {
                    const index = frame.read_u16();
                    try self.push_value(self.function_constants.items[index]);
                },
                .OP_LOAD_UPVALUE => {
                    const index = frame.read_u16();
                    const upvalue = frame.closure.upvalues[index];
                    try self.push_value(if (upvalue.closed) upvalue.closed_value else upvalue.location.*);
                },
                .OP_STORE_UPVALUE => {
                    const index = frame.read_u16();
                    const upvalue = frame.closure.upvalues[index];
                    if (upvalue.closed) {
                        upvalue.closed_value = try self.peek_value(0);
                    } else {
                        upvalue.location.* = try self.peek_value(0);
                    }
                },
            }
        }
    }
};
