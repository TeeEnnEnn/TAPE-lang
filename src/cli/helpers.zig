//! Helper functions for the TAPE CLI

const std = @import("std");
const builtin = @import("builtin");
const Environ = std.process.Environ;
const options = @import("TAPE_lang_build_options");

const manifest_file_name = "tape.json";

pub const ManifestPackage = struct {
    name: []const u8,
    version: []const u8,
};

pub const ManifestConfig = struct {
    name: []const u8,
    entrypoint: []const u8,
    tape_version: []const u8,
    package_version: []const u8,
    packages: []ManifestPackage,
};

/// Gets the current working directory (The directory from which the TAPE CLI is being run)
/// Returns the path of the current directory as a allocated string.
/// Caller must free
pub fn get_current_dir_path(io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const path = try std.Io.Dir.realPathFileAlloc(cwd, io, ".", allocator);
    return path;
}

pub fn read_file(path: []const u8, dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    const file_contents = try dir.readFileAlloc(io, path, allocator, .unlimited);
    return file_contents;
}

pub fn get_manifest_path(starting_dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    var dir = starting_dir;
    while (true) {
        const dir_path = try std.Io.Dir.realPathFileAlloc(dir, io, ".", allocator);
        defer allocator.free(dir_path);
        const manifest_path = try std.fs.path.join(allocator, &.{ dir_path, manifest_file_name });
        if (std.Io.Dir.openFile(dir, io, manifest_path, .{ .path_only = true })) |_| {
            // we found a manifest
            return manifest_path;
        } else |_| {
            // move up a directory and try again
            allocator.free(manifest_path);
            const parent_path = try std.Io.Dir.realPathFileAlloc(dir, io, "..", allocator);
            defer allocator.free(parent_path);
            if (std.mem.eql(u8, parent_path, dir_path)) {
                return error.ManifestNotFound;
            }
            dir = try std.Io.Dir.openDir(dir, io, parent_path, .{});
            continue;
        }
    }
}

pub fn parse_manifest(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, manifest_path: []const u8) !ManifestConfig {
    const file_contents = try read_file(manifest_path, dir, io, allocator);
    const parsed = try std.json.parseFromSliceLeaky(ManifestConfig, allocator, file_contents, .{ .ignore_unknown_fields = true });
    return parsed;
}

pub fn get_package_entrypoint(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) ![]u8 {
    const manifest_path = try get_manifest_path(dir, io, allocator);
    defer allocator.free(manifest_path);
    const parsed_manifest = try parse_manifest(allocator, dir, io, manifest_path);
    const dir_path = try std.Io.Dir.realPathFileAlloc(dir, io, ".", allocator);
    defer allocator.free(dir_path);
    const resolved = try std.fs.path.join(allocator, &.{ dir_path, parsed_manifest.entrypoint });
    return resolved;
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
    const cwd = std.Io.Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    try std.Io.Dir.createDir(cwd, io, name, .default_dir);
    const new_project_dir_path = try std.fs.path.joinZ(allocator, &.{ cwd_path, name });
    defer allocator.free(new_project_dir_path);

    // package directory
    const pkg_dir_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, "pkg" });
    try std.Io.Dir.createDir(cwd, io, pkg_dir_path, .default_dir);
    const gitkeep_path = try std.fs.path.joinZ(allocator, &.{ pkg_dir_path, ".gitkeep" });
    _ = try std.Io.Dir.createFile(cwd, io, gitkeep_path, .{});

    // gitignore
    const gitignore_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, ".gitignore" });
    const gitignore_content = "# Do not ignore pkg directory\n!pkg/\n";
    _ = try std.Io.Dir.createFile(cwd, io, gitignore_path, .{});
    try std.Io.Dir.writeFile(cwd, io, .{ .data = gitignore_content, .sub_path = gitignore_path, .flags = .{} });

    // manifest file
    const tape_version = options.version;
    const manifest_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, manifest_file_name });
    const manifest_content = try std.fmt.allocPrint(allocator, "{{\n    \"name\": \"{s}\",\n    \"package_version\": \"0.0.1\",\n    \"entrypoint\": \"src/main.tape\",\n    \"tape_version\": \"{s}\",\n    \"packages\": []\n}}\n", .{ name, tape_version });
    defer allocator.free(manifest_content);
    _ = try std.Io.Dir.createFile(cwd, io, manifest_path, .{});
    try std.Io.Dir.writeFile(cwd, io, .{ .data = manifest_content, .sub_path = manifest_path, .flags = .{} });

    // src directory
    const src_dir_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, "src" });
    try std.Io.Dir.createDir(cwd, io, src_dir_path, .default_dir);

    // basic script
    const script_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, "src", "main.tape" });
    const script_content = "// This is the main script for the TAPE project.";
    _ = try std.Io.Dir.createFile(cwd, io, script_path, .{});
    try std.Io.Dir.writeFile(cwd, io, .{ .data = script_content, .sub_path = script_path, .flags = .{} });
}

pub const RESET = "\x1b[0m";
pub const BOLD_RED = "\x1b[1;31m";
pub const RED = "\x1b[31m";
pub const YELLOW = "\x1b[33m";
pub const GRAY = "\x1b[37m";
