const std = @import("std");
const Chunk = @import("../../runtime/chunk.zig").Chunk;
const Opcode = @import("../../runtime/chunk.zig").Opcode;

test "Can initialize" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
}

test "Can write opcode" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    try chunk.write_opcode(Opcode.OP_JUMP, 0);
    const code = chunk.code.items;
    std.debug.assert(code[0] == @backingInt(Opcode.OP_JUMP));
}

test "Can write constant" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    _ = try chunk.write_constant(.{ .int = 42 });
    const constants = chunk.constants.items;
    std.debug.assert(constants[0].int == 42);
}

test "Can emit constants" {
    const allocator = std.testing.allocator;
    var chunk = Chunk.init(allocator);
    defer chunk.deinit();
    try chunk.emit_constant(.{ .int = 42 }, 0);
    const code = chunk.code.items;
    std.debug.assert(code[0] == @backingInt(Opcode.OP_CONSTANT));
    const constants = chunk.constants.items;
    std.debug.assert(constants[0].int == 42);
}
