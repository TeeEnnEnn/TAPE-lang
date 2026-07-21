const std = @import("std");
const Entities = @import("entities.zig");

/// Instructions for the virtual machine
pub const Opcode = enum(u8) {
    OP_RETURN,
    OP_CONSTANT,
    OP_NIL,
    OP_TRUE,
    OP_FALSE,
    OP_NEGATE_INT,
    OP_NEGATE_FLOAT,
    OP_LOGICAL_NOT,
    OP_EQUAL,
    OP_NOT_EQUAL,

    OP_BITWISE_NOT,
    OP_BITWISE_AND,
    OP_BITWISE_OR,
    OP_BITWISE_XOR,
    OP_LEFT_SHIFT,
    OP_RIGHT_SHIFT,

    OP_GREATER_INT,
    OP_LESS_INT,
    OP_GREATER_EQUAL_INT,
    OP_LESS_EQUAL_INT,

    OP_GREATER_FLOAT,
    OP_LESS_FLOAT,
    OP_GREATER_EQUAL_FLOAT,
    OP_LESS_EQUAL_FLOAT,

    OP_GREATER_INT_FLOAT,
    OP_LESS_INT_FLOAT,
    OP_GREATER_EQUAL_INT_FLOAT,
    OP_LESS_EQUAL_INT_FLOAT,

    OP_GREATER_FLOAT_INT,
    OP_LESS_FLOAT_INT,
    OP_GREATER_EQUAL_FLOAT_INT,
    OP_LESS_EQUAL_FLOAT_INT,

    OP_ADD_INT,
    OP_SUB_INT,
    OP_MUL_INT,
    OP_DIV_INT,

    OP_ADD_FLOAT,
    OP_SUB_FLOAT,
    OP_MUL_FLOAT,
    OP_DIV_FLOAT,

    OP_ADD_INT_FLOAT,
    OP_ADD_FLOAT_INT,
    OP_SUB_INT_FLOAT,
    OP_SUB_FLOAT_INT,
    OP_MUL_INT_FLOAT,
    OP_MUL_FLOAT_INT,
    OP_DIV_INT_FLOAT,
    OP_DIV_FLOAT_INT,

    OP_EXPONENT_INT,
    OP_EXPONENT_FLOAT,
    OP_EXPONENT_INT_FLOAT,
    OP_EXPONENT_FLOAT_INT,

    OP_MOD_INT,
    OP_MOD_FLOAT,
    OP_MOD_INT_FLOAT,
    OP_MOD_FLOAT_INT,

    OP_POP,
    OP_LOAD_GLOBAL,
    OP_STORE_GLOBAL,
    OP_STORE_LOCAL,
    OP_LOAD_LOCAL,
    OP_JUMP,
    OP_JUMP_IF_FALSE,
    OP_JUMP_IF_NIL,
    OP_LOOP,
    OP_CALL,

    OP_CLOSURE,
};

/// A chunk of bytecode
pub const Chunk = struct {
    allocator: std.mem.Allocator,
    /// Constants used in the chunk.
    constants: std.ArrayList(Entities.Value),
    /// Bytes used in the chunk (opcodes and operands).
    code: std.ArrayList(u8),
    /// Line numbers corresponding to each opcode.
    line_numbers: std.ArrayList(usize),

    /// Initializes a new chunk with the given allocator.
    pub fn init(allocator: std.mem.Allocator) Chunk {
        return Chunk{
            .allocator = allocator,
            .constants = .empty,
            .code = .empty,
            .line_numbers = .empty,
        };
    }

    /// Deinitializes the chunk and frees all allocated memory.
    pub fn deinit(self: *Chunk) void {
        self.constants.deinit(self.allocator);
        self.code.deinit(self.allocator);
        self.line_numbers.deinit(self.allocator);
    }

    pub fn write_u8(self: *Chunk, value: u8, line: usize) !void {
        try self.code.append(self.allocator, @intCast(value));
        try self.line_numbers.append(self.allocator, line);
    }

    /// Writes a 16-bit value to the chunk.
    pub fn write_u16(self: *Chunk, value: u16, line: usize) !void {
        try self.write_u8(@as(u8, @truncate(value >> 8)), line);
        try self.write_u8(@as(u8, @truncate(value)), line);
    }

    /// Writes an opcode to the chunk.
    pub fn write_opcode(self: *Chunk, opcode: Opcode, line: usize) !void {
        try self.write_u8(@intFromEnum(opcode), line);
    }

    pub fn write_constant(self: *Chunk, value: Entities.Value) !u16 {
        try self.constants.append(self.allocator, value);
        return @intCast(self.constants.items.len - 1);
    }

    pub fn emit_constant(self: *Chunk, value: Entities.Value, line: usize) !void {
        const index = try self.write_constant(value);
        try self.write_opcode(.OP_CONSTANT, line);
        try self.write_u16(index, line);
    }
};
