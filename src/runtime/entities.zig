//! Entity Representation for TAPE
//! Entities are Values and Objects.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const Isolate = @import("isolate.zig").Isolate;
const AST = @import("../compiler/ast.zig");
const BasicGarbageCollector = @import("../memory/basic_garbage_collector.zig");
const basic_gc = BasicGarbageCollector.BasicGarbageCollector;
const mark_object = basic_gc.mark_object;
const options = @import("TAPE_lang_build_options");

pub const CallFrame = struct {
    closure: *ObjectClosure,
    ip: usize,
    slot_start: usize,

    pub fn read_u8(frame: *CallFrame) u8 {
        frame.ip += 1;
        return frame.closure.function.chunk.code.items[frame.ip - 1];
    }

    pub fn read_u32(frame: *CallFrame) u32 {
        frame.ip += 4;
        const code = frame.closure.function.chunk.code.items;

        const high_high: u32 = code[frame.ip - 4];
        const low_high: u32 = code[frame.ip - 3];
        const high_low: u32 = code[frame.ip - 2];
        const low_low: u32 = code[frame.ip - 1];

        return (high_high << 24) | (low_high << 16) | (high_low << 8) | (low_low);
    }

    pub fn read_u16(frame: *CallFrame) u16 {
        frame.ip += 2;
        const code = frame.closure.function.chunk.code.items;
        const high: u16 = code[frame.ip - 2];
        const low: u16 = code[frame.ip - 1];
        return (high << 8) | low;
    }

    pub fn read_constant(frame: *CallFrame) Value {
        const index = CallFrame.read_u16(frame);
        return frame.closure.function.chunk.constants.items[index];
    }

    pub fn read_string(frame: *CallFrame) *ObjectString {
        const constant = frame.read_constant(frame);
        return @ptrCast(constant.object);
    }
};

/// Type of a heap allocated TAPE object.
pub const ObjectType = enum(u8) {
    ObjectString,
    ObjectArray,
    ObjectTable,
    ObjectTuple,
    ObjectFunction,
    ObjectClosure,
    ObjectCoroutine,
    ObjectUpvalue,
    ObjectStructInstance,
    ObjectRange,
};

pub const ObjectHeader = struct {
    next: ?*ObjectHeader,
    object_type: ObjectType,
    marked: bool,
};

pub const ObjectString = struct {
    header: ObjectHeader,
    chars: []const u8,
    byte_length: usize,
    code_point_length: usize,
    hash: u64,
};

pub const ObjectArray = struct {
    header: ObjectHeader,
    elements: []Value,
    capacity: usize,
    length: usize,
};

pub const TableEntryState = enum {
    empty,
    tombstone,
    occupied,
};

pub const TableEntry = struct {
    key: Value = .nil,
    value: Value = .nil,
    state: TableEntryState = .empty,
};

pub const ObjectTable = struct {
    header: ObjectHeader,
    entries: []TableEntry,
    capacity: usize,
    length: usize,
};

pub const ObjectTuple = struct {
    header: ObjectHeader,
    elements: []Value,
};

pub const ObjectFunction = struct {
    header: ObjectHeader,
    name: ?*ObjectString,
    chunk: Chunk,
    upvalue_count: usize,
    arity: usize,
};

pub const ObjectClosure = struct {
    header: ObjectHeader,
    function: *ObjectFunction,
    upvalues: []*ObjectUpvalue,
};

pub const ObjectUpvalue = struct {
    header: ObjectHeader,
    /// Next upvalue in the isolate's open-upvalue list.
    next: ?*ObjectUpvalue = null,
    /// Where the captured value lives on the VM stack while it is still open.
    location: *Value,
    /// Once the upvalue is closed (its stack slot has gone out of scope), the value is moved here.
    closed_value: Value,
    /// True once the upvalue no longer points into the VM stack.
    closed: bool = false,
};

pub const CoroutineState = union(enum) {
    SUSPENDED,
    RUNNING,
    FINISHED: Value,
};

pub const DeferredEntry = struct { target_ip: usize, is_errdefer: bool };
pub const DeferredScope = struct { entry_start: usize, frame_index: usize };
pub const DeferredRun = struct {
    entry_start: usize,
    continuation_ip: usize,
    frame_index: usize,
    run_error_defers: bool,
    saved_value: ?Value,
};

