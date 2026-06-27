const std = @import("std");

pub const BasicAllocator = struct {};

pub const SlabAllocator = struct {
    allocator: std.mem.Allocator,
    slot_size: usize,
    slabs: std.ArrayList([]u8),
    free_slabs: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator, slot_size: usize) !*SlabAllocator {
        const self = allocator.create(SlabAllocator) catch {
            std.debug.print("Failed to create SlabAllocator\n", .{});
            return error.OutOfMemory;
        };
        std.debug.assert(std.math.isPowerOfTwo(slot_size));
        self.* = .{
            .allocator = allocator,
            .slot_size = slot_size,
            .slabs = .empty,
            .free_slabs = .empty,
        };
        return self;
    }

    pub fn deinit(self: *SlabAllocator) void {
        for (self.slabs.items) |slab| {
            self.allocator.free(slab);
        }
        self.slabs.deinit(self.allocator);
        self.free_slabs.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn append_new_slab(self: *SlabAllocator) !void {
        const new_slab = try self.allocator.alignedAlloc(u8, @alignOf(*anyopaque), self.slot_size);
        try self.slabs.append(self.allocator, new_slab);
        try self.free_slabs.append(self.allocator, new_slab);
    }

    fn allocate_from_slab(self: *SlabAllocator) !*anyopaque {
        if (self.free_slabs.items.len == 0) {
            try self.append_new_slab();
        }
        const slab = self.free_slabs.pop();
        if (slab) |alloced_slab| {
            return @ptrCast(alloced_slab.ptr);
        }
        return error.OutOfMemory;
    }

    fn deallocate_from_slab(self: *SlabAllocator, ptr: *anyopaque) void {
        const slice: []u8 = @as([*]u8, @ptrCast(ptr))[0..self.slot_size];
        self.free_slabs.append(self.allocator, slice) catch {
            std.debug.print("Failed to deallocate from slab\n", .{});
        };
    }
};
