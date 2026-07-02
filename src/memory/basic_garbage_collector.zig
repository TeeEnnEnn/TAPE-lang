const std = @import("std");
const Entities = @import("../vm/entities.zig");
const ManagedAllocator = @import("managed_allocator.zig");

pub const RootMarker = *const fn (isolate_ptr: *anyopaque, gc: *BasicGarbageCollector) void;

pub const BasicGarbageCollector = struct {
    /// Used for the gray stack
    allocator: std.mem.Allocator,
    managed_allocator: *ManagedAllocator.ManagedAllocator,
    objects: ?*Entities.ObjectHeader = null,
    gray_stack: std.ArrayList(*Entities.ObjectHeader),

    next_gc: usize = 1024 * 1024,

    isolate_ptr: *anyopaque,
    mark_roots_fn: RootMarker,

    pub fn init(allocator: std.mem.Allocator, managed: *ManagedAllocator.ManagedAllocator, isolate_ptr: *anyopaque, mark_roots_fn: RootMarker) BasicGarbageCollector {
        return .{
            .allocator = allocator,
            .managed_allocator = managed,
            .gray_stack = .empty,
            .isolate_ptr = isolate_ptr,
            .mark_roots_fn = mark_roots_fn,
        };
    }

    pub fn deinit(self: *BasicGarbageCollector) void {
        self.gray_stack.deinit(self.allocator);
        // sweep everything

        // deinit managed allocator
        self.managed_allocator.deinit();
    }

    pub fn allocate_object(self: *BasicGarbageCollector, comptime T: type, object_type: Entities.ObjectType) !*T {
        if (self.managed_allocator.bytes_allocated > self.next_gc) {
            try self.collect();
        }

        const alloc = self.managed_allocator.allocator();
        const ptr = alloc.create(T);

        ptr.header = .{ .object_type = object_type, .marked = false, .next = self.objects };
        self.objects = &ptr.header;

        return ptr;
    }

    pub fn collect(self: *BasicGarbageCollector) !void {
        self.mark_roots_fn(self.isolate_ptr, self);

        try self.trace_references();

        self.sweep();

        self.next_gc = self.managed_allocator.bytes_allocated * 2;
    }

    pub fn mark_object(self: *BasicGarbageCollector, obj: *Entities.ObjectHeader) !void {
        if (obj.marked) return;
        obj.marked = true;
        try self.gray_stack.append(self.allocator, obj);
    }

    pub fn trace_references(self: *BasicGarbageCollector) !void {
        while (self.gray_stack.items.len > 0) {
            const obj = self.gray_stack.pop();
            try Entities.blacken_object(self, obj);
        }
    }

    pub fn sweep(self: *BasicGarbageCollector) void {
        var previous: ?*Entities.ObjectHeader = null;
        var current = self.objects;
        const alloc = self.managed_allocator.allocator();

        while (current) |obj| {
            if (obj.marked) {
                obj.marked = false;
                previous = obj;
                current = obj.next;
            } else {
                const unreached = obj;
                current = obj.next;
                if (previous) |prev| prev.next = current else self.objects = current;

                Entities.free_object(alloc, unreached);
            }
        }
    }
};
