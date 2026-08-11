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

test "tableSet tableGet and tableDelete use open addressing" {
    const allocator = std.testing.allocator;
    var workspace = Workspace.init(allocator, std.testing.io);
    defer workspace.deinit();

    const vm = try VM.init(.{}, &workspace, allocator);
    defer vm.deinit();

    const isolate = try vm.new_isolate();
    const table = try Entities.newTableObject(isolate, 0);
    try isolate.push_value(.{ .object = &table.header });

    _ = try Entities.tableSet(isolate, table, .{ .int = 0 }, .{ .int = 10 });
    _ = try Entities.tableSet(isolate, table, .{ .int = 8 }, .{ .int = 20 });
    _ = try Entities.tableSet(isolate, table, .{ .int = 0 }, .{ .int = 30 });

    try std.testing.expectEqual(@as(i64, 30), (try Entities.tableGet(table, .{ .int = 0 })).?.int);
    try std.testing.expectEqual(@as(i64, 20), (try Entities.tableGet(table, .{ .int = 8 })).?.int);

    try std.testing.expect(try Entities.tableDelete(table, .{ .int = 0 }));
    try std.testing.expect((try Entities.tableGet(table, .{ .int = 0 })) == null);
    try std.testing.expectEqual(@as(i64, 20), (try Entities.tableGet(table, .{ .int = 8 })).?.int);

    _ = try Entities.tableSet(isolate, table, .{ .int = 16 }, .{ .int = 40 });
    try std.testing.expectEqual(@as(i64, 40), (try Entities.tableGet(table, .{ .int = 16 })).?.int);
}
