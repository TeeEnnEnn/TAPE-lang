const std = @import("std");

const TapeValue = @import("../natives.zig").NativeRequirements.value;
const RuntimePanic = @import("../natives.zig").NativeRequirements.error_type;
const Isolate = @import("../natives.zig").NativeRequirements.isolate;
const Entities = @import("../natives.zig").NativeRequirements.entities;

/// Adds two integers
/// returns the result of the addition if there is no overflow. If the addition would cause overflow
/// an error is returned.
pub fn math_addi(isolate: *Isolate, args: []const TapeValue) RuntimePanic!TapeValue {
    _ = isolate;

    const a: i64 = args[0].int;
    const b: i64 = args[1].int;

    const result = std.math.add(@TypeOf(a), a, b) catch |e| {
        switch (e) {
            error.Overflow => {}, // TODO: decide how to return errors to TAPE
        }
    };

    return TapeValue{ .int = result };
}
