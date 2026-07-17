const std = @import("std");
const Parser = @import("../../compiler/parser.zig").Parser;
const TypeRegistry = @import("../../compiler/type_registry.zig").TypeRegistry;
const TypeId = @import("../../compiler/type_registry.zig").TypeId;
const PrimitiveType = @import("../../compiler/type_registry.zig").PrimitiveType;
const DiagnosticsReporter = @import("../../diagnostics/diagnostics.zig").DiagnosticsReporter;
const Workspace = @import("../../compiler/workspace.zig").Workspace;
const Module = @import("../../compiler/workspace.zig").Module;

fn resolveType(allocator: std.mem.Allocator, registry: *TypeRegistry, type_str: []const u8) !TypeId {
    const source = try std.fmt.allocPrint(allocator, "var x: {s} = 0;", .{type_str});
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();
    const mod = try Module.init("test", source, allocator);
    var p = try Parser.init(allocator, &workspace, mod, io, &group);
    const node = try p.parse();
    const var_decl = node.program.declarations[0].var_decl;
    return try registry.resolve(var_decl.type_annotation.?);
}

test "TypeRegistry - Primitive Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const int_id = try resolveType(allocator, &registry, "Int");
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), int_id);

    const string_id = try resolveType(allocator, &registry, "String");
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.String), string_id);

    const float_id = try resolveType(allocator, &registry, "Float");
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Float), float_id);
}

test "TypeRegistry - Array Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const array_int_id = try resolveType(allocator, &registry, "Array[Int]");
    const array_int_id2 = try resolveType(allocator, &registry, "Array[Int]");

    // Deduplication check: same type should resolve to the same TypeId
    try std.testing.expectEqual(array_int_id, array_int_id2);

    const array_string_id = try resolveType(allocator, &registry, "Array[String]");
    try std.testing.expect(array_int_id != array_string_id);
}

test "TypeRegistry - Table Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const table_id = try resolveType(allocator, &registry, "Table[String, Int]");
    const table_id2 = try resolveType(allocator, &registry, "Table[String, Int]");
    try std.testing.expectEqual(table_id, table_id2);
}

test "TypeRegistry - Union Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const union_id = try resolveType(allocator, &registry, "Int | Nil");
    const union_id2 = try resolveType(allocator, &registry, "Int | Nil");
    try std.testing.expectEqual(union_id, union_id2);
}

test "TypeRegistry - Function Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const fn_id = try resolveType(allocator, &registry, "fn (Int, Float) -> String");
    const fn_id2 = try resolveType(allocator, &registry, "fn (Int, Float) -> String");
    try std.testing.expectEqual(fn_id, fn_id2);
}

test "TypeRegistry - Shape Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const shape_id = try resolveType(allocator, &registry, "shape { x: Int, y: Float }");
    const shape_id2 = try resolveType(allocator, &registry, "shape { x: Int, y: Float }");
    try std.testing.expectEqual(shape_id, shape_id2);
}
