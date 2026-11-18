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
    const mod = try Module.init("test", source, allocator, true);
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
    try std.testing.expectEqual(@backingInt(PrimitiveType.Int), int_id);

    const string_id = try resolveType(allocator, &registry, "String");
    try std.testing.expectEqual(@backingInt(PrimitiveType.String), string_id);

    const float_id = try resolveType(allocator, &registry, "Float");
    try std.testing.expectEqual(@backingInt(PrimitiveType.Float), float_id);
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

test "TypeRegistry - Optional Types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    const opt_int = try resolveType(allocator, &registry, "?Int");
    const opt_int2 = try resolveType(allocator, &registry, "?Int");
    // Deduplication: the same inner type resolves to the same TypeId
    try std.testing.expectEqual(opt_int, opt_int2);
    try std.testing.expect(opt_int != @backingInt(PrimitiveType.Int));

    // `?Nil` and nested optionals are also rejected at the registry level so
    // aliases cannot smuggle them past the parser.
    try std.testing.expectError(error.OptionalOfNil, registry.add_optional_type(@backingInt(PrimitiveType.Nil)));
    try std.testing.expectError(error.NestedOptional, registry.add_optional_type(opt_int));
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
