const std = @import("std");
const builtin = @import("builtin");

const options = @import("TAPE_lang_build_options");

const TapeScanner = @import("../compiler/scanner.zig");
const TapeParser = @import("../compiler/parser.zig");
const TapeTypeChecker = @import("../compiler/type_checker.zig");
const TapeEnvironment = @import("../compiler/environment.zig");
const TapeTypeRegistry = @import("../compiler/type_registry.zig");
const TapeDiagnostics = @import("../diagnostics/diagnostics.zig");
const TapeWorkspace = @import("../compiler/workspace.zig");

const Environ = std.process.Environ;

pub const RESET = "\x1b[0m";
pub const BOLD_RED = "\x1b[1;31m";
pub const RED = "\x1b[31m";
pub const YELLOW = "\x1b[33m";
pub const GRAY = "\x1b[37m";

const app_manifest_file_name = "app.tape.json";
const pkg_manifest_file_name = "pkg.tape.json";

/// Errors that can occur when running TAPE in REPL mode.
const TapeReplError = error{
    /// The user has exited the REPL.
    ReplExit,
};

/// Errors that can occur when running a TAPE script file.
const TapeScriptError = error{
    /// The file does not exist.
    FileNotFound,
    /// The file exists but could not be accessed.
    FileAccessError,
};

const TapeInitProjectError = error{
    /// The project name is invalid.
    InvalidName,
    /// The project directory already exists.
    DirectoryExists,
};

const CliError = error{
    AmbiguousCommand,
    InvalidCommand,
};

/// A option for a command.
const CommandOption = union(enum) {
    /// An optional keyword option for a command.
    optional_keyword: []const u8,
    /// A required keyword option for a command.
    required_keyword: []const u8,
    /// An optional value option for a command.
    optional_value: []const u8,
    /// A required value option for a command.
    required_value: []const u8,
    /// A required choice between n items
    required_choice: []const []const u8,
};

const Command = struct {
    /// The name of the command.
    name: []const u8,
    /// The description of the command.
    description: []const u8,
    /// The handler function for the command.
    handler: *const fn (io: std.Io, []const []const u8, allocator: std.mem.Allocator) u8,
    /// The options of the command. The arguments needed to execute the command.
    options: []const CommandOption,
};

/// All possible commands
const commands: []const Command = &[_]Command{
    .{
        .name = "repl",
        .description = "Runs TAPE in interactive mode",
        .handler = run_repl,
        .options = &[_]CommandOption{},
    },
    .{
        .name = "run",
        .description = "Runs a TAPE script file",
        .handler = run_file,
        .options = &[_]CommandOption{ CommandOption{ .required_keyword = "run" }, CommandOption{ .optional_value = "path" } },
    },
    .{
        .name = "init",
        .description = "Initializes a new TAPE project",
        .handler = init_project,
        .options = &[_]CommandOption{ CommandOption{ .required_keyword = "init" }, CommandOption{ .required_choice = &.{ "app", "pkg" } }, CommandOption{ .optional_value = "name" } },
    },
    .{
        .name = "version",
        .description = "Displays the TAPE version",
        .handler = get_version,
        .options = &[_]CommandOption{CommandOption{ .required_keyword = "-v" }},
    },
    .{
        .name = "help",
        .description = "Displays this help message",
        .handler = get_help,
        .options = &[_]CommandOption{CommandOption{ .required_keyword = "-h" }},
    },
    .{
        .name = "check",
        .description = "Run the parser and type checker.",
        .handler = run_check,
        .options = &[_]CommandOption{ CommandOption{ .required_keyword = "check" }, CommandOption{ .optional_value = "path" } },
    },
};

/// Manifests can be of two types
/// 1. Application - Manifest defining an executable TAPE application
/// 2. Package - Manifest defining a reusable TAPE package
pub const ManifestType = enum { Application, Package };

/// The definition of a package used in manifest files
/// package versions will be compared as strings and not semvar
pub const ManifestPackage = struct {
    name: []const u8,
    version: []const u8,
};

/// Configuration used when definitng an application
pub const AppManifestConfig = struct {
    name: []const u8,
    entrypoint: []const u8,
    tape_version: []const u8,
    app_version: []const u8,
    packages: []ManifestPackage,
};

/// Configuration used when defining a package
pub const PackageManifestConfig = struct {
    name: []const u8,
    entrypoint: []const u8,
    tape_version: []const u8,
    package_version: []const u8,
    requires: []ManifestPackage,
};

/// Gets the directory from which the TAPE CLI is being run
/// Returns the path of the current directory as a allocated string.
/// Caller must free
pub fn read_file(path: []const u8, dir: std.Io.Dir, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
    return dir.readFileAlloc(io, path, allocator, .unlimited);
}

