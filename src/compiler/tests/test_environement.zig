const std = @import("std");
const Environment = @import("../environment.zig").Environment;
const EnvironmentError = @import("../environment.zig").EnvironmentError;
const TypeId = @import("../ast.zig").TypeId;

test "Environment - define works" {
    const allocator = std.testing.allocator;
    var env = Environment.init(allocator, null);
    defer env.deinit();

    try env.define("x", 42);
}

test "Environment - lookup works" {
    const allocator = std.testing.allocator;
    var env = Environment.init(allocator, null);
    defer env.deinit();

    try env.define("x", 42);
    const result = try env.lookup("x");
    try std.testing.expectEqual(@as(TypeId, 42), result);
}

test "Environment - fails for redefinition" {
    const allocator = std.testing.allocator;
    var env = Environment.init(allocator, null);
    defer env.deinit();

    try env.define("x", 42);
    const result = env.define("x", 43);
    try std.testing.expectError(error.DuplicateDefinition, result);
}

test "Environment - fails for non existent name" {
    const allocator = std.testing.allocator;
    var env = Environment.init(allocator, null);
    defer env.deinit();

    const result = env.lookup("y");
    try std.testing.expectError(error.UndefinedName, result);
}

test "Environment - correctly gets name from parent environment" {
    const allocator = std.testing.allocator;
    var parent = Environment.init(allocator, null);
    defer parent.deinit();

    try parent.define("x", 10);

    var child = Environment.init(allocator, &parent);
    defer child.deinit();

    const result = try child.lookup("x");
    try std.testing.expectEqual(@as(TypeId, 10), result);
}
