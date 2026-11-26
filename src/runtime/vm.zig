const std = @import("std");
const Entities = @import("entities.zig");
const Chunk = @import("chunk.zig");
const BasicGarbageCollector = @import("../memory/basic_garbage_collector.zig");
const ManagedAllocator = @import("../memory/managed_allocator.zig");
const Workspace = @import("../compiler/workspace.zig").Workspace;
const TapeValue = Entities.Value;
const Opcode = Chunk.Opcode;
const Isolate = @import("isolate.zig").Isolate;

pub const VMConfig = struct {
    stack_size: usize = 2048,
    frame_capacity: usize = 128,
    globals_size: usize = 1024,
    debug_execution: bool = false,
};

pub const RuntimePanic = error{
    StackOverflow,
    StackUnderflow,
    DivisionByZero,
    ArgumentCountMismatch,
    CorruptedState,
    NegativeDenominator,
    OutOfMemory,
    IndexOutOfBounds,
    KeyNotFound,
    InvalidValue,
    FinishedCoroutineResumption,
    CoroutineAlreadyRunning,
    FailedOptionalUnwrap,
    Panic,
};

/// Represents the virtual machine - the orchestrator of execution.
pub const VM = struct {
    base_allocator: std.mem.Allocator,
    config: VMConfig,
    workspace: *Workspace,
    isolates: std.ArrayList(*Isolate),

    pub fn init(config: VMConfig, workspace: *Workspace, base_allocator: std.mem.Allocator) !*VM {
        const vm = try base_allocator.create(VM);
        vm.* = VM{
            .base_allocator = base_allocator,
            .config = config,
            .workspace = workspace,
            .isolates = .empty,
        };
        return vm;
    }

    /// deinits the VM
    /// destroys the pointer to the VM, so calling this function twice is not safe
    pub fn deinit(self: *VM) void {
        for (self.isolates.items) |isolate| {
            isolate.deinit();
        }
        self.isolates.deinit(self.base_allocator);
        self.base_allocator.destroy(self);
    }

    pub fn new_isolate(self: *VM, global_count: u16, function_constants_count: u16) !*Isolate {
        const isolate = try Isolate.init(self, self.base_allocator, global_count, function_constants_count);
        errdefer isolate.deinit();
        try self.isolates.append(self.base_allocator, isolate);
        return isolate;
    }
};
