//! Entity Representation for TAPE
//! Entities are Values and Objects.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const Isolate = @import("vm.zig").Isolate;
const BasicGarbageCollector = @import("../memory/basic_garbage_collector.zig");
const basic_gc = BasicGarbageCollector.BasicGarbageCollector;
const mark_object = basic_gc.mark_object;

pub const CallFrame = struct {
    closure: *ObjectClosure,
    ip: usize,
    slot_start: usize,

    pub fn read_u8(frame: *CallFrame) u8 {
        frame.ip += 1;
        return frame.closure.function.chunk.code.items[frame.ip - 1];
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

pub const ObjectTable = struct {
    header: ObjectHeader,
    keys: []Value,
    values: []Value,
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
    location: *Value,
    closed_value: Value,
};

pub const ObjectCoroutine = struct {
    header: ObjectHeader,
    function: *ObjectFunction,
    upvalues: []*ObjectUpvalue,
};

pub const Value = union(enum) {
    int: i64,
    float: f64,
    boolean: bool,
    nil: void,
    object: *ObjectHeader,
};

pub fn is_truthy(value: Value) bool {
    return switch (value) {
        .boolean => |b| b,
        else => false,
    };
}

pub fn is_falsy(value: Value) bool {
    return !is_truthy(value);
}

pub fn equals(a: Value, b: Value) bool {
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
        .object => |a_obj| switch (b) {
            .object => |b_obj| a_obj == b_obj,
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
        .object => |a_obj| switch (b) {
            .object => |b_obj| a_obj == b_obj,
            else => false,
        },
    };
}

pub fn print_value(value: Value) void {
    switch (value) {
        .int => |int| std.debug.print("{}", .{int}),
        .float => |float| std.debug.print("{}", .{float}),
        .boolean => |b| std.debug.print("{}", .{b}),
        .nil => std.debug.print("nil", .{}),
        .object => |obj| print_object(obj),
    }
}

pub fn as(comptime T: type, obj: *ObjectHeader) *T {
    return @ptrCast(obj);
}

pub fn print_object(obj: *ObjectHeader) void {
    std.debug.print("{s}@{*}\n", .{ @tagName(obj.object_type), obj });
}

pub fn new_string_object(isolate: *Isolate, chars: []const u8) !*ObjectString {
    const string: *ObjectString = try isolate.gc.allocate_object(ObjectString, .ObjectString);
    string.hash = std.hash.Fnv1a_64.hash(chars);
    string.chars = chars;
    // TODO: fix byte_length and code_point_length calculations for UTF-8
    string.byte_length = chars.len;
    string.code_point_length = chars.len;
    return string;
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
    table.capacity = 0;
    table.length = 0;
    table.keys = try isolate.gc.managed_allocator.allocator().alloc(Value, 0);
    table.values = try isolate.gc.managed_allocator.allocator().alloc(Value, 0);
    return table;
}

pub fn new_tuple_object(isolate: *Isolate, length: usize) !*ObjectTuple {
    const tuple: *ObjectTuple = try isolate.gc.allocate_object(ObjectTuple, .ObjectTuple);
    tuple.elements = try isolate.gc.managed_allocator.allocator().alloc(Value, length);
    for (tuple.elements) |*element| {
        element.* = .nil;
    }
    return tuple;
}

pub fn new_function_object(isolate: *Isolate) !*ObjectFunction {
    const func: *ObjectFunction = try isolate.gc.allocate_object(ObjectFunction, .ObjectFunction);
    func.chunk = Chunk.init(isolate.gc.managed_allocator.allocator());
    func.upvalue_count = 0;
    func.arity = 0;
    func.name = null;
    return func;
}

pub fn new_closure_object(isolate: *Isolate, function: *ObjectFunction) !*ObjectClosure {
    const closure: *ObjectClosure = try isolate.gc.allocate_object(ObjectClosure, .ObjectClosure);
    closure.function = function;
    closure.upvalues = try isolate.gc.managed_allocator.allocator().alloc(*ObjectUpvalue, function.upvalue_count);
    for (closure.upvalues) |*upvalue| {
        upvalue.* = undefined;
    }
    return closure;
}

pub fn new_upvalue_object(isolate: *Isolate, location: *Value) !*ObjectUpvalue {
    const upvalue: *ObjectUpvalue = try isolate.gc.allocate_object(ObjectUpvalue, .ObjectUpvalue);
    upvalue.location = location;
    upvalue.closed_value = .nil;
    return upvalue;
}

pub fn new_coroutine_object(isolate: *Isolate, function: *ObjectFunction) !*ObjectCoroutine {
    const coroutine: *ObjectCoroutine = try isolate.gc.allocate_object(ObjectCoroutine, .ObjectCoroutine);
    coroutine.function = function;
    coroutine.upvalues = try isolate.gc.managed_allocator.allocator().alloc(*ObjectUpvalue, function.upvalue_count);
    for (coroutine.upvalues) |*upvalue| {
        upvalue.* = undefined;
    }
    return coroutine;
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
            try mark_object(garbage_collector, @ptrCast(coroutine.function));
            for (coroutine.upvalues) |upvalue| {
                try mark_object(garbage_collector, @ptrCast(upvalue));
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
            for (table.keys) |key| {
                try mark_value(garbage_collector, key);
            }
            for (table.values) |value| {
                try mark_value(garbage_collector, value);
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
        },
    }
}

pub fn get_size_of_object(obj: *ObjectHeader) usize {
    return switch (obj.object_type) {
        .ObjectFunction => @sizeOf(ObjectFunction),
        .ObjectArray => @sizeOf(ObjectArray),
        .ObjectTuple => @sizeOf(ObjectTuple),
        .ObjectTable => @sizeOf(ObjectTable),
        .ObjectString => @sizeOf(ObjectString),
        .ObjectUpvalue => @sizeOf(ObjectUpvalue),
        .ObjectClosure => @sizeOf(ObjectClosure),
        .ObjectCoroutine => @sizeOf(ObjectCoroutine),
    };
}

pub fn free_object(allocator: std.mem.Allocator, obj: *ObjectHeader) void {
    switch (obj.object_type) {
        .ObjectFunction => {
            const func: *ObjectFunction = @ptrCast(obj);
            func.chunk.deinit();
            allocator.destroy(func);
        },
        .ObjectArray => {
            const array: *ObjectArray = @ptrCast(obj);
            allocator.free(array.elements);
            allocator.destroy(array);
        },
        .ObjectTuple => {
            const tuple: *ObjectTuple = @ptrCast(obj);
            allocator.free(tuple.elements);
            allocator.destroy(tuple);
        },
        .ObjectTable => {
            const table: *ObjectTable = @ptrCast(obj);
            allocator.free(table.keys);
            allocator.free(table.values);
            allocator.destroy(table);
        },
        .ObjectString => {
            const str: *ObjectString = @ptrCast(obj);
            allocator.free(str.chars);
            allocator.destroy(str);
        },
        .ObjectUpvalue => {
            const up: *ObjectUpvalue = @ptrCast(obj);
            allocator.destroy(up);
        },
        .ObjectClosure => {
            const closure: *ObjectClosure = @ptrCast(obj);
            allocator.free(closure.upvalues);
            allocator.destroy(closure);
        },
        .ObjectCoroutine => {
            const coroutine: *ObjectCoroutine = @ptrCast(obj);
            allocator.free(coroutine.upvalues);
            allocator.destroy(coroutine);
        },
    }
}
