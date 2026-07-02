const std = @import("std");
const Entities = @import("entities.zig");
const BasicGarbageCollector = @import("../memory/basic_garbage_collector.zig");
const ManagedAllocator = @import("../memory/managed_allocator.zig");

const VMConfig = struct {};

const BuiltinFunctions = struct {};

/// Represents the virtual machine - the orchestrator of execution.
const VM = struct {
    config: VMConfig,
    isolates: std.ArrayList(Isolate),

    pub fn init(config: VMConfig) VM {
        const vm = VM{
            .config = config,
            .isolates = .empty,
        };

        return vm;
    }
};

/// Represents an isolate, which is a self-contained execution context.
const Isolate = struct {
    vm: *VM,

    managed_allocator: *ManagedAllocator.ManagedAllocator,
    gc: *BasicGarbageCollector.BasicGarbageCollector,
    base_allocator: std.mem.Allocator,

    builtin_functions: BuiltinFunctions,
    string_intern: std.StringHashMap(*Entities.ObjectString),
    isolate_closure: *Entities.ObjectClosure,
    stack: [1024]Entities.Value,
    stack_top_index: usize,
    frames: std.ArrayList(*Entities.CallFrame),

    pub fn init(vm: *VM, base_allocator: std.mem.Allocator, builtin_functions: BuiltinFunctions, isolate_closure: *Entities.ObjectClosure) !void {
        const isolate = try base_allocator.create(Isolate);
        isolate.vm = vm;
        isolate.base_allocator = base_allocator;
        isolate.builtin_functions = builtin_functions;
        isolate.isolate_closure = isolate_closure;

        isolate.managed_allocator = try ManagedAllocator.ManagedAllocator.init(base_allocator);
        isolate.gc = BasicGarbageCollector.BasicGarbageCollector.init(base_allocator, &isolate.managed_allocator, isolate, mark_roots);

        isolate.stack_top_index = 0;
        isolate.frames = .empty;

        return isolate;
    }

    fn mark_roots(ptr: *anyopaque, gc: *BasicGarbageCollector.BasicGarbageCollector) void {
        const isolate: *Isolate = @ptrCast(@alignCast(ptr));

        for (isolate.stack[0..isolate.stack_top_index]) |value| {
            Entities.mark_value(gc, value) catch {
                // TODO: diagnostic
            };
        }
        // mark globals

        // mark interned strings
    }
};
