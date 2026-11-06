const std = @import("std");

const TapeValue = @import("../natives.zig").NativeRequirements.value;
const RuntimePanic = @import("../natives.zig").NativeRequirements.error_type;
const Isolate = @import("../natives.zig").NativeRequirements.isolate;
const Entities = @import("../natives.zig").NativeRequirements.entities;
