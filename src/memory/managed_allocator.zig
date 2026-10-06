const std = @import("std");
const Alignment = std.mem.Alignment;
const SlabAllocator = @import("slab_allocator.zig");
const Slab = SlabAllocator.SlabAllocator;

// Single source of truth for size classes. alloc and free both route
// through slabClass(), so a block always returns to the slab it came from.
const size_classes = [_]usize{ 24, 32, 48, 64 };
const max_slab_size = size_classes[size_classes.len - 1];

const slab_alignment = Alignment.of(SlabAllocator.SlabNode);

/// Maps (len + 7) / 8 to a size class index. built from size classes
const class_table = blk: {
    var table: [max_slab_size / 8 + 1]u8 = undefined;
    for (&table, 0..) |*entry, granule| {
        const size = granule * 8;
        var class: u8 = 0;
        while (size_classes[class] < size) class += 1;
        entry.* = class;
    }
    break :blk table;
};

/// Returns the slab index for a request, or null if it must go to the
/// backing allocator.
inline fn slabClass(len: usize, alignment: Alignment) ?usize {
    if (len > max_slab_size) return null;
    if (alignment.compare(.gt, slab_alignment)) return null;
    return class_table[(len + 7) >> 3];
}

pub const ManagedAllocator = struct {
    backing_allocator: std.mem.Allocator,
    bytes_allocated: usize,
    slabs: [size_classes.len]*Slab,

    pub fn init(backing_allocator: std.mem.Allocator, slab_capacity: usize) !ManagedAllocator {
        var slabs: [size_classes.len]*Slab = undefined;
        var initialized: usize = 0;
        // If a later slab fails to init, release the ones already created.
        errdefer for (slabs[0..initialized]) |s| s.deinit();

        for (size_classes, 0..) |size, i| {
            slabs[i] = try Slab.init(backing_allocator, slab_capacity, size);
            initialized += 1;
        }

        return .{
            .backing_allocator = backing_allocator,
            .bytes_allocated = 0,
            .slabs = slabs,
        };
    }

    pub fn deinit(self: *ManagedAllocator) void {
        for (self.slabs) |s| s.deinit();
    }

    pub fn allocator(self: *ManagedAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc,
        .resize = resize,
        .free = free,
        .remap = remap,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ManagedAllocator = @ptrCast(@alignCast(ctx));

        const ptr: ?[*]u8 = if (slabClass(len, alignment)) |class| blk: {
            const slot = self.slabs[class].allocate_from_slab() catch break :blk null;
            break :blk @ptrCast(slot);
        } else self.backing_allocator.rawAlloc(len, alignment, ret_addr);

        // Count only successful allocations.
        if (ptr != null) self.bytes_allocated += len;
        return ptr;
    }

    /// Resize is not supported by ManagedAllocator.
    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return false;
    }

    /// Remap is not supported by ManagedAllocator.
    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = memory;
        _ = alignment;
        _ = new_len;
        _ = ret_addr;
        return null;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *ManagedAllocator = @ptrCast(@alignCast(ctx));

        if (slabClass(memory.len, alignment)) |class| {
            self.slabs[class].deallocate_from_slab(@ptrCast(memory.ptr));
        } else {
            self.backing_allocator.rawFree(memory, alignment, ret_addr);
        }
        // memory.len should never be greater than bytes allocated
        std.debug.assert(self.bytes_allocated >= memory.len);
        self.bytes_allocated -= memory.len;
    }
};
