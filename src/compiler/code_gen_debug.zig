const std = @import("std");
const Chunk = @import("../runtime/chunk.zig").Chunk;
const Opcode = @import("../runtime/chunk.zig").Opcode;
const Entities = @import("../runtime/entities.zig");
const Value = Entities.Value;

const JumpDirection = enum { FORWARD, BACKWARD };

fn print_value_for_disassembly(value: Value) void {
    switch (value) {
        .int => |int| std.debug.print("{}", .{int}),
        .float => |float| std.debug.print("{}", .{float}),
        .boolean => |b| std.debug.print("{}", .{b}),
        .nil => std.debug.print("nil", .{}),
        .enum_ => |variant| std.debug.print("enum variant {}", .{variant.index}),
        .error_ => |variant| std.debug.print("error variant {}", .{variant.index}),
        .object => |obj| std.debug.print("{s}", .{@tagName(obj.object_type)}),
    }
}

pub const ChunkDisassembler = struct {
    pub fn disassemble(chunk: *Chunk, name: []const u8) void {
        std.debug.print("======= {s} =======\n", .{name});
        var offset: usize = 0;
        while (offset < chunk.code.items.len) {
            offset = disassemble_chunk(chunk, offset);
        }
    }

    fn read_u16(chunk: *Chunk, offset: usize) u16 {
        const code = chunk.code.items;
        const high: u16 = code[offset];
        const low: u16 = code[offset + 1];
        return (high << 8) | low;
    }

    fn read_u32(chunk: *Chunk, offset: usize) u32 {
        const high: u32 = read_u16(chunk, offset);
        const low: u32 = read_u16(chunk, offset + 2);
        return (high << 16) | low;
    }

    fn disassemble_simple_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        std.debug.print("{s}\n", .{@tagName(opcode)});
        return offset + 1;
    }

    fn disassemble_constant_instruction(chunk: *Chunk, offset: usize) usize {
        const index = read_u16(chunk, offset + 1);
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const value = chunk.constants.items[index];
        std.debug.print("{s}  ", .{@tagName(opcode)});
        print_value_for_disassembly(value);
        std.debug.print("\n", .{});
        return offset + 3;
    }

    fn disassemble_call_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const param_count = read_u16(chunk, offset + 1);
        std.debug.print("{s} - {d} param(s)\n", .{ @tagName(opcode), param_count });
        return offset + 1 + 2; // +1 for opcode +2 for u16 param_count
    }

    fn disassemble_jump_instruction(chunk: *Chunk, offset: usize, direction: JumpDirection) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const jump_amount = read_u16(chunk, offset + 1);
        std.debug.print("{s}  {s} {}\n", .{ @tagName(opcode), @tagName(direction), jump_amount });
        return offset + 3;
    }

    fn disassemble_closure_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const index = read_u16(chunk, offset + 1);
        std.debug.print("{s}  {d}", .{ @tagName(opcode), index });
        if (index < chunk.constants.items.len) {
            const value = chunk.constants.items[index];
            switch (value) {
                .object => |obj| switch (obj.object_type) {
                    .ObjectFunction => {
                        const func: *Entities.ObjectFunction = @ptrCast(obj);
                        std.debug.print(" (upvalues: {d})", .{func.upvalue_count});
                        for (0..func.upvalue_count) |i| {
                            const is_local = chunk.code.items[offset + 3 + i * 3];
                            const slot = read_u16(chunk, offset + 4 + i * 3);
                            std.debug.print(" [{d}: {s} {d}]", .{ i, if (is_local != 0) "local" else "upvalue", slot });
                        }
                        if (func.upvalue_count > 0) std.debug.print("\n", .{});
                        return offset + 3 + func.upvalue_count * 3;
                    },
                    else => {},
                },
                else => {},
            }
        }
        std.debug.print("\n", .{});
        return offset + 3;
    }

    fn disassemble_load_store_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const index = read_u16(chunk, offset + 1);
        std.debug.print("{s}  {}\n", .{ @tagName(opcode), index });
        return offset + 3;
    }

    fn disassemble_object_inline_arg_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const arg_count = read_u16(chunk, offset + 1);
        std.debug.print("{s}  {} args\n", .{ @tagName(opcode), arg_count });
        return offset + 3;
    }

    fn disassemble_struct_instruction(chunk: *Chunk, offset: usize) usize {
        // opcode, typeid, field_count
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const type_id = read_u32(chunk, offset + 1);
        const arg_count = read_u16(chunk, offset + 5);
        std.debug.print("{s} - type_id: {d} - {} args\n", .{ @tagName(opcode), type_id, arg_count });
        return offset + 7;
    }

    fn disassemble_for_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const slot = read_u16(chunk, offset + 1);
        // this may be the loop offset or the exit offset
        const jump_offset = read_u16(chunk, offset + 3);
        std.debug.print("{s} - variable slot: {d} - offset: {d}", .{ @tagName(opcode), slot, jump_offset });
        return offset + 5;
    }

    pub fn disassemble_chunk(chunk: *Chunk, offset: usize) usize {
        std.debug.print("{:4}  ", .{offset});

        if (offset > 0 and chunk.line_numbers.items[offset] == chunk.line_numbers.items[offset - 1]) {
            std.debug.print("  |  ", .{});
        } else {
            std.debug.print("{:3}  ", .{chunk.line_numbers.items[offset]});
        }

        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);

        switch (opcode) {
            .OP_ADD_FLOAT,
            .OP_SUB_FLOAT,
            .OP_MUL_FLOAT,
            .OP_DIV_FLOAT,
            .OP_ADD_INT_FLOAT,
            .OP_SUB_INT_FLOAT,
            .OP_MUL_INT_FLOAT,
            .OP_DIV_INT_FLOAT,
            .OP_ADD_FLOAT_INT,
            .OP_SUB_FLOAT_INT,
            .OP_MUL_FLOAT_INT,
            .OP_DIV_FLOAT_INT,
            .OP_ADD_INT,
            .OP_SUB_INT,
            .OP_MUL_INT,
            .OP_DIV_INT,
            .OP_RETURN,
            .OP_NIL,
            .OP_TRUE,
            .OP_FALSE,
            .OP_GREATER_INT,
            .OP_LESS_INT,
            .OP_GREATER_EQUAL_INT,
            .OP_LESS_EQUAL_INT,
            .OP_GREATER_FLOAT,
            .OP_LESS_FLOAT,
            .OP_GREATER_EQUAL_FLOAT,
            .OP_LESS_EQUAL_FLOAT,
            .OP_GREATER_INT_FLOAT,
            .OP_LESS_INT_FLOAT,
            .OP_GREATER_EQUAL_INT_FLOAT,
            .OP_LESS_EQUAL_INT_FLOAT,
            .OP_GREATER_FLOAT_INT,
            .OP_LESS_FLOAT_INT,
            .OP_GREATER_EQUAL_FLOAT_INT,
            .OP_LESS_EQUAL_FLOAT_INT,
            .OP_POP,
            .OP_EQUAL,
            .OP_NEGATE_INT,
            .OP_NEGATE_FLOAT,
            .OP_LOGICAL_NOT,
            .OP_NOT_EQUAL,
            .OP_BITWISE_NOT,
            .OP_BITWISE_AND,
            .OP_BITWISE_OR,
            .OP_BITWISE_XOR,
            .OP_LEFT_SHIFT,
            .OP_RIGHT_SHIFT,
            .OP_EXPONENT_INT,
            .OP_EXPONENT_FLOAT,
            .OP_EXPONENT_INT_FLOAT,
            .OP_EXPONENT_FLOAT_INT,
            .OP_MOD_INT,
            .OP_MOD_FLOAT,
            .OP_MOD_INT_FLOAT,
            .OP_MOD_FLOAT_INT,
            .OP_STRING_CONCAT,
            .OP_INDEX_ARRAY,
            .OP_INDEX_STRING,
            .OP_INDEX_TABLE,
            .OP_RESUME,
            .OP_YIELD,
            .OP_DUP,
            .OP_PANIC,
            .OP_RANGE,
            => {
                return disassemble_simple_instruction(chunk, offset);
            },

            .OP_CALL,
            .OP_COROUTINE,
            => {
                return disassemble_call_instruction(chunk, offset);
            },
            .OP_LOAD_GLOBAL,
            .OP_STORE_GLOBAL,
            .OP_STORE_LOCAL,
            .OP_LOAD_LOCAL,
            .OP_POP_N,
            .OP_INDEX_TUPLE,
            .OP_LOAD_FUNCTION_CONSTANT,
            .OP_LOAD_UPVALUE,
            .OP_STORE_UPVALUE,
            .OP_GET_FIELD,
            .OP_SET_FIELD,
            => {
                return disassemble_load_store_instruction(chunk, offset);
            },

            .OP_JUMP,
            .OP_JUMP_IF_FALSE,
            .OP_JUMP_IF_NIL,
            .OP_JUMP_IF_ERROR,
            => return disassemble_jump_instruction(chunk, offset, .FORWARD),
            .OP_LOOP,
            => return disassemble_jump_instruction(chunk, offset, .BACKWARD),

            .OP_CONSTANT => {
                return disassemble_constant_instruction(chunk, offset);
            },

            .OP_CLOSURE => {
                return disassemble_closure_instruction(chunk, offset);
            },

            .OP_ARRAY, .OP_TABLE, .OP_TUPLE => {
                return disassemble_object_inline_arg_instruction(chunk, offset);
            },

            .OP_STRUCT => {
                return disassemble_struct_instruction(chunk, offset);
            },
            .OP_FOR_PREP,
            .OP_FOR_NEXT,
            => {
                return disassemble_for_instruction(chunk, offset);
            },
        }
    }
};