pub const ExecutionState = struct {
    stack: [*]Value,
    stack_top_index: usize,
    stack_size: usize,
    frames: [*]CallFrame,
    frame_count: usize,
    frame_capacity: usize,
    open_upvalues: ?*ObjectUpvalue,
    deferred_entries: std.ArrayList(DeferredEntry),
    deferred_scopes: std.ArrayList(DeferredScope),
    deferred_runs: std.ArrayList(DeferredRun),

    pub fn init(allocator: std.mem.Allocator, frame_capacity: usize, stack_size: usize) !ExecutionState {
        const frames: [*]CallFrame = @ptrCast(@alignCast(try allocator.alloc(CallFrame, frame_capacity)));
        errdefer allocator.free(frames[0..frame_capacity]);
        const stack: [*]Value = @ptrCast(@alignCast(try allocator.alloc(Value, stack_size)));

        return .{
            .frame_count = 0,
            .frames = frames,
            .stack = stack,
            .stack_top_index = 0,
            .stack_size = stack_size,
            .frame_capacity = frame_capacity,
            .open_upvalues = null,
            .deferred_entries = .empty,
            .deferred_scopes = .empty,
            .deferred_runs = .empty,
        };
    }

    pub fn deinit(self: *ExecutionState, allocator: std.mem.Allocator) void {
        allocator.free(self.frames[0..self.frame_capacity]);
        allocator.free(self.stack[0..self.stack_size]);
        self.deferred_entries.deinit(allocator);
        self.deferred_scopes.deinit(allocator);
        self.deferred_runs.deinit(allocator);
        self.open_upvalues = null;
    }

    pub fn mark_execution_state(self: *ExecutionState, garbage_collector: *basic_gc) !void {
        // mark frame closures
        for (self.frames[0..self.frame_count]) |frame| {
            try mark_object(garbage_collector, &frame.closure.header);
        }

        // mark upvalues
        var current = self.open_upvalues;
        while (current) |upvalue| {
            try mark_object(garbage_collector, &upvalue.header);
            current = upvalue.next;
        }

        // mark the stack
        for (self.stack[0..self.stack_top_index]) |value| {
            try mark_value(garbage_collector, value);
        }
        for (self.deferred_runs.items) |run| {
            if (run.saved_value) |value| try mark_value(garbage_collector, value);
        }
    }
};

pub const ObjectCoroutine = struct {
    header: ObjectHeader,
    closure: *ObjectClosure,
    execution_state: ExecutionState,
    state: CoroutineState,
    /// Whether the coroutine has been resumed at least once. Until it suspends
    /// at a yield, resume values have nowhere to go and are discarded.
    started: bool,
};

pub const ObjectStructInstance = struct {
    header: ObjectHeader,
    type_id: AST.TypeId,
    fields: []Value,
};

pub const ObjectRange = struct {
    header: ObjectHeader,
    start: i64,
    end: i64,
    step: i64,
};

pub const Variant = struct {
    type_id: AST.TypeId,
    index: u32,
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    nil: void,
    object: *ObjectHeader,
    enum_: Variant,
    error_: Variant,
};

/// hash of a TAPE Value
pub fn hash_value(value: Value) error{NonHashableElement}!u64 {
    return switch (value) {
        .boolean => |b| @as(u64, @intFromBool(b)),
        .float => |f| if (f == 0) 0 else @bitCast(f),
        .int => |i| @as(u64, @bitCast(i)),
        .nil => std.math.maxInt(u64),
        .enum_ => |variant| hash_variant(0x9e3779b97f4a7c15, variant), // magic number mixing constant
        .error_ => |variant| hash_variant(0xbf58476d1ce4e5b9, variant), // magic number mixing constant
        .object => |obj| switch (obj.object_type) {
            .ObjectString => @as(*ObjectString, @ptrCast(obj)).hash,
            else => error.NonHashableElement,
        },
    };
}

fn hash_variant(seed: u64, variant: Variant) u64 {
    var hash = seed;
    hash ^= @as(u64, variant.type_id) +% 0x9e3779b97f4a7c15 +% (hash << 6) +% (hash >> 2);
    hash ^= @as(u64, variant.index) +% 0x9e3779b97f4a7c15 +% (hash << 6) +% (hash >> 2);
    return hash;
}

