const std = @import("std");
const Natives = @import("../natives/natives.zig").Natives;
const Entities = @import("entities.zig");
const Chunk = @import("chunk.zig");
const BasicGarbageCollector = @import("../memory/basic_garbage_collector.zig");
const ManagedAllocator = @import("../memory/managed_allocator.zig");
const Workspace = @import("../compiler/workspace.zig").Workspace;
const TapeValue = Entities.Value;
const Opcode = Chunk.Opcode;
const VM = @import("vm.zig").VM;
const RuntimePanic = @import("vm.zig").RuntimePanic;
const object_as = @import("entities.zig").object_as;

pub const ExecutionResult = union(enum) {
    Ok: TapeValue,
    Yielded: TapeValue,
};

/// Represents an isolate, which is a self-contained execution context.
pub const Isolate = struct {
    vm: *VM,
    gc: *BasicGarbageCollector.BasicGarbageCollector,
    base_allocator: std.mem.Allocator,

    string_intern: std.StringHashMap(*Entities.ObjectString),
    isolate_closure: *Entities.ObjectClosure,

    function_constants: [*]TapeValue,
    function_constants_count: usize,

    globals: [*]TapeValue,
    globals_count: usize,

    execution_state: Entities.ExecutionState,

    current: *Entities.ExecutionState,

    pub fn init(vm: *VM, base_allocator: std.mem.Allocator, globals_count: usize, function_constants_count: usize) !*Isolate {
        const isolate = try base_allocator.create(Isolate);
        isolate.vm = vm;
        isolate.base_allocator = base_allocator;
        isolate.isolate_closure = undefined;
        isolate.string_intern = std.StringHashMap(*Entities.ObjectString).init(base_allocator);

        isolate.gc = try BasicGarbageCollector.BasicGarbageCollector.init(base_allocator, isolate, mark_roots, clean_string_intern);

        isolate.execution_state = try Entities.ExecutionState.init(isolate.gc.managed_allocator.allocator(), vm.config.frame_capacity, vm.config.stack_size);

        isolate.globals = @ptrCast(@alignCast(try base_allocator.alloc(TapeValue, globals_count)));
        isolate.globals_count = globals_count;
        // initialize globals to nil
        for (0..globals_count) |index| {
            isolate.globals[index] = .nil;
        }
        isolate.function_constants = @ptrCast(@alignCast(try base_allocator.alloc(TapeValue, function_constants_count)));
        isolate.function_constants_count = function_constants_count;
        // initialize function constants to nil
        for (0..function_constants_count) |index| {
            isolate.function_constants[index] = .nil;
        }

        isolate.current = &isolate.execution_state;

        return isolate;
    }

    pub fn deinit(self: *Isolate) void {
        self.string_intern.deinit();
        self.execution_state.deinit(self.gc.managed_allocator.allocator());
        self.base_allocator.free(self.globals[0..self.globals_count]);
        self.base_allocator.free(self.function_constants[0..self.function_constants_count]);
        self.gc.deinit();
        self.base_allocator.destroy(self);
    }

    fn mark_roots(ptr: *anyopaque, gc: *BasicGarbageCollector.BasicGarbageCollector) void {
        const isolate: *Isolate = @ptrCast(@alignCast(ptr));

        // mark isolate closure
        gc.mark_object(&isolate.isolate_closure.header) catch {
            // if we fail to add a to the gray list
            // this is catastrofic - but keep going.
        };

        // mark execution states
        isolate.execution_state.mark_execution_state(gc) catch {
            // if we fail to add a to the gray list
            // this is catastrofic - but keep going.
        };
        if (isolate.current != &isolate.execution_state) {
            isolate.current.mark_execution_state(gc) catch {
                // if we fail to add a to the gray list
                // this is catastrofic - but keep going.
            };
        }
        // mark globals
        for (0..isolate.globals_count) |index| {
            Entities.mark_value(gc, isolate.globals[index]) catch {
                isolate.vm.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .severity = .Error, .message = "Failed to mark value", .stage = .Execution, .file_path = "", .hint = "This is an internal error. Please report it to the TAPE-lang team." }) catch {};
            };
        }
        // mark functions
        for (0..isolate.function_constants_count) |index| {
            Entities.mark_value(gc, isolate.function_constants[index]) catch {
                isolate.vm.workspace.diagnostics.add_diagnostic(.{ .column = 0, .line = 0, .severity = .Error, .message = "Failed to mark value", .stage = .Execution, .file_path = "", .hint = "This is an internal error. Please report it to the TAPE-lang team." }) catch {};
            };
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
        if (self.current.stack_top_index >= self.current.stack_size) {
            return error.StackOverflow;
        }
        self.current.stack[self.current.stack_top_index] = value;
        self.current.stack_top_index += 1;
    }

    /// Returns the value at the top of the stack
    pub fn pop_value(self: *Isolate) !TapeValue {
        if (self.current.stack_top_index == 0) {
            return error.StackUnderflow;
        }

        self.current.stack_top_index -= 1;
        return self.current.stack[self.current.stack_top_index];
    }

    /// Gets the value on the stack at the given offset
    pub fn peek_value(self: *Isolate, offset: usize) !TapeValue {
        if (offset >= self.current.stack_top_index) {
            return error.StackUnderflow;
        }
        return self.current.stack[self.current.stack_top_index - 1 - offset];
    }

    fn continue_deferred_run(self: *Isolate, frame: *Entities.CallFrame) RuntimePanic!void {
        if (self.current.deferred_runs.items.len == 0) return RuntimePanic.CorruptedState;
        const run_index = self.current.deferred_runs.items.len - 1;
        const run = self.current.deferred_runs.items[run_index];
        while (self.current.deferred_entries.items.len > run.entry_start) {
            const entry = self.current.deferred_entries.pop() orelse return RuntimePanic.CorruptedState;
            if (entry.is_errdefer and !run.run_error_defers) continue;
            frame.ip = entry.target_ip;
            return;
        }
        const finished_run = self.current.deferred_runs.pop() orelse return RuntimePanic.CorruptedState;
        if (finished_run.saved_value) |value| try self.push_value(value);
        frame.ip = run.continuation_ip;
    }

    /// Returns an upvalue pointing at the given stack slot, reusing an existing open
    /// upvalue so multiple closures capturing the same local share it. The open-upvalue
    /// list is kept sorted by descending stack address so that close_upvalues can stop
    /// scanning as soon as it reaches an upvalue below the boundary.
    pub fn capture_upvalue(self: *Isolate, local: *TapeValue) !*Entities.ObjectUpvalue {
        var previous: ?*Entities.ObjectUpvalue = null;
        var current = self.current.open_upvalues;
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
            self.current.open_upvalues = created;
        }
        return created;
    }

    /// Closes every open upvalue whose stack location is at or above `last`, moving
    /// the captured value out of the stack and into the upvalue itself.
    pub fn close_upvalues(self: *Isolate, last: *TapeValue) void {
        while (self.current.open_upvalues) |upvalue| {
            if (@intFromPtr(upvalue.location) < @intFromPtr(last)) break;
            upvalue.closed_value = upvalue.location.*;
            upvalue.closed = true;
            upvalue.location = &upvalue.closed_value;
            self.current.open_upvalues = upvalue.next;
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
        if (self.current.frame_count + 1 >= self.vm.config.frame_capacity) {
            return RuntimePanic.StackOverflow;
        }
        self.current.frame_count += 1;
        const frame = &self.current.frames[self.current.frame_count - 1];
        frame.closure = closure;
        frame.ip = 0;
        // the closure is at self.current.stack_top_index
        frame.slot_start = self.current.stack_top_index - arg_count;
    }

    pub fn execute(self: *Isolate) RuntimePanic!ExecutionResult {
        try self.push_value(TapeValue{ .object = &self.isolate_closure.header });
        try self.call(self.isolate_closure, 0);
        return try self.execution_loop();
    }

    pub fn current_line(self: *const Isolate) ?usize {
        if (self.current.frame_count == 0) return null;
        const frame = &self.current.frames[self.current.frame_count - 1];
        if (frame.ip == 0) return null;
        if (frame.ip - 1 >= frame.closure.function.chunk.line_numbers.items.len) return null;
        return frame.closure.function.chunk.line_numbers.items[frame.ip - 1];
    }

    pub fn print_stack_trace(self: *Isolate, with_value: ?TapeValue, error_type: RuntimePanic) void {
        var frame_count = self.current.frame_count;

        std.debug.print("TAPE panic --- Unhandled {s}\n" ++ "with value: ", .{@errorName(error_type)});
        if (with_value) |v| {
            Entities.print_value(v);
        }
        std.debug.print("\n", .{});

        std.debug.print("Stack Trace: \n", .{});

        while (frame_count > 0) : (frame_count -= 1) {
            const call_frame = &self.current.frames[frame_count - 1];
            if (call_frame.ip == 0) continue;
            if (call_frame.ip - 1 >= call_frame.closure.function.chunk.line_numbers.items.len) continue;
            const callable_name = if (call_frame.closure.function.name) |name| name.chars else if (frame_count - 1 == 0) "main" else "anonymous";
            const line = call_frame.closure.function.chunk.line_numbers.items[call_frame.ip - 1];
            std.debug.print("  at {s}() [{s}:{d}]\n", .{ callable_name, call_frame.closure.function.chunk.file_path, line });
        }
    }

    pub fn execution_loop(self: *Isolate) RuntimePanic!ExecutionResult {
        var frame = &self.current.frames[self.current.frame_count - 1];

        while (true) {
            const instruction: Opcode = @fromBackingInt(@intCast(frame.closure.function.chunk.code.items[frame.ip]));
            frame.ip += 1;

            switch (instruction) {
                .OP_RETURN => {
                    const result = try self.pop_value();
                    if (self.vm.config.debug_execution) {
                        std.debug.print("RETURN: ", .{});
                        Entities.print_value(result);
                        std.debug.print("\n", .{});
                    }
                    self.close_upvalues(&self.current.stack[frame.slot_start]);
                    self.current.stack_top_index = frame.slot_start - 1;
                    self.current.frame_count -= 1;
                    if (self.current.frame_count == 0) {
                        self.current.open_upvalues = null;
                        return .{ .Ok = result };
                    }

                    try self.push_value(result);
                    frame = &self.current.frames[self.current.frame_count - 1];
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
                    const b = try self.peek_value(0);
                    const a = try self.peek_value(1);

                    const string_b: *Entities.ObjectString = object_as(Entities.ObjectString, b.object);
                    const string_a: *Entities.ObjectString = object_as(Entities.ObjectString, a.object);

                    const new_length = string_b.byte_length + string_a.byte_length;
                    const new_chars = try self.base_allocator.alloc(u8, new_length);
                    @memcpy(new_chars[0..string_a.byte_length], string_a.chars);
                    @memcpy(new_chars[string_a.byte_length..], string_b.chars);

                    const new_string = Entities.take_string(self, self.base_allocator, new_chars) catch {
                        return RuntimePanic.OutOfMemory;
                    };
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    try self.push_value(.{ .object = @ptrCast(new_string) });
                },

                .OP_POP => {
                    const v = try self.pop_value();
                    if (self.vm.config.debug_execution) {
                        std.debug.print("POP: ", .{});
                        Entities.print_value(v);
                        std.debug.print("\n", .{});
                    }
                },

                .OP_POP_N => {
                    const pop_count = frame.read_u16();
                    if (pop_count > 0) {
                        self.close_upvalues(&self.current.stack[self.current.stack_top_index - pop_count]);
                    }
                    self.current.stack_top_index -= pop_count;
                },

                .OP_DEFER_SCOPE => {
                    self.current.deferred_scopes.append(self.gc.managed_allocator.allocator(), .{
                        .entry_start = self.current.deferred_entries.items.len,
                        .frame_index = self.current.frame_count - 1,
                    }) catch return RuntimePanic.OutOfMemory;
                },

                .OP_DEFER_PUSH => {
                    const target_ip = frame.read_u32();
                    const is_errdefer = frame.read_u8() != 0;
                    self.current.deferred_entries.append(self.gc.managed_allocator.allocator(), .{
                        .target_ip = target_ip,
                        .is_errdefer = is_errdefer,
                    }) catch return RuntimePanic.OutOfMemory;
                },

                .OP_DEFER_RUN => {
                    const mode = frame.read_u8();
                    if (self.current.deferred_scopes.items.len == 0) return RuntimePanic.CorruptedState;
                    const scope = self.current.deferred_scopes.pop() orelse return RuntimePanic.CorruptedState;
                    if (scope.frame_index != self.current.frame_count - 1) return RuntimePanic.CorruptedState;
                    const run_error_defers = switch (mode) {
                        0 => false,
                        1 => true,
                        2 => if (self.current.stack_top_index > 0) self.current.stack[self.current.stack_top_index - 1] == .error_ else false,
                        3 => false,
                        else => return RuntimePanic.CorruptedState,
                    };
                    const saved_value = if (mode != 0) try self.peek_value(0) else null;
                    self.current.deferred_runs.append(self.gc.managed_allocator.allocator(), .{
                        .entry_start = scope.entry_start,
                        .continuation_ip = frame.ip,
                        .frame_index = scope.frame_index,
                        .run_error_defers = run_error_defers,
                        .saved_value = saved_value,
                    }) catch return RuntimePanic.OutOfMemory;
                    if (mode != 0) _ = try self.pop_value();
                    try self.continue_deferred_run(frame);
                },

                .OP_DEFER_END => try self.continue_deferred_run(frame),

                .OP_GIVE_POP => {
                    const pop_count = frame.read_u16();
                    const give_value = try self.pop_value();
                    if (pop_count > 0) {
                        self.close_upvalues(&self.current.stack[self.current.stack_top_index - pop_count]);
                        self.current.stack_top_index -= pop_count;
                    }
                    try self.push_value(give_value);
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
                    self.current.stack[frame.slot_start + index] = try self.peek_value(0);
                },
                .OP_LOAD_LOCAL => {
                    const index = frame.read_u16();
                    try self.push_value(self.current.stack[frame.slot_start + index]);
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
                    try self.push_value(table_value); // root the table

                    const table_literal_start = self.current.stack_top_index - 1 - (@as(usize, count) * 2);
                    for (0..count) |i| {
                        const key = self.current.stack[table_literal_start + i];
                        const value = self.current.stack[table_literal_start + count + i];
                        _ = Entities.table_set(self, table_object, key, value) catch |err| switch (err) {
                            error.OutOfMemory => return RuntimePanic.OutOfMemory,
                            error.NonHashableElement => return RuntimePanic.CorruptedState,
                        };
                    }

                    self.current.stack[table_literal_start] = table_value;
                    self.current.stack_top_index = table_literal_start + 1;
                },

                .OP_INDEX_ARRAY => {
                    const index = try self.pop_value();
                    const collection = try self.pop_value();
                    const array: *Entities.ObjectArray = object_as(Entities.ObjectArray, collection.object);
                    const idx = try checked_index(index, array.length);
                    const value = array.elements[idx];
                    try self.push_value(value);
                },

                .OP_INDEX_STRING => {
                    const index = try self.peek_value(0);
                    const collection = try self.peek_value(1);
                    const string: *Entities.ObjectString = object_as(Entities.ObjectString, collection.object);
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
                    const key = try self.pop_value();
                    const collection = try self.pop_value();
                    const table: *Entities.ObjectTable = object_as(Entities.ObjectTable, collection.object);
                    const value = (Entities.table_get(table, key) catch |err| switch (err) {
                        error.NonHashableElement => return RuntimePanic.CorruptedState,
                    }) orelse return RuntimePanic.KeyNotFound;
                    try self.push_value(value);
                },

                .OP_INDEX_TUPLE => {
                    const index = frame.read_u16();
                    const collection = try self.pop_value();
                    const tuple: *Entities.ObjectTuple = object_as(Entities.ObjectTuple, collection.object);
                    if (index >= tuple.elements.len) return RuntimePanic.IndexOutOfBounds;
                    const value = tuple.elements[index];
                    try self.push_value(value);
                },

                .OP_SET_INDEX_ARRAY => {
                    const value = try self.peek_value(0);
                    const index = try self.peek_value(1);
                    const collection = try self.peek_value(2);
                    const array: *Entities.ObjectArray = object_as(Entities.ObjectArray, collection.object);
                    const idx = try checked_index(index, array.length);
                    array.elements[idx] = value;
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    try self.push_value(value);
                },

                .OP_SET_INDEX_TABLE => {
                    const value = try self.peek_value(0);
                    const key = try self.peek_value(1);
                    const collection = try self.peek_value(2);
                    const table: *Entities.ObjectTable = object_as(Entities.ObjectTable, collection.object);
                    _ = Entities.table_set(self, table, key, value) catch |err| switch (err) {
                        error.OutOfMemory => return RuntimePanic.OutOfMemory,
                        error.NonHashableElement => return RuntimePanic.CorruptedState,
                    };
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    _ = try self.pop_value();
                    try self.push_value(value);
                },

                .OP_CALL_NATIVE => {
                    const arg_count = frame.read_u16();
                    const slot = frame.read_u16();
                    const native_fn = Natives.get(slot);
                    const result = try native_fn(self, self.current.stack[self.current.stack_top_index - arg_count .. self.current.stack_top_index]);
                    // unwinding stack slots
                    self.current.stack_top_index -= arg_count;
                    try self.push_value(result);
                },

                .OP_CALL => {
                    const arg_count = frame.read_u16();
                    const callee = try self.peek_value(arg_count);
                    const closure: *Entities.ObjectClosure = object_as(Entities.ObjectClosure, callee.object);
                    try self.call(closure, arg_count);
                    frame = &self.current.frames[self.current.frame_count - 1]; // re-point at the new frame
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
                    // root the closure
                    try self.push_value(.{ .object = &closure.header });

                    if (function.upvalue_count != 0) {
                        const upvalues = try self.gc.managed_allocator.allocator().alloc(*Entities.ObjectUpvalue, function.upvalue_count);
                        errdefer {
                            self.gc.managed_allocator.allocator().free(upvalues);
                            _ = self.pop_value() catch {
                                // do nothing if we fail at this point
                            }; // remove the rooted closure on failure
                        }

                        for (0..function.upvalue_count) |upvalue_slot| {
                            const captures_parent_local = frame.read_u8() != 0;
                            const parent_slot = frame.read_u16();
                            upvalues[upvalue_slot] = if (captures_parent_local)
                                try self.capture_upvalue(&self.current.stack[frame.slot_start + parent_slot])
                            else
                                frame.closure.upvalues[parent_slot];
                        }
                        closure.upvalues = upvalues;
                    }
                    // remove rooted closure
                    _ = try self.pop_value();
                    try self.push_value(.{ .object = &closure.header });
                },
                .OP_COROUTINE => {
                    const arg_count = frame.read_u16();
                    const callee = try self.peek_value(arg_count);
                    const closure_object: *Entities.ObjectClosure = object_as(Entities.ObjectClosure, callee.object);

                    // Copy args off the caller's stack - these will be copied to the coroutines stack.
                    var args = try std.ArrayList(TapeValue).initCapacity(self.base_allocator, arg_count);
                    defer args.deinit(self.base_allocator);
                    for (0..arg_count) |i| {
                        args.appendAssumeCapacity(try self.peek_value(arg_count - 1 - i));
                    }

                    const coroutine = try Entities.new_coroutine_object(self, closure_object, self.vm.config.frame_capacity, self.vm.config.stack_size);

                    const prev_execution_state = self.current;
                    self.current = &coroutine.execution_state;

                    try self.push_value(.{ .object = &coroutine.closure.header });
                    for (args.items) |arg| try self.push_value(arg);
                    try self.call(coroutine.closure, arg_count);

                    self.current = prev_execution_state;

                    // discard callee + args from the caller's stack
                    self.current.stack_top_index -= (arg_count + 1);
                    try self.push_value(.{ .object = &coroutine.header });
                },

                .OP_RESUME => {
                    const resume_value = try self.pop_value();
                    const coroutine_value = try self.peek_value(0); // keep the coroutine on the stack
                    const coroutine_object: *Entities.ObjectCoroutine = object_as(Entities.ObjectCoroutine, coroutine_value.object);

                    switch (coroutine_object.state) {
                        .FINISHED => return RuntimePanic.FinishedCoroutineResumption,
                        .SUSPENDED, .RUNNING => {},
                    }
                    if (coroutine_object.state == .RUNNING) return RuntimePanic.CoroutineAlreadyRunning;

                    const prev_execution_state = self.current;
                    self.current = &coroutine_object.execution_state;
                    coroutine_object.state = .RUNNING;

                    // Before the first resume the resume value is discarded.
                    // once started it feeds yield
                    if (coroutine_object.started) {
                        try self.push_value(resume_value);
                    } else {
                        coroutine_object.started = true;
                    }

                    const result = self.execution_loop(); // resume execution where you left off
                    self.current = prev_execution_state;
                    _ = try self.pop_value(); // the executed coroutine

                    switch (try result) {
                        .Ok => |value| {
                            coroutine_object.state = .{ .FINISHED = value };
                            try self.push_value(.nil);
                        },
                        .Yielded => |value| {
                            coroutine_object.state = .SUSPENDED;
                            try self.push_value(value);
                        },
                    }
                },

                // Give execution back to your caller
                .OP_YIELD => {
                    const value = try self.pop_value();
                    return .{ .Yielded = value }; // return from the nested execution scope with the yielded value
                },

                .OP_LOAD_FUNCTION_CONSTANT => {
                    const index = frame.read_u16();
                    try self.push_value(self.function_constants[index]);
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

                .OP_STRUCT => {
                    const type_id = frame.read_u32();
                    const field_count = frame.read_u16();

                    const instance = try self.gc.allocate_object(Entities.ObjectStructInstance, .ObjectStructInstance);
                    instance.type_id = type_id;
                    instance.fields = try self.gc.managed_allocator.allocator().alloc(TapeValue, field_count);

                    var i: usize = field_count;
                    while (i > 0) {
                        i -= 1;
                        instance.fields[i] = try self.pop_value();
                    }

                    try self.push_value(.{ .object = &instance.header });
                },

                .OP_GET_FIELD => {
                    const index = frame.read_u16();
                    const struct_val = try self.pop_value();
                    const instance = object_as(Entities.ObjectStructInstance, struct_val.object);

                    try self.push_value(instance.fields[index]);
                },

                .OP_SET_FIELD => {
                    const index = frame.read_u16();
                    const new_val = try self.pop_value();
                    const struct_val = try self.pop_value();
                    const instance = object_as(Entities.ObjectStructInstance, struct_val.object);

                    instance.fields[index] = new_val;
                    try self.push_value(new_val); // Assignment expression evaluates to the assigned value
                },

                .OP_DUP => {
                    const top = try self.peek_value(0);
                    try self.push_value(top);
                },
                .OP_DUP_TWO => {
                    const first = try self.peek_value(1);
                    const second = try self.peek_value(0);
                    try self.push_value(first);
                    try self.push_value(second);
                },

                .OP_PANIC => {
                    const with_value = try self.pop_value();
                    self.print_stack_trace(with_value, RuntimePanic.Panic);
                    return RuntimePanic.Panic;
                },

                .OP_RANGE => {
                    const end = try self.pop_value();
                    const start = try self.pop_value();
                    var step: i64 = 1;

                    if (end.int < start.int) {
                        step = -1;
                    }

                    const range_object = try Entities.new_range_object(self, start.int, end.int, step);
                    try self.push_value(.{ .object = &range_object.header });
                },

                .OP_FOR_PREP => {
                    const iterator_var = frame.read_u16();
                    const exit_offset = frame.read_u16();
                    const range_val = self.current.stack[frame.slot_start + iterator_var - 1];
                    const range = object_as(Entities.ObjectRange, range_val.object);

                    const is_empty = if (range.step > 0) range.start >= range.end else range.start <= range.end;
                    if (is_empty) {
                        frame.ip += exit_offset;
                    } else {
                        self.current.stack[frame.slot_start + iterator_var] = .{ .int = range.start };
                    }
                },

                .OP_FOR_NEXT => {
                    const iteratr_var = frame.read_u16();
                    const loop_offset = frame.read_u16();
                    const range_val = self.current.stack[frame.slot_start + iteratr_var - 1];
                    const range = object_as(Entities.ObjectRange, range_val.object);

                    var current_i = self.current.stack[frame.slot_start + iteratr_var].int;
                    current_i += range.step;
                    self.current.stack[frame.slot_start + iteratr_var] = .{ .int = current_i };

                    const should_continue = if (range.step > 0) current_i < range.end else current_i > range.end;
                    if (should_continue) {
                        frame.ip -= loop_offset;
                    }
                },
                .OP_OPTIONAL_UNWRAP => {
                    const top = try self.peek_value(0);
                    if (top == .nil) return RuntimePanic.FailedOptionalUnwrap;
                },
                .OP_NEW_ENUM => {
                    const type_id = frame.read_u32();
                    const tag = frame.read_u32();
                    const payload_count = frame.read_u16();
                    const enum_object = try self.gc.allocate_object(Entities.ObjectEnum, .ObjectEnum);
                    enum_object.type_id = type_id;
                    enum_object.tag = tag;
                    enum_object.payloads = &.{};
                    try self.push_value(.{ .object = &enum_object.header });
                    if (payload_count > 0) {
                        const payload_len: usize = @intCast(payload_count);
                        const payloads = try self.gc.managed_allocator.allocator().alloc(TapeValue, payload_len);
                        for (0..payload_len) |i| payloads[payload_len - i - 1] = try self.peek_value(i + 1);
                        enum_object.payloads = payloads;
                    }
                    _ = try self.pop_value();
                    for (0..payload_count) |_| _ = try self.pop_value();
                    try self.push_value(.{ .object = &enum_object.header });
                },
                .OP_ENUM_TAG => {
                    const enum_value = try self.pop_value();
                    const enum_object = object_as(Entities.ObjectEnum, enum_value.object);
                    try self.push_value(.{ .int = @intCast(enum_object.tag) });
                },
                .OP_ENUM_UNIT_TAG => {
                    const enum_value = try self.pop_value();
                    try self.push_value(.{ .int = @intCast(enum_value.enum_.index) });
                },
                .OP_ENUM_FIELD => {
                    const index = frame.read_u16();
                    const enum_value = try self.pop_value();
                    const enum_object = object_as(Entities.ObjectEnum, enum_value.object);
                    try self.push_value(enum_object.payloads[index]);
                },
            }
        }
    }
};
