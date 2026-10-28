const std = @import("std");
const Entities = @import("../../runtime/entities.zig");
const Value = Entities.Value;
const values_equal = Entities.values_equal;
const Workspace = @import("../../compiler/workspace.zig").Workspace;
const VM = @import("../../runtime/vm.zig").VM;

test "values_equal" {
    const a = Value{ .int = 42 };
    const b = Value{ .int = 42 };
    const result = values_equal(a, b);
    try std.testing.expect(result);
}

test "values_equal different types" {
    const a = Value{ .int = 42 };
    const b = Value{ .float = 42.0 };
    const result = values_equal(a, b);
    try std.testing.expect(!result);
}

test "table_set table_get and table_delete use open addressing" {
    const allocator = std.testing.allocator;
    var workspace = Workspace.init(allocator, std.testing.io);
    defer workspace.deinit();

    const vm = try VM.init(.{}, &workspace, allocator);
    defer vm.deinit();

    const isolate = try vm.new_isolate(@intCast(vm.config.globals_size), 256);
    const table = try Entities.new_table_object(isolate);
    try isolate.push_value(.{ .object = &table.header });

    _ = try Entities.table_set(isolate, table, .{ .int = 0 }, .{ .int = 10 });
    _ = try Entities.table_set(isolate, table, .{ .int = 8 }, .{ .int = 20 });
    _ = try Entities.table_set(isolate, table, .{ .int = 0 }, .{ .int = 30 });

    try std.testing.expectEqual(@as(i64, 30), (try Entities.table_get(table, .{ .int = 0 })).?.int);
    try std.testing.expectEqual(@as(i64, 20), (try Entities.table_get(table, .{ .int = 8 })).?.int);

    try std.testing.expect(try Entities.table_delete(table, .{ .int = 0 }));
    try std.testing.expect((try Entities.table_get(table, .{ .int = 0 })) == null);
    try std.testing.expectEqual(@as(i64, 20), (try Entities.table_get(table, .{ .int = 8 })).?.int);

    _ = try Entities.table_set(isolate, table, .{ .int = 16 }, .{ .int = 40 });
    try std.testing.expectEqual(@as(i64, 40), (try Entities.table_get(table, .{ .int = 16 })).?.int);
}