pub fn is_truthy(value: Value) bool {
    return switch (value) {
        .boolean => |b| b,
        else => false,
    };
}

pub fn is_falsy(value: Value) bool {
    return !is_truthy(value);
}

pub fn values_equal(a: Value, b: Value) bool {
    return switch (a) {
        .int => |a_int| switch (b) {
            .int => |b_int| a_int == b_int,
            else => false,
        },
        .float => |a_float| switch (b) {
            .float => |b_float| a_float == b_float,
            else => false,
        },
        .boolean => |a_bool| switch (b) {
            .boolean => |b_bool| a_bool == b_bool,
            else => false,
        },
        .nil => switch (b) {
            .nil => true,
            else => false,
        },
        .enum_ => |a_variant| switch (b) {
            .enum_ => |b_variant| a_variant.type_id == b_variant.type_id and a_variant.index == b_variant.index,
            else => false,
        },
        .error_ => |a_variant| switch (b) {
            .error_ => |b_variant| a_variant.type_id == b_variant.type_id and a_variant.index == b_variant.index,
            else => false,
        },
        .object => |a_obj| switch (b) {
            .object => |b_obj| switch (a_obj.object_type) {
                .ObjectString => switch (b_obj.object_type) {
                    .ObjectString => compare_strings(@ptrCast(a_obj), @ptrCast(b_obj)),
                    else => false,
                },
                else => a_obj == b_obj,
            },
            else => false,
        },
    };
}

pub fn object_from_value(value: Value) !*ObjectHeader {
    return switch (value) {
        .object => |obj| obj,
        else => error.InvalidValue,
    };
}

pub fn value_from_object(obj: *ObjectHeader) Value {
    return Value{ .object = obj };
}

pub fn print_value(value: Value) void {
    switch (value) {
        .int => |int| std.debug.print("{}", .{int}),
        .float => |float| std.debug.print("{}", .{float}),
        .boolean => |b| std.debug.print("{}", .{b}),
        .nil => std.debug.print("nil", .{}),
        .enum_ => |variant| std.debug.print("enum variant {}", .{variant.index}),
        .error_ => |variant| std.debug.print("error variant {}", .{variant.index}),
        .object => |obj| print_object(obj),
    }
}

pub fn object_as(comptime T: type, obj: *ObjectHeader) *T {
    return switch (obj.object_type) {
        .ObjectArray => @ptrCast(obj),
        .ObjectClosure => @ptrCast(obj),
        .ObjectCoroutine => @ptrCast(obj),
        .ObjectFunction => @ptrCast(obj),
        .ObjectString => @ptrCast(obj),
        .ObjectTable => @ptrCast(obj),
        .ObjectTuple => @ptrCast(obj),
        .ObjectUpvalue => @ptrCast(obj),
        .ObjectStructInstance => @ptrCast(obj),
        .ObjectRange => @ptrCast(obj),
    };
}

pub fn print_object(obj: *ObjectHeader) void {
    switch (obj.object_type) {
        .ObjectString => {
            const object = object_as(ObjectString, obj);
            std.debug.print("{s}", .{object.chars});
        },
        .ObjectArray => {
            const object = object_as(ObjectArray, obj);
            std.debug.print("[", .{});
            for (object.elements, 0..object.elements.len) |element, i| {
                print_value(element);
                if (i != object.elements.len - 1)
                    std.debug.print(", ", .{});
            }
            std.debug.print("]", .{});
        },
        .ObjectTuple => {
            const object = object_as(ObjectTuple, obj);
            std.debug.print("(", .{});
            for (object.elements, 0..object.elements.len) |element, i| {
                print_value(element);
                if (i != object.elements.len - 1)
                    std.debug.print(", ", .{});
            }
            std.debug.print(")", .{});
        },
        .ObjectTable => {
            const object = object_as(ObjectTable, obj);
            std.debug.print("{{", .{});
            var printed: usize = 0;
            for (object.entries) |entry| {
                if (entry.state != .occupied) continue;
                if (printed > 0) std.debug.print(", ", .{});
                print_value(entry.key);
                std.debug.print(": ", .{});
                print_value(entry.value);
                printed += 1;
            }
            std.debug.print("}}", .{});
        },
        .ObjectUpvalue => {
            const object = object_as(ObjectUpvalue, obj);
            std.debug.print("ObjectUpvalue: ", .{});
            print_value(object.closed_value);
        },
        .ObjectRange => {
            const object = object_as(ObjectRange, obj);
            std.debug.print("{d}..{d} step {d}", .{ object.start, object.end, object.step });
        },
        else => std.debug.print("{s}@{*}\n", .{ @tagName(obj.object_type), obj }),
    }
}

