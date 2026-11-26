const std = @import("std");

const TapeValue = @import("../runtime/entities.zig").Value;
const RuntimePanic = @import("../runtime/vm.zig").RuntimePanic;
const Isolate = @import("../runtime/isolate.zig").Isolate;
const Entities = @import("../runtime/entities.zig");

/// TAPE types that native files can access
pub const NativeRequirements = struct {
    pub const value: type = TapeValue;
    pub const error_type: type = RuntimePanic;
    pub const isolate: type = Isolate;
    pub const entities: type = Entities;
};

pub const NativeCallable = *const fn (*Isolate, []const TapeValue) RuntimePanic!TapeValue;

/// A compiled native callable and its discovery key.
pub const Entry = struct {
    /// Name used in the TAPE native declaration
    fn_name: []const u8,
    /// The function pointer.
    callable: NativeCallable,
};

/// files that will be searches for native functions
const native_files = .{ .io = @import("src/io.zig"), .coroutine = @import("src/coroutine.zig") };

/// Ensure that a function `T` matches the expected NativeCallable type.
fn matches_native_signature(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .@"fn" => |f| {
            if (f.is_generic or f.attrs.varargs) return false;
            if (f.param_types.len != 2) return false;
            const isolate_type = f.param_types[0] orelse return false;
            const args_type = f.param_types[1] orelse return false;
            const return_type = f.return_type orelse return false;
            return isolate_type == *Isolate and args_type == []const TapeValue and return_type == RuntimePanic!TapeValue;
        },
        else => return false,
    }
}

/// Enforces the native naming convention: `<module_name>_<function_name>`
fn check_native_name(comptime file_key: [:0]const u8, comptime decl_name: [:0]const u8) void {
    const prefix = file_key ++ "_";
    if (!std.mem.startsWith(u8, decl_name, prefix)) {
        @compileError("Native function '" ++ decl_name ++ "' in module '" ++ file_key ++ "' must be named after its module: '" ++ prefix ++ "<function_name>'.");
    }
    if (decl_name.len == prefix.len) {
        @compileError("Native function must include a name after the module prefix in module '" ++ file_key ++ "': '" ++ prefix ++ "<function_name>'.");
    }
}

pub const Natives = struct {
    /// Flat, table of native callables.
    pub const natives: [native_count]Entry = build_native_table();

    /// native_name: the name used in the TAPE native declaration
    /// returns the slot index used for code generation, or null if not found
    pub fn find(native_name: []const u8) ?u16 {
        for (natives, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.fn_name, native_name)) {
                return @intCast(index);
            }
        }
        return null;
    }

    /// index: the slot index produced by `find`
    /// returns the callable to invoke
    pub fn get(index: u16) NativeCallable {
        return natives[index].callable;
    }
};

/// Number of native callables matching `NativeCallable` across all native modules
const native_count = blk: {
    var count: u16 = 0;
    for (@typeInfo(@TypeOf(native_files)).@"struct".field_names) |file_key| {
        const file = @field(native_files, file_key);
        for (@typeInfo(file).@"struct".decl_names) |decl_name| {
            if (matches_native_signature(@TypeOf(@field(file, decl_name)))) {
                check_native_name(file_key, decl_name);
                count += 1;
            }
        }
    }
    break :blk count;
};

/// Builds the native table by reflecting over every native module's public declarations.
fn build_native_table() [native_count]Entry {
    var entries: [native_count]Entry = undefined;
    var index: u16 = 0;
    for (@typeInfo(@TypeOf(native_files)).@"struct".field_names) |file_key| {
        const file = @field(native_files, file_key);
        for (@typeInfo(file).@"struct".decl_names) |decl_name| {
            if (matches_native_signature(@TypeOf(@field(file, decl_name)))) {
                check_native_name(file_key, decl_name);
                entries[index] = .{
                    .fn_name = decl_name,
                    .callable = @field(file, decl_name),
                };
                index += 1;
            }
        }
    }

    // ensuring that there are no duplicate names
    for (entries, 0..) |entry_a, index_a| {
        for (entries[index_a + 1 ..]) |entry_b| {
            if (std.mem.eql(u8, entry_a.fn_name, entry_b.fn_name)) {
                @compileError("Duplicate native function name '" ++ std.fmt.comptimePrint("{s}", .{entry_a.fn_name}) ++ "'. Native names must be unique.");
            }
        }
    }
    return entries;
}
