const std = @import("std");

pub const SlabAllocatorError = error{
    InvalidSlotSize,
    InvalidCapacity,
} || std.mem.Allocator.Error;

pub const SlabNode = struct {
    next: ?*SlabNode,
    // memory slots follow immediately in memory
};

pub const SlabAllocator = struct {
    allocator: std.mem.Allocator,
    slot_size: usize,
    free_list: ?*anyopaque,
    slab_head: ?*SlabNode,
    capacity: usize,

    pub fn init(allocator: std.mem.Allocator, capacity: usize, slot_size: usize) SlabAllocatorError!*SlabAllocator {
        if (!std.math.isPowerOfTwo(slot_size)) {
            return .InvalidSlotSize;
        }
        if (slot_size < @sizeOf(*anyopaque)) {
            return .InvalidSlotSize;
        }
        if (capacity == 0) {
            return .InvalidCapacity;
        }

        const self = try allocator.create(SlabAllocator);

        self.* = .{
            .allocator = allocator,
            .slot_size = slot_size,
            .free_list = null,
            .slab_head = null,
            .capacity = capacity,
        };
        return self;
    }

    pub fn deinit(self: *SlabAllocator) void {
        const header_size = @sizeOf(SlabNode);
        const memory_size = self.slot_size * self.capacity;
        if (self.slab_head != null) {
            var curr = self.slab_head;
            while (curr) |node| {
                curr = node.next;
                const base: [*]u8 = @ptrCast(node);
                const slice = base[0 .. header_size + memory_size];
                self.allocator.free(slice);
            }
        }
        self.allocator.destroy(self);
    }

    fn append_new_slab(self: *SlabAllocator) !void {
        const header_size: usize = @sizeOf(SlabNode);
        const memory_size: usize = self.slot_size * self.capacity;

        const new_slab = try self.allocator.alloc(u8, header_size + memory_size);
        const node: *SlabNode = @ptrCast(@alignCast(new_slab.ptr));

        node.next = self.slab_head;
        self.slab_head = node;

        const memory: [*]u8 = new_slab.ptr + header_size;
        for (0..self.capacity - 1) |i| {
            const current_addr = memory + i * self.slot_size;
            const next_addr = memory + (i + 1) * self.slot_size;

            const current_slot: *?*anyopaque = @ptrCast(@alignCast(current_addr));
            current_slot.* = @ptrCast(next_addr);
        }

        const last_addr = memory.ptr + (self.capacity - 1) * self.slot_size;
        const last_slot: *?*anyopaque = @ptrCast(@alignCast(last_addr));
        last_slot.* = self.free_list;

        self.free_list = @ptrCast(memory);
    }

    pub fn allocate_from_slab(self: *SlabAllocator) !*anyopaque {
        if (self.free_list == null) {
            try self.append_new_slab();
        }

        const ptr = self.free_list;
        const next_slot: *?*anyopaque = @ptrCast(@alignCast(ptr));
        self.free_list = next_slot.*;
        return ptr;
    }

    pub fn free_from_slab(self: *SlabAllocator, ptr: *anyopaque) void {
        const slot: *?*anyopaque = @ptrCast(@alignCast(ptr));
        slot.* = self.free_list;
        self.free_list = ptr;
    }
};
