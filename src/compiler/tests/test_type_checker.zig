const std = @import("std");
const TypeChecker = @import("../type_checker.zig").TypeChecker;
const TypeCheckerError = @import("../type_checker.zig").TypeCheckerError;
const Environment = @import("../environment.zig").Environment;
const EnvironmentError = @import("../environment.zig").EnvironmentError;
const TypeRegistry = @import("../type_registry.zig").TypeRegistry;
const TypeId = @import("../ast.zig").TypeId;
const Parser = @import("../parser.zig").Parser;
const PrimitiveType = @import("../type_registry.zig").PrimitiveType;

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !struct { registry: TypeRegistry, env: Environment } {
    var parser = try Parser.init(allocator, source);
    const program = try parser.parse();

    var env = Environment.init(allocator, null);
    var registry = try TypeRegistry.init(allocator);
    var checker = TypeChecker.init(allocator, &registry, &env);
    try checker.check(program);

    return .{ .registry = registry, .env = env };
}

test "Type Checker - Init works" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var env = Environment.init(allocator, null);
    defer env.deinit();

    var registry = try TypeRegistry.init(arena_allocator);
    defer registry.deinit();

    const type_checker = TypeChecker.init(allocator, &registry, &env);
    _ = type_checker;
}

test "Type Checker - checks typed variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator, "var x: Int = 1;");
    defer result.env.deinit();
    defer result.registry.deinit();

    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), try result.env.lookup("x"));
}

test "Type Checker - rejects mismatched variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "var x: String = 1;"));
}

test "Type Checker - checks function declaration and return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator, "fn id(x: Int) -> Int { return x; }");
    defer result.env.deinit();
    defer result.registry.deinit();

    const fn_type = result.registry.get_type_info(try result.env.lookup("id"));
    try std.testing.expect(fn_type == .function);
    try std.testing.expectEqual(@as(usize, 1), fn_type.function.args.len);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), fn_type.function.args[0]);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), fn_type.function.ret);
}

test "Type Checker - rejects function return mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "fn bad() -> String { return 1; }"));
}

test "Type Checker - checks struct construction and member access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator,
        \\struct Point { x: Int, y: Int }
        \\var p = new Point { x = 1, y = 2 };
        \\var px: Int = p.x;
    );
    defer result.env.deinit();
    defer result.registry.deinit();

    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), try result.env.lookup("px"));
}
