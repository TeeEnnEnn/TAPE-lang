const std = @import("std");
const Alignment = std.mem.Allocator.Alignment;
const SlabAllocator = @import("slab_allocator.zig");

pub const ManagedAllocator = struct {
    backing_allocator: std.mem.Allocator,
    bytes_allocated: usize,

    slab_24: *SlabAllocator.SlabAllocator,
    slab_32: *SlabAllocator.SlabAllocator,
    slab_48: *SlabAllocator.SlabAllocator,
    slab_64: *SlabAllocator.SlabAllocator,

    pub fn init(backing_allocator: std.mem.Allocator) !ManagedAllocator {
        return .{
            .backing_allocator = backing_allocator,
            .bytes_allocated = 0,
            .slab_24 = try SlabAllocator.SlabAllocator.init(backing_allocator),
            .slab_32 = try SlabAllocator.SlabAllocator.init(backing_allocator),
            .slab_48 = try SlabAllocator.SlabAllocator.init(backing_allocator),
            .slab_64 = try SlabAllocator.SlabAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *ManagedAllocator) void {
        self.slab_24.deinit();
        self.slab_32.deinit();
        self.slab_48.deinit();
        self.slab_64.deinit();
        self.backing_allocator.destroy(self);
    }

    pub fn allocator(self: *ManagedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = .{
            .alloc = alloc,
            .resize = resize,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ManagedAllocator = @ptrCast(@alignCast(ctx));
        if (self.bytes_allocated > self.next_gc) {
            self.collect_garbage();
        }
        if (len <= 24) {
            return self.slab_24.allocate_from_slab();
        } else if (len <= 32) {
            return self.slab_32.allocate_from_slab();
        } else if (len <= 48) {
            return self.slab_48.allocate_from_slab();
        } else if (len <= 64) {
            return self.slab_64.allocate_from_slab();
        } else {
            return self.backing_allocator.rawAlloc(len, alignment, ret_addr);
        }
    }

    /// Resize is not supported by ManagedAllocator.
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        std.debug.assert(false);
        return false;
    }

    /// Remap is not supported by ManagedAllocator.
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        std.debug.assert(false);
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ManagedAllocator = @ptrCast(@alignCast(ctx));
        if (memory.len <= 24) {
            self.slab_24.deallocate_from_slab(memory);
        } else if (memory.len <= 32) {
            self.slab_32.deallocate_from_slab(memory);
        } else if (memory.len <= 48) {
            self.slab_48.deallocate_from_slab(memory);
        } else if (memory.len <= 64) {
            self.slab_64.deallocate_from_slab(memory);
        } else {
            self.backing_allocator.rawFree(memory, alignment, ret_addr);
        }
    }
};
