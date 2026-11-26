const std = @import("std");
const Entities = @import("../runtime/entities.zig");
const ManagedAllocator = @import("managed_allocator.zig");
const options = @import("TAPE_build_options");

pub const RootMarker = *const fn (isolate_ptr: *anyopaque, gc: *BasicGarbageCollector) void;
pub const CleanStringIntern = *const fn (isolate_ptr: *anyopaque, gc: *BasicGarbageCollector) void;

fn current_time() i64 {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.io();
    const now = std.Io.Clock.now(.awake, io);
    return now.toMilliseconds();
}

pub const BasicGarbageCollector = struct {
    /// Used for the gray stack
    allocator: std.mem.Allocator,
    managed_allocator: ManagedAllocator.ManagedAllocator,
    objects: ?*Entities.ObjectHeader = null,
    gray_stack: std.ArrayList(*Entities.ObjectHeader),
    next_gc: usize = 1024 * 1024,
    isolate_ptr: *anyopaque,
    mark_roots_fn: RootMarker,
    clean_string_intern: CleanStringIntern,
    collections: usize = 0,

    is_active: bool = true,

    const slab_capacity: usize = 1024;
    const stress_gc = options.stress_gc;
    const log_gc = options.log_gc;

    pub const SweepStats = struct {
        freed: usize,
        kept: usize,
        bytes_before: usize,
        bytes_after: usize,
    };

    fn count_objects(self: *BasicGarbageCollector) usize {
        var count: usize = 0;
        var current = self.objects;
        while (current) |obj| {
            count += 1;
            current = obj.next;
        }
        return count;
    }

    pub fn init(allocator: std.mem.Allocator, isolate_ptr: *anyopaque, mark_roots_fn: RootMarker, clean_string_intern: CleanStringIntern) !*BasicGarbageCollector {
        const gc = try allocator.create(BasicGarbageCollector);
        gc.* = .{
            .allocator = allocator,
            .managed_allocator = try ManagedAllocator.ManagedAllocator.init(allocator, slab_capacity),
            .gray_stack = .empty,
            .isolate_ptr = isolate_ptr,
            .mark_roots_fn = mark_roots_fn,
            .clean_string_intern = clean_string_intern,
            .is_active = true,
        };

        if (BasicGarbageCollector.log_gc) {
            std.debug.print(
                \\======= GARBAGE COLLECTOR INIT =======
                \\  slab_capacity: {d}
                \\  next_gc: {d}
                \\  stress_gc: {}
                \\======================================
                \\
            ,
                .{ BasicGarbageCollector.slab_capacity, gc.next_gc, BasicGarbageCollector.stress_gc },
            );
        }

        return gc;
    }

    pub fn deinit(self: *BasicGarbageCollector) void {
        const remaining = self.count_objects();
        const bytes_allocated = self.managed_allocator.bytes_allocated;

        if (BasicGarbageCollector.log_gc) {
            std.debug.print(
                \\======= GARBAGE COLLECTOR DEINIT =======
                \\  collections: {d}
                \\  remaining objects: {d}
                \\  bytes allocated: {d}
                \\======================================
                \\
            ,
                .{ self.collections, remaining, bytes_allocated },
            );
        }

        self.gray_stack.deinit(self.allocator);
        var current = self.objects;
        const alloc = self.managed_allocator.allocator();
        while (current) |obj| {
            const next = obj.next;
            Entities.free_object(alloc, obj);
            current = next;
        }

        self.managed_allocator.deinit();
        self.allocator.destroy(self);
    }

    pub fn allocate_object(self: *BasicGarbageCollector, comptime T: type, object_type: Entities.ObjectType) !*T {
        if (BasicGarbageCollector.stress_gc) {
            try self.collect();
        } else if (self.managed_allocator.bytes_allocated > self.next_gc) {
            try self.collect();
        }

        const alloc = self.managed_allocator.allocator();
        const ptr = try alloc.create(T);

        ptr.header = .{ .object_type = object_type, .marked = false, .next = self.objects };
        self.objects = &ptr.header;

        if (BasicGarbageCollector.log_gc) {
            std.debug.print(
                \\======= GARBAGE COLLECTOR ALLOC =======
                \\  type: {s}
                \\  size: {d}
                \\  addr: {*}
                \\  bytes_allocated: {d}
                \\  next_gc: {d}
                \\======================================
                \\
            ,
                .{
                    @tagName(object_type),
                    @sizeOf(T),
                    &ptr.header,
                    self.managed_allocator.bytes_allocated,
                    self.next_gc,
                },
            );
        }

        return ptr;
    }

    pub inline fn activate_collector(self: *BasicGarbageCollector) void {
        self.is_active = true;
    }

    pub inline fn deactivate_collector(self: *BasicGarbageCollector) void {
        self.is_active = false;
    }

    pub fn collect(self: *BasicGarbageCollector) !void {
        if (!self.is_active) {
            return;
        }
        const start_bytes = self.managed_allocator.bytes_allocated;
        const start_count = if (BasicGarbageCollector.log_gc) self.count_objects() else 0;
        const start_ms = if (BasicGarbageCollector.log_gc) current_time() else 0;

        if (BasicGarbageCollector.log_gc) {
            std.debug.print(
                \\======= GARBAGE COLLECTOR COLLECT #{d} =======
                \\  bytes allocated (start): {d}
                \\  objects (start): {d}
                \\  gray stack depth: {d}
                \\
            ,
                .{ self.collections + 1, start_bytes, start_count, self.gray_stack.items.len },
            );
        }
        self.mark_roots_fn(self.isolate_ptr, self);

        try self.trace_references();

        self.clean_string_intern(self.isolate_ptr, self);

        const sweep_stats = self.sweep();

        self.collections += 1;
        self.next_gc = self.managed_allocator.bytes_allocated * 2;
        if (BasicGarbageCollector.log_gc) {
            const end_ms = current_time();
            std.debug.print(
                \\  bytes allocated (end): {d}
                \\  objects (end): {d}
                \\  freed: {d} / kept: {d}
                \\  next_gc: {d}
                \\  duration: {d}ms
                \\======================================
                \\
            ,
                .{
                    sweep_stats.bytes_after,
                    sweep_stats.kept,
                    sweep_stats.freed,
                    sweep_stats.kept,
                    self.next_gc,
                    end_ms - start_ms,
                },
            );
        }
    }

    pub fn mark_object(self: *BasicGarbageCollector, obj: *Entities.ObjectHeader) !void {
        if (obj.marked) return;
        obj.marked = true;
        try self.gray_stack.append(self.allocator, obj);
    }

    pub fn trace_references(self: *BasicGarbageCollector) !void {
        const roots_queued = if (BasicGarbageCollector.log_gc) self.gray_stack.items.len else 0;
        if (BasicGarbageCollector.log_gc) {
            std.debug.print(
                \\  ------- TRACE -------
                \\  roots queued: {d}
                \\
            ,
                .{roots_queued},
            );
        }
        var traced: usize = 0;
        while (self.gray_stack.items.len > 0) {
            const obj = self.gray_stack.pop();
            try Entities.blacken_object(self, obj.?);
            traced += 1;
        }
        if (BasicGarbageCollector.log_gc) {
            std.debug.print(
                \\  traced: {d}
                \\  ---------------------
                \\
            ,
                .{traced},
            );
        }
    }

    pub fn sweep(self: *BasicGarbageCollector) SweepStats {
        const bytes_before = self.managed_allocator.bytes_allocated;
        var freed: usize = 0;
        var kept: usize = 0;
        var previous: ?*Entities.ObjectHeader = null;
        var current = self.objects;
        const alloc = self.managed_allocator.allocator();

        while (current) |obj| {
            if (obj.marked) {
                obj.marked = false;
                kept += 1;
                previous = obj;
                current = obj.next;
            } else {
                const unreached = obj;
                current = obj.next;
                if (previous) |prev| prev.next = current else self.objects = current;

                Entities.free_object(alloc, unreached);
                freed += 1;
            }
        }

        const bytes_after = self.managed_allocator.bytes_allocated;
        if (BasicGarbageCollector.log_gc) {
            std.debug.print(
                \\  ------- SWEEP -------
                \\  freed: {d}
                \\  kept: {d}
                \\  bytes before: {d}
                \\  bytes after: {d}
                \\  bytes freed: {d}
                \\  ---------------------
                \\
            ,
                .{ freed, kept, bytes_before, bytes_after, bytes_before -| bytes_after },
            );
        }

        return .{
            .freed = freed,
            .kept = kept,
            .bytes_before = bytes_before,
            .bytes_after = bytes_after,
        };
    }
};