pub fn copy_string(isolate: *Isolate, chars: []const u8) !*ObjectString {
    const entry = isolate.string_intern.getEntry(chars);
    if (entry) |e| {
        return e.value_ptr.*;
    }

    return try new_string_object(isolate, chars);
}

/// Takes a string owned by allocator, and makes it a GC owned string
/// Will free `chars`
pub fn take_string(isolate: *Isolate, allocator: std.mem.Allocator, chars: []const u8) !*ObjectString {
    const entry = isolate.string_intern.getEntry(chars);
    if (entry) |e| {
        allocator.free(chars);
        return e.value_ptr.*;
    }
    defer allocator.free(chars);
    return try new_string_object(isolate, chars);
}

pub fn new_string_object(isolate: *Isolate, chars: []const u8) !*ObjectString {
    const string: *ObjectString = try isolate.gc.allocate_object(ObjectString, .ObjectString);

    string.chars = try isolate.gc.managed_allocator.allocator().dupe(u8, chars);
    string.hash = std.hash.Fnv1a_64.hash(chars);
    string.byte_length = chars.len;
    string.code_point_length = try std.unicode.utf8CountCodepoints(chars);

    try isolate.string_intern.put(string.chars, string);

    return string;
}

pub fn compare_strings(a: *ObjectString, b: *ObjectString) bool {
    if (a.byte_length != b.byte_length) {
        return false;
    }
    return std.mem.eql(u8, a.chars, b.chars);
}

pub fn new_array_object(isolate: *Isolate, element_count: usize) !*ObjectArray {
    const array: *ObjectArray = try isolate.gc.allocate_object(ObjectArray, .ObjectArray);
    array.capacity = element_count;
    array.length = 0;
    array.elements = try isolate.gc.managed_allocator.allocator().alloc(Value, element_count);
    for (array.elements) |*element| {
        element.* = .nil;
    }
    return array;
}

pub fn new_table_object(isolate: *Isolate) !*ObjectTable {
    const table: *ObjectTable = try isolate.gc.allocate_object(ObjectTable, .ObjectTable);
    table.entries = &.{};
    table.capacity = 0;
    table.length = 0;
    return table;
}

const tableMaxLoad = 0.75;

fn grow_table_capacity(capacity: usize) usize {
    if (capacity < 8) return 8;
    return capacity * 2;
}

fn init_table_entries(entries: []TableEntry) void {
    for (entries) |*entry| {
        entry.* = .{};
    }
}

fn find_table_entry(entries: []TableEntry, key: Value) !*TableEntry {
    const capacity = entries.len;
    var index: usize = @intCast((try hash_value(key)) & @as(u64, @intCast(capacity - 1)));
    var tombstone: ?*TableEntry = null;

    while (true) {
        const entry = &entries[index];

        switch (entry.state) {
            .empty => return tombstone orelse entry,
            .tombstone => {
                if (tombstone == null) tombstone = entry;
            },
            .occupied => {
                if (values_equal(entry.key, key)) return entry;
            },
        }

        index = (index + 1) & (capacity - 1);
    }
}

/// Grows the size of the table and moves elements to their new positions
fn adjustTableCapacity(isolate: *Isolate, table: *ObjectTable, capacity: usize) !void {
    const allocator = isolate.gc.managed_allocator.allocator();
    const entries = try allocator.alloc(TableEntry, capacity);
    init_table_entries(entries);

    table.length = 0;
    for (table.entries) |entry| {
        if (entry.state != .occupied) continue;

        const dest = try find_table_entry(entries, entry.key);
        dest.* = .{
            .key = entry.key,
            .value = entry.value,
            .state = .occupied,
        };
        table.length += 1;
    }

    if (table.entries.len > 0) allocator.free(table.entries);
    table.entries = entries;
    table.capacity = capacity;
}