pub fn get_current_dir_path(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const cwd = std.Io.Dir.cwd();
    const path = try std.Io.Dir.realPathFileAlloc(cwd, io, ".", allocator);
    return path;
}

/// Gets the path to closest the manifest file
/// Returns the path to the closest manifest file as an allocated string
/// Caller must free
pub fn get_manifest_path(allocator: std.mem.Allocator, starting_dir: std.Io.Dir, io: std.Io) ![]u8 {
    var dir = starting_dir;
    while (true) {
        const dir_path = try std.Io.Dir.realPathFileAlloc(dir, io, ".", allocator);
        defer allocator.free(dir_path);
        const app_manifest_path = try std.fs.path.join(allocator, &.{ dir_path, app_manifest_file_name });
        const pkg_manifest_path = try std.fs.path.join(allocator, &.{ dir_path, pkg_manifest_file_name });
        if (std.Io.Dir.openFile(dir, io, app_manifest_path, .{ .path_only = true }) catch null) |_| {
            return app_manifest_path; // we found an app manifest
        } else if (std.Io.Dir.openFile(dir, io, pkg_manifest_path, .{ .path_only = true }) catch null) |_| {
            return pkg_manifest_path; // we found a package manifest
        } else {
            // move up a directory and try again
            allocator.free(app_manifest_path);
            allocator.free(pkg_manifest_path);
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

/// Parse the manifest at the given path
/// Generic over the manifest type
/// This function allocates - but cannot be freed. Memory will be returned when allocated deinits
pub fn parse_manifest(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io, manifest_path: []const u8, manifest_type: type) !manifest_type {
    const file_contents = try dir.readFileAlloc(io, manifest_path, allocator, .unlimited);
    const parsed = try std.json.parseFromSliceLeaky(manifest_type, allocator, file_contents, .{ .ignore_unknown_fields = true });
    return parsed;
}

/// Gets the entry point of a package or application project
/// returns the entrypoint file path as an allocated string
/// Caller must free
pub fn get_entrypoint(allocator: std.mem.Allocator, dir: std.Io.Dir, io: std.Io) ![]u8 {
    const manifest_path = try get_manifest_path(allocator, dir, io);
    defer allocator.free(manifest_path);
    const file_contents = try dir.readFileAlloc(io, manifest_path, allocator, .unlimited);
    const basename = std.fs.path.basename(manifest_path);
    const entrypoint = if (std.mem.eql(u8, basename, app_manifest_file_name))
        (try std.json.parseFromSliceLeaky(AppManifestConfig, allocator, file_contents, .{ .ignore_unknown_fields = true })).entrypoint
    else if (std.mem.eql(u8, basename, pkg_manifest_file_name))
        (try std.json.parseFromSliceLeaky(PackageManifestConfig, allocator, file_contents, .{ .ignore_unknown_fields = true })).entrypoint
    else
        return error.ManifestNotFound;
    const dir_path = try std.Io.Dir.realPathFileAlloc(dir, io, ".", allocator);
    defer allocator.free(dir_path);
    const resolved = try std.fs.path.join(allocator, &.{ dir_path, entrypoint });
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
pub fn create_tape_project(io: std.Io, allocator: std.mem.Allocator, name: []const u8, manifest_type: ManifestType) !void {
    const cwd = std.Io.Dir.cwd();
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    // project directory
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
    const manifest_file_name = if (manifest_type == .Application) app_manifest_file_name else if (manifest_type == .Package) pkg_manifest_file_name else unreachable;
    const manifest_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, manifest_file_name });
    var manifest_content: []u8 = undefined;
    if (manifest_type == .Application) {
        manifest_content = try std.fmt.allocPrint(allocator, "{{\n    \"name\": \"{s}\",\n    \"package_version\": \"0.0.1\",\n    \"entrypoint\": \"src/main.tape\",\n    \"tape_version\": \"{s}\",\n    \"packages\": []\n}}\n", .{ name, tape_version });
    } else if (manifest_type == .Package) {
        manifest_content = try std.fmt.allocPrint(allocator, "{{\n    \"name\": \"{s}\",\n    \"package_version\": \"0.0.1\",\n    \"entrypoint\": \"src/lib.tape\",\n    \"tape_version\": \"{s}\",\n    \"requires\": []\n}}\n", .{ name, tape_version });
    } else {
        unreachable;
    }

    defer allocator.free(manifest_content);
    _ = try std.Io.Dir.createFile(cwd, io, manifest_path, .{});
    try std.Io.Dir.writeFile(cwd, io, .{ .data = manifest_content, .sub_path = manifest_path, .flags = .{} });

    // src directory
    const src_dir_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, "src" });
    try std.Io.Dir.createDir(cwd, io, src_dir_path, .default_dir);

    // basic script
    var script_path: []u8 = undefined;
    if (manifest_type == .Application) {
        script_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, "src", "main.tape" });
    } else if (manifest_type == .Package) {
        script_path = try std.fs.path.joinZ(allocator, &.{ new_project_dir_path, "src", "lib.tape" });
    }
    defer allocator.free(script_path);
    const script_content = "// This is the entrypoint script for your TAPE project.";
    _ = try std.Io.Dir.createFile(cwd, io, script_path, .{});
    try std.Io.Dir.writeFile(cwd, io, .{ .data = script_content, .sub_path = script_path, .flags = .{} });
}

