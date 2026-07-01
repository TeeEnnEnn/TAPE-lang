const std = @import("std");
const Value = @import("../entities.zig").Value;
const values_equal = @import("../entities.zig").values_equal;

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
