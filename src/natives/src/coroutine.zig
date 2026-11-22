const TapeValue = @import("../natives.zig").NativeRequirements.value;
const RuntimePanic = @import("../natives.zig").NativeRequirements.error_type;
const Isolate = @import("../natives.zig").NativeRequirements.isolate;
const Entities = @import("../natives.zig").NativeRequirements.entities;

fn coroutine_from(args: []const TapeValue) RuntimePanic!*Entities.ObjectCoroutine {
    const value = args[0];
    const object = switch (value) {
        .object => |obj| obj,
        else => return RuntimePanic.InvalidValue,
    };
    if (object.object_type != .ObjectCoroutine) return RuntimePanic.InvalidValue;
    return @ptrCast(object);
}

pub fn coroutine_returned(isolate: *Isolate, args: []const TapeValue) RuntimePanic!TapeValue {
    _ = isolate;
    const coroutine = try coroutine_from(args);
    return switch (coroutine.state) {
        .FINISHED => |value| value,
        .SUSPENDED, .RUNNING => .nil,
    };
}

pub fn coroutine_is_finished(isolate: *Isolate, args: []const TapeValue) RuntimePanic!TapeValue {
    _ = isolate;
    const coroutine = try coroutine_from(args);
    return .{ .boolean = switch (coroutine.state) {
        .FINISHED => true,
        .SUSPENDED, .RUNNING => false,
    } };
}