pub fn run_repl(io: std.Io, parsed_args: []const []const u8, allocator: std.mem.Allocator) u8 {
    _ = parsed_args;
    const stdout = std.Io.File.stdout();
    _ = allocator;
    stdout.writeStreamingAll(io, "This is the TAPE REPL. Type 'exit' to quit.") catch {
        return 1;
    };
    return 0;
}

const CompileCommandArgs = struct {
    path: ?[]const u8 = null,
    debug: TapeWorkspace.DebugOptions = .{},
};

fn emit_cli_error(message: []const u8) void {
    std.debug.print("{s}Error:{s} {s}\n", .{ RED, RESET, message });
}

fn parse_compile_command_args(args: []const []const u8) !CompileCommandArgs {
    var result = CompileCommandArgs{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) {
            result.debug.enable_all();
        } else if (std.mem.eql(u8, arg, "--debug-ast")) {
            result.debug.ast = true;
        } else if (std.mem.eql(u8, arg, "--debug-bytecode")) {
            result.debug.bytecode = true;
        } else if (std.mem.eql(u8, arg, "--debug-vm")) {
            result.debug.vm = true;
        } else if (std.mem.eql(u8, arg, "--debug-pipeline")) {
            result.debug.pipeline = true;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.InvalidOption;
        } else if (result.path == null) {
            result.path = arg;
        } else {
            return error.TooManyPaths;
        }
    }
    return result;
}

fn resolve_source_path(allocator: std.mem.Allocator, io: std.Io, path: ?[]const u8) ![]u8 {
    if (path) |provided_path| {
        if (std.fs.path.isAbsolute(provided_path)) return try allocator.dupe(u8, provided_path);
        const current_dir = try get_current_dir_path(allocator, io);
        defer allocator.free(current_dir);
        return try std.fs.path.join(allocator, &.{ current_dir, provided_path });
    }
    return get_entrypoint(allocator, std.Io.Dir.cwd(), io);
}

fn run_compile_command(io: std.Io, parsed_args: []const []const u8, allocator: std.mem.Allocator, execute: bool) u8 {
    const command_args = parse_compile_command_args(parsed_args) catch |err| {
        emit_cli_error(switch (err) {
            error.InvalidOption => "Unknown option. Supported debug options: --debug, --debug-ast, --debug-bytecode, --debug-vm, --debug-pipeline.",
            error.TooManyPaths => "Expected at most one source file path.",
        });
        return 1;
    };

    var workspace = TapeWorkspace.Workspace.init(allocator, io);
    defer workspace.deinit();

    const file_path = resolve_source_path(allocator, io, command_args.path) catch {
        emit_cli_error("Unable to resolve the source file path.");
        return 1;
    };
    defer allocator.free(file_path);

    const succeeded = workspace.compile_workspace(file_path, .{ .execute = execute, .debug = command_args.debug }) catch {
        if (workspace.diagnostics.has_content()) {
            workspace.diagnostics.report_all(io) catch {};
        } else {
            emit_cli_error("The compiler could not complete the requested operation.");
        }
        return 1;
    };

    if (!succeeded) {
        workspace.diagnostics.report_all(io) catch {};
        return 1;
    }

    return 0;
}

pub fn run_file(io: std.Io, parsed_args: []const []const u8, allocator: std.mem.Allocator) u8 {
    return run_compile_command(io, parsed_args, allocator, true);
}

pub fn run_check(io: std.Io, parsed_args: []const []const u8, allocator: std.mem.Allocator) u8 {
    return run_compile_command(io, parsed_args, allocator, false);
}

pub fn get_version(io: std.Io, parsed_args: []const []const u8, allocator: std.mem.Allocator) u8 {
    _ = parsed_args;
    _ = allocator;
    const stdout = std.Io.File.stdout();
    const version = options.version;
    stdout.writeStreamingAll(io, version) catch {
        return 1;
    };
    return 0;
}

