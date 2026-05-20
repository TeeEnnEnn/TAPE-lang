const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const TypeRegistry = @import("../type_registry.zig").TypeRegistry;
const TypeId = @import("../type_registry.zig").TypeId;
const PrimitiveType = @import("../type_registry.zig").PrimitiveType;

fn resolveType(allocator: std.mem.Allocator, registry: *TypeRegistry, type_str: []const u8) !TypeId {
    const source = try std.fmt.allocPrint(allocator, "var x: {s} = 0;", .{type_str});
    var p = try Parser.init(allocator, source);
    const node = try p.parse();
    const var_decl = node.var_decl;
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

test "TypeRegistry - Vector and Matrix Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const vec_id = try resolveType(allocator, &registry, "Vector[3]");
    const vec_id2 = try resolveType(allocator, &registry, "Vector[3]");
    try std.testing.expectEqual(vec_id, vec_id2);

    const mat_id = try resolveType(allocator, &registry, "Matrix[2, 3]");
    const mat_id2 = try resolveType(allocator, &registry, "Matrix[2, 3]");
    try std.testing.expectEqual(mat_id, mat_id2);
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
