const std = @import("std");
const TypeChecker = @import("../type_checker.zig").TypeChecker;
const TypeCheckerError = @import("../type_checker.zig").TypeCheckerError;
const Environment = @import("../environment.zig").Environment;
const EnvironmentError = @import("../environment.zig").EnvironmentError;
const TypeRegistry = @import("../type_registry.zig").TypeRegistry;
const TypeId = @import("../ast.zig").TypeId;

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
