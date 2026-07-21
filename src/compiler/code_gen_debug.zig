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
        std.debug.print("{s}\n", .{@tagName(opcode)});
        return offset + 1;
    }

    fn disassemble_jump_instruction(chunk: *Chunk, offset: usize, direction: JumpDirection) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const jump_amount = read_u16(chunk, offset + 1);
        std.debug.print("{s}  {s} {}\n", .{ @tagName(opcode), @tagName(direction), jump_amount });
        return offset + 3;
    }

    fn disassemble_closure_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        std.debug.print("{s}\n", .{@tagName(opcode)});
        return offset + 1;
    }

    fn disassemble_load_store_instruction(chunk: *Chunk, offset: usize) usize {
        const opcode: Opcode = @enumFromInt(chunk.code.items[offset]);
        const index = read_u16(chunk, offset + 1);
        std.debug.print("{s}  {}\n", .{ @tagName(opcode), index });
        return offset + 3;
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
            => {
                return disassemble_simple_instruction(chunk, offset);
            },

            .OP_CALL => {
                return disassemble_call_instruction(chunk, offset);
            },
            .OP_LOAD_GLOBAL,
            .OP_STORE_GLOBAL,
            .OP_STORE_LOCAL,
            .OP_LOAD_LOCAL,
            => {
                return disassemble_load_store_instruction(chunk, offset);
            },

            .OP_JUMP,
            .OP_JUMP_IF_FALSE,
            .OP_JUMP_IF_NIL,
            => return disassemble_jump_instruction(chunk, offset, .FORWARD),
            .OP_LOOP,
            => return disassemble_jump_instruction(chunk, offset, .BACKWARD),

            .OP_CONSTANT => {
                return disassemble_constant_instruction(chunk, offset);
            },

            .OP_CLOSURE => {
                return disassemble_closure_instruction(chunk, offset);
            },
        }
    }
};