pub fn init_project(io: std.Io, parsed_args: []const []const u8, allocator: std.mem.Allocator) u8 {
    const stdout = std.Io.File.stdout();
    if (parsed_args.len == 0 or parsed_args.len > 2) {
        emit_cli_error("Usage: TAPE_lang init [app|pkg] [name]");
        return 1;
    }
    const manifest_type = if (std.mem.eql(u8, "pkg", parsed_args[0]))
        ManifestType.Package
    else if (std.mem.eql(u8, "app", parsed_args[0]))
        ManifestType.Application
    else {
        emit_cli_error("Project kind must be `app` or `pkg`.");
        return 1;
    };
    const new_project_name: []const u8 = if (parsed_args.len == 2) parsed_args[1] else "tape_project";
    create_tape_project(io, allocator, new_project_name, manifest_type) catch {
        stdout.writeStreamingAll(io, "Failed to initialize TAPE project.\n") catch {};
        return 1;
    };
    stdout.writeStreamingAll(io, "Initialized a new TAPE project.\n") catch {
        return 1;
    };
    return 0;
}

pub fn get_help(io: std.Io, parsed_args: []const []const u8, allocator: std.mem.Allocator) u8 {
    _ = parsed_args;
    _ = allocator;
    const stdout = std.Io.File.stdout();

    stdout.writeStreamingAll(io, "Usage: TAPE <command> [args]\n\n") catch {};
    stdout.writeStreamingAll(io, "Available commands:\n") catch {};
    stdout.writeStreamingAll(io, "\n") catch {};
    stdout.writeStreamingAll(io, "Command\t\tArgs\n\n") catch {};

    var longest_command_args: usize = 0;

    for (commands) |command| {
        longest_command_args = if (longest_command_args > command.options.len) longest_command_args else command.options.len;
    }

    for (commands) |command| {
        var args_printed: usize = 0;
        for (command.options) |option| {
            switch (option) {
                .optional_keyword => |keyword| {
                    stdout.writeStreamingAll(io, "?") catch {};
                    stdout.writeStreamingAll(io, keyword) catch {};
                },
                .required_keyword => |keyword| {
                    stdout.writeStreamingAll(io, keyword) catch {};
                },
                .optional_value => |value| {
                    stdout.writeStreamingAll(io, "?") catch {};
                    stdout.writeStreamingAll(io, value) catch {};
                },
                .required_value => |value| {
                    stdout.writeStreamingAll(io, value) catch {};
                },
                .required_choice => |value| {
                    stdout.writeStreamingAll(io, "[ ") catch {};
                    for (value, 0..) |choice, i| {
                        stdout.writeStreamingAll(io, choice) catch {};
                        if (i != value.len - 1) {
                            stdout.writeStreamingAll(io, " | ") catch {};
                        }
                    }
                    stdout.writeStreamingAll(io, " ]") catch {};
                },
            }
            args_printed += 1;
            if (args_printed != longest_command_args) {
                stdout.writeStreamingAll(io, "\t\t") catch {};
            } else {
                stdout.writeStreamingAll(io, "\t") catch {};
            }
        }
        if (args_printed == 0) {
            stdout.writeStreamingAll(io, "<none>") catch {};
        }
        if (args_printed < longest_command_args) {
            const to_print = longest_command_args - args_printed;
            for (0..to_print) |_| {
                stdout.writeStreamingAll(io, "\t\t") catch {};
            }
        }

        stdout.writeStreamingAll(io, command.description) catch {};
        stdout.writeStreamingAll(io, "\n") catch {};
    }
    stdout.writeStreamingAll(io, "\nrun and check accept: --debug, --debug-ast, --debug-bytecode, --debug-vm, --debug-pipeline\n") catch {};
    return 0;
}

/// Runs the TAPE CLI with the given arguments.
pub fn cli_main(args: []const []const u8, allocator: std.mem.Allocator, io: std.Io) u8 {
    if (args.len == 1) {
        return run_repl(io, &.{}, allocator);
    }

    const command = args[1];
    const command_args = args[2..];
    if (std.mem.eql(u8, command, "run")) return run_file(io, command_args, allocator);
    if (std.mem.eql(u8, command, "check")) return run_check(io, command_args, allocator);
    if (std.mem.eql(u8, command, "init")) return init_project(io, command_args, allocator);
    if (std.mem.eql(u8, command, "repl")) return run_repl(io, command_args, allocator);
    if (std.mem.eql(u8, command, "version") or std.mem.eql(u8, command, "-v")) return get_version(io, command_args, allocator);
    if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "-h") or std.mem.eql(u8, command, "--help")) return get_help(io, command_args, allocator);

    emit_cli_error("Invalid command. Use `TAPE_lang help` for usage.");
    return 1;
}