pub fn table_set(isolate: *Isolate, table: *ObjectTable, key: Value, value: Value) !bool {
    if (@as(f64, @floatFromInt(table.length + 1)) > @as(f64, @floatFromInt(table.capacity)) * tableMaxLoad) {
        try adjustTableCapacity(isolate, table, grow_table_capacity(table.capacity));
    }

    const entry = try find_table_entry(table.entries, key);
    const is_new_key = entry.state != .occupied;

    if (is_new_key) {
        table.length += 1;
    }

    entry.* = .{
        .key = key,
        .value = value,
        .state = .occupied,
    };
    return is_new_key;
}

pub fn table_get(table: *const ObjectTable, key: Value) !?Value {
    if (table.length == 0) return null;

    const entry = try find_table_entry(table.entries, key);
    if (entry.state != .occupied) return null;
    return entry.value;
}

pub fn table_delete(table: *ObjectTable, key: Value) !bool {
    if (table.length == 0) return false;

    const entry = try find_table_entry(table.entries, key);
    if (entry.state != .occupied) return false;

    entry.* = .{
        .key = .nil,
        .value = .{ .boolean = true },
        .state = .tombstone,
    };
    return true;
}

pub fn table_add_all(isolate: *Isolate, from: *const ObjectTable, to: *ObjectTable) !void {
    for (from.entries) |entry| {
        if (entry.state == .occupied) {
            _ = try table_set(isolate, to, entry.key, entry.value);
        }
    }
}

pub fn new_tuple_object(isolate: *Isolate, length: usize) !*ObjectTuple {
    const tuple: *ObjectTuple = try isolate.gc.allocate_object(ObjectTuple, .ObjectTuple);
    tuple.elements = try isolate.gc.managed_allocator.allocator().alloc(Value, length);
    for (tuple.elements) |*element| {
        element.* = .nil;
    }
    return tuple;
}

pub fn new_function_object(isolate: *Isolate, file_path: []const u8) !*ObjectFunction {
    const func: *ObjectFunction = try isolate.gc.allocate_object(ObjectFunction, .ObjectFunction);
    func.chunk = Chunk.init(isolate.gc.managed_allocator.allocator());
    func.chunk.file_path = file_path;
    func.upvalue_count = 0;
    func.arity = 0;
    func.name = null;
    return func;
}

pub fn new_closure_object(isolate: *Isolate, function: *ObjectFunction) !*ObjectClosure {
    const closure: *ObjectClosure = try isolate.gc.allocate_object(ObjectClosure, .ObjectClosure);
    closure.function = function;
    closure.upvalues = &.{}; // upvalues will be allocated later
    return closure;
}

pub fn new_upvalue_object(isolate: *Isolate, location: *Value) !*ObjectUpvalue {
    const upvalue: *ObjectUpvalue = try isolate.gc.allocate_object(ObjectUpvalue, .ObjectUpvalue);
    upvalue.location = location;
    upvalue.closed_value = .nil;
    upvalue.closed = false;
    upvalue.next = null;
    return upvalue;
}

pub fn new_coroutine_object(isolate: *Isolate, closure: *ObjectClosure, frame_capacity: usize, stack_size: usize) !*ObjectCoroutine {
    const coroutine: *ObjectCoroutine = try isolate.gc.allocate_object(ObjectCoroutine, .ObjectCoroutine);
    coroutine.closure = closure;
    coroutine.state = .SUSPENDED;
    coroutine.started = false;
    coroutine.execution_state = try ExecutionState.init(isolate.gc.managed_allocator.allocator(), frame_capacity, stack_size);

    return coroutine;
}

pub fn new_range_object(isolate: *Isolate, start: i64, end: i64, step: i64) !*ObjectRange {
    const range: *ObjectRange = try isolate.gc.allocate_object(ObjectRange, .ObjectRange);
    range.start = start;
    range.end = end;
    range.step = step;

    return range;
}

pub fn mark_value(garbage_collector: *basic_gc, value: Value) !void {
    switch (value) {
        .object => |obj| {
            try mark_object(garbage_collector, obj);
        },
        else => {},
    }
}

