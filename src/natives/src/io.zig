const std = @import("std");

const TapeValue = @import("../natives.zig").NativeRequirements.value;
const RuntimePanic = @import("../natives.zig").NativeRequirements.error_type;
const Isolate = @import("../natives.zig").NativeRequirements.isolate;
const Entities = @import("../natives.zig").NativeRequirements.entities;

/// Writes an argument to the console (strings rendered raw) followed by a newline.
pub fn io_print(isolate: *Isolate, args: []const TapeValue) RuntimePanic!TapeValue {
    _ = isolate;

    const value = args[0];
    const chars = switch (value) {
        .object => |object| switch (object.object_type) {
            .ObjectString => @as(*Entities.ObjectString, @ptrCast(object)).chars,
            else => return RuntimePanic.InvalidValue,
        },
        else => return RuntimePanic.InvalidValue,
    };
    std.debug.print("{s}", .{chars});
    std.debug.print("\n", .{});
    return .nil;
}
