//! Helper functions for the TAPE CLI

const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;

/// Gets the current working directory (The directory from which the TAPE CLI is being run)
/// Returns the path of the current directory as a allocated string.
/// Caller must free
pub fn get_current_dir(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const path = try std.Io.Dir.realPathFileAlloc(cwd, io, ".", allocator);
    return path;
}

/// Gets the user's home directory
/// Returns the path of the user's home directory as a allocated string.
/// Caller must free
pub fn get_user_home_dir(environ_map: *Environ.Map) ![]u8 {
    if (builtin.os.tag == .windows) {
        return environ_map.get("USERPROFILE") orelse error.HomeDirNotFound;
    } else if (builtin.os.tag == .macos) {
        return environ_map.get("HOME") orelse error.HomeDirNotFound;
    } else if (builtin.os.tag == .linux) {
        return environ_map.get("HOME") orelse error.HomeDirNotFound;
    } else {
        return error.UnsupportedOS;
    }
}

/// Gets the TAPE directory and checks if it exists, and it is readable/writable
/// Returns the path to the TAPE directory as an allocated string.
/// Caller must free
pub fn get_tape_dir(io: std.Io, environ_map: *Environ.Map, allocator: std.mem.Allocator) ![]u8 {
    const home_dir = try get_user_home_dir(environ_map);
    const tape_dir = try std.fs.path.joinZ(allocator, .{ home_dir, ".TAPE" });
    if (std.Io.Dir.accessAbsolute(io, tape_dir, .{ .read = true, .write = true })) {
        return tape_dir;
    } else |_| {
        return error.TapeDirNotFound;
    }
}

/// creates a new TAPE project in the given directory
pub fn create_tape_project(io: std.Io, allocator: std.mem.Allocator, name: []const u8) !void {
    _ = io;
    _ = allocator;
    _ = name;
}