pub fn blacken_object(garbage_collector: *basic_gc, obj: *ObjectHeader) !void {
    switch (obj.object_type) {
        .ObjectFunction => {
            const func: *ObjectFunction = @ptrCast(obj);
            if (func.name) |name| {
                try mark_object(garbage_collector, @ptrCast(name));
            }
            for (func.chunk.constants.items) |constant| {
                try mark_value(garbage_collector, constant);
            }
        },
        .ObjectClosure => {
            const closure: *ObjectClosure = @ptrCast(obj);
            try mark_object(garbage_collector, @ptrCast(closure.function));
            for (closure.upvalues) |upvalue| {
                try mark_object(garbage_collector, @ptrCast(upvalue));
            }
        },
        .ObjectCoroutine => {
            const coroutine: *ObjectCoroutine = @ptrCast(obj);
            try mark_object(garbage_collector, @ptrCast(coroutine.closure));
            try coroutine.execution_state.mark_execution_state(garbage_collector);
            switch (coroutine.state) {
                .FINISHED => |ret_val| try mark_value(garbage_collector, ret_val),
                .SUSPENDED, .RUNNING => {},
            }
        },
        .ObjectString => {},
        .ObjectTuple => {
            const tuple: *ObjectTuple = @ptrCast(obj);
            for (tuple.elements) |value| {
                try mark_value(garbage_collector, value);
            }
        },
        .ObjectTable => {
            const table: *ObjectTable = @ptrCast(obj);
            for (table.entries) |entry| {
                if (entry.state != .occupied) continue;
                try mark_value(garbage_collector, entry.key);
                try mark_value(garbage_collector, entry.value);
            }
        },
        .ObjectArray => {
            const array: *ObjectArray = @ptrCast(obj);
            for (array.elements) |value| {
                try mark_value(garbage_collector, value);
            }
        },
        .ObjectUpvalue => {
            const up: *ObjectUpvalue = @ptrCast(obj);
            try mark_value(garbage_collector, up.closed_value);
            try mark_value(garbage_collector, up.location.*);
            if (up.next) |next| {
                try mark_object(garbage_collector, @ptrCast(next));
            }
        },
        .ObjectStructInstance => {
            const struct_instance: *ObjectStructInstance = @ptrCast(obj);
            for (struct_instance.fields) |field| {
                try mark_value(garbage_collector, field);
            }
        },
        .ObjectRange => {},
    }
}

pub fn free_object(allocator: std.mem.Allocator, obj: *ObjectHeader) void {
    switch (obj.object_type) {
        .ObjectFunction => {
            const func: *ObjectFunction = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectFunction {*}\n", .{obj});
            }
            func.chunk.deinit();
            allocator.destroy(func);
        },
        .ObjectArray => {
            const array: *ObjectArray = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectArray {*}\n", .{obj});
            }
            allocator.free(array.elements);
            allocator.destroy(array);
        },
        .ObjectTuple => {
            const tuple: *ObjectTuple = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectTuple {*}\n", .{obj});
            }
            allocator.free(tuple.elements);
            allocator.destroy(tuple);
        },
        .ObjectTable => {
            const table: *ObjectTable = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectTable {*}\n", .{obj});
            }
            if (table.entries.len > 0) allocator.free(table.entries);
            allocator.destroy(table);
        },
        .ObjectString => {
            const str: *ObjectString = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectString {*}\n", .{obj});
            }
            allocator.free(str.chars);
            allocator.destroy(str);
        },
        .ObjectUpvalue => {
            const up: *ObjectUpvalue = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectUpvalue {*}\n", .{obj});
            }
            allocator.destroy(up);
        },
        .ObjectClosure => {
            const closure: *ObjectClosure = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectClosure {*}\n", .{obj});
            }
            if (closure.upvalues.len > 0) allocator.free(closure.upvalues);
            allocator.destroy(closure);
        },
        .ObjectCoroutine => {
            const coroutine: *ObjectCoroutine = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectCoroutine  {*}\n", .{obj});
            }
            coroutine.execution_state.deinit(allocator);
            allocator.destroy(coroutine);
        },
        .ObjectStructInstance => {
            const struct_instance: *ObjectStructInstance = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectStructInstance {*}\n", .{obj});
            }
            allocator.free(struct_instance.fields);
            allocator.destroy(struct_instance);
        },
        .ObjectRange => {
            const range: *ObjectRange = @ptrCast(obj);
            if (options.log_gc) {
                std.debug.print("freed: ObjectRange: {*}\n", .{obj});
            }
            allocator.destroy(range);
        },
    }
}
