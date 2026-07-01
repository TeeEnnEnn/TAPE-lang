//! Entity Representation for TAPE
//! Entities are Values and Objects.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;

pub const ObjectType = enum {
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
    name: *ObjectString,
    chunk: Chunk,
    upvalue_count: usize,
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
    // TODO: move this to vm print
    switch (value) {
        .int => |int| std.debug.print("{}\n", .{int}),
        .float => |float| std.debug.print("{}\n", .{float}),
        .boolean => |b| std.debug.print("{}\n", .{b}),
        .nil => std.debug.print("nil\n", .{}),
        .object => |obj| print_object(obj),
    }
}

pub fn print_object(obj: *ObjectHeader) void {
    // TODO: Add vm print
    // TODO: implement
    switch (obj.object_type) {}
}

pub fn allocate_object(allocator: std.mem.Allocator, object_type: ObjectType) !*ObjectHeader {
    const obj: *ObjectHeader = switch (object_type) {
        .ObjectString => @ptrCast(try allocator.create(ObjectString)),
        .ObjectArray => @ptrCast(try allocator.create(ObjectArray)),
        .ObjectTable => @ptrCast(try allocator.create(ObjectTable)),
        .ObjectTuple => @ptrCast(try allocator.create(ObjectTuple)),
        .ObjectFunction => @ptrCast(try allocator.create(ObjectFunction)),
        .ObjectClosure => @ptrCast(try allocator.create(ObjectClosure)),
        .ObjectCoroutine => @ptrCast(try allocator.create(ObjectCoroutine)),
        .ObjectUpvalue => @ptrCast(try allocator.create(ObjectUpvalue)),
    };
    obj.object_type = object_type;
    obj.marked = false;
    return obj;
}

pub fn new_string_object(allocator: std.mem.Allocator, chars: []const u8) !*ObjectString {
    const string: *ObjectString = @ptrCast(try allocate_object(allocator, .ObjectString));
    string.hash = std.hash.Fnv1a_64.hash(chars);
    string.chars = chars;
    // TODO: fix byte_length and code_point_length calculations
    string.byte_length = chars.len;
    string.code_point_length = chars.len;
    return string;
}

pub fn new_array_object(allocator: std.mem.Allocator, element_count: usize) !*ObjectArray {
    const array: *ObjectArray = @ptrCast(try allocate_object(allocator, .ObjectArray));
    array.capacity = element_count;
    array.length = 0;
    array.elements = try allocator.alloc(Value, element_count);
    for (array.elements) |*element| {
        element.* = .nil;
    }
    return array;
}

pub fn new_table_object(allocator: std.mem.Allocator) !*ObjectTable {
    const table: *ObjectTable = @ptrCast(try allocate_object(allocator, .ObjectTable));
    table.capacity = 0;
    table.length = 0;
    table.keys = try allocator.alloc(Value, 0);
    table.values = try allocator.alloc(Value, 0);
    return table;
}

pub fn new_tuple_object(allocator: std.mem.Allocator, length: usize) !*ObjectTuple {
    const tuple: *ObjectTuple = @ptrCast(try allocate_object(allocator, .ObjectTuple));
    tuple.elements = try allocator.alloc(Value, length);
    for (tuple.elements) |*element| {
        element.* = .nil;
    }
    return tuple;
}

pub fn new_function_object(allocator: std.mem.Allocator) !*ObjectFunction {
    const func: *ObjectFunction = @ptrCast(try allocate_object(allocator, .ObjectFunction));
    func.chunk = Chunk.init(allocator);
    func.upvalue_count = 0;
    func.name = undefined;
    return func;
}

pub fn new_closure_object(allocator: std.mem.Allocator, function: *ObjectFunction) !*ObjectClosure {
    const closure: *ObjectClosure = @ptrCast(try allocate_object(allocator, .ObjectClosure));
    closure.function = function;
    closure.upvalues = try allocator.alloc(*ObjectUpvalue, function.upvalue_count);
    for (closure.upvalues) |*upvalue| {
        upvalue.* = undefined;
    }
    return closure;
}

pub fn new_upvalue_object(allocator: std.mem.Allocator, location: *Value) !*ObjectUpvalue {
    const upvalue: *ObjectUpvalue = @ptrCast(try allocate_object(allocator, .ObjectUpvalue));
    upvalue.location = location;
    upvalue.closed_value = .nil;
    return upvalue;
}

pub fn new_coroutine_object(allocator: std.mem.Allocator, function: *ObjectFunction) !*ObjectCoroutine {
    const coroutine: *ObjectCoroutine = @ptrCast(try allocate_object(allocator, .ObjectCoroutine));
    coroutine.function = function;
    coroutine.upvalues = try allocator.alloc(*ObjectUpvalue, function.upvalue_count);
    for (coroutine.upvalues) |*upvalue| {
        upvalue.* = undefined;
    }
    return coroutine;
}
