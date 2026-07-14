const std = @import("std");
const SlabAllocator = @import("../basic_allocator.zig").SlabAllocator;

test "SlabAllocator - initialization happy path" {
    const allocator = std.testing.allocator;
    const slot_size = 16;
    const slab_allocator = try SlabAllocator.init(allocator, slot_size);
    defer slab_allocator.deinit();
}
