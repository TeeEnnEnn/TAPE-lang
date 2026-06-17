const std = @import("std");
const options = @import("TAPE_lang_build_options");
const helpers = @import("helpers.zig");

const TapeScanner = @import("../compiler/scanner.zig");
const TapeParser = @import("../compiler/parser.zig");
const TapeTypeChecker = @import("../compiler/type_checker.zig");
const TapeEnvironment = @import("../compiler/environment.zig");
const TapeTypeRegistry = @import("../compiler/type_registry.zig");
const TapeDiagnostics = @import("../helpers/diagnostics.zig");
const TapeWorkspace = @import("../compiler/workspace.zig");

const RESET = helpers.RESET;
const BOLD_RED = helpers.BOLD_RED;
const RED = helpers.RED;
const YELLOW = helpers.YELLOW;
const GRAY = helpers.GRAY;

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
};

const Command = struct {
    /// The name of the command.
    name: []const u8,
    /// The description of the command.
    description: []const u8,
    /// The handler function for the command.
    handler: *const fn (io: std.Io, [][]const u8, allocator: std.mem.Allocator) u8,
    /// The options of the command. The arguments needed to execute the command.
    options: []const CommandOption,
};

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
        .options = &[_]CommandOption{ CommandOption{ .required_keyword = "init" }, CommandOption{ .optional_value = "name" } },
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

pub fn run_repl(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) u8 {
    _ = parsed_args;
    const stdout = std.Io.File.stdout();
    _ = allocator;
    stdout.writeStreamingAll(io, "This is the TAPE REPL. Type 'exit' to quit.") catch {
        return 1;
    };
    return 0;
}

// TODO: run_flatten
// The flatten command flattens the pkg directory that might contain nested packages. into a flat directory structure.
// if conflicting packages are found the flatten command will error and force the user to resolve the conflicts before continuing.
// execution only works if the pkg directory is flat.

pub fn run_file(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) u8 {
    const stdout = std.Io.File.stdout();
    _ = allocator;
    stdout.writeStreamingAll(io, "Run a file") catch {
        return 1;
    };
    for (parsed_args) |arg| {
        stdout.writeStreamingAll(io, arg) catch {
            return 1;
        };
    }
    return 0;
}

pub fn run_check(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) u8 {
    var workspace = TapeWorkspace.Workspace.init(allocator, io);

    const file_path = if (parsed_args.len == 0) blk: {
        break :blk helpers.get_package_entrypoint(allocator, std.Io.Dir.cwd(), io) catch {
            return 1;
        };
    } else blk: {
        const current_dir = helpers.get_current_dir_path(io, allocator) catch {
            return 1;
        };
        defer allocator.free(current_dir);
        break :blk std.fs.path.join(allocator, &.{ current_dir, parsed_args[0] }) catch {
            return 1;
        };
    };
    defer allocator.free(file_path);

    workspace.compile_workspace(file_path) catch {
        return 1;
    };

    // const file_contents = helpers.read_file(file_path, std.Io.Dir.cwd(), io, allocator) catch {
    //     return 1;
    // };
    // defer allocator.free(file_contents);

    // var diagnostics = TapeDiagnostics.DiagnosticsReporter.init(allocator);
    // defer diagnostics.deinit();

    // var parser = TapeParser.Parser.init(allocator, file_contents, &diagnostics, file_path) catch {
    //     if (diagnostics.has_errors) {
    //         diagnostics.report_all(io) catch {};
    //     }
    //     return 1;
    // };
    // const program = parser.parse() catch {
    //     if (diagnostics.has_errors) {
    //         diagnostics.report_all(io) catch {};
    //     }
    //     return 1;
    // };

    // var env = TapeEnvironment.Environment.init(allocator, null);
    // defer env.deinit();
    // var registry = TapeTypeRegistry.TypeRegistry.init(allocator) catch {
    //     return 1;
    // };
    // defer registry.deinit();
    // var checker = TapeTypeChecker.TypeChecker.init(allocator, &registry, &env, &diagnostics, file_path);
    // _ = checker.check(program) catch |err| {
    //     if (!diagnostics.has_errors) {
    //         diagnostics.add_diagnostic(.{
    //             .stage = .TypeChecker,
    //             .severity = .Error,
    //             .message = @errorName(err),
    //             .file_path = file_path,
    //             .line = 0,
    //             .column = 0,
    //         }) catch {};
    //     }
    //     diagnostics.report_all(io) catch {};
    //     return 1;
    // };
    return 0;
}

pub fn get_version(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) u8 {
    _ = parsed_args;
    _ = allocator;
    const stdout = std.Io.File.stdout();
    const version = options.version;
    stdout.writeStreamingAll(io, version) catch {
        return 1;
    };
    return 0;
}

pub fn init_project(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) u8 {
    const stdout = std.Io.File.stdout();
    var new_project_name: []const u8 = "tape_project";
    if (parsed_args.len > 0) {
        new_project_name = parsed_args[0];
    }
    helpers.create_tape_project(io, allocator, new_project_name) catch {
        stdout.writeStreamingAll(io, "Failed to initialize TAPE project.\n") catch {};
        return 1;
    };
    stdout.writeStreamingAll(io, "Initialized a new TAPE project.\n") catch {
        return 1;
    };
    return 0;
}

pub fn get_help(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) u8 {
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
                    stdout.writeStreamingAll(io, "\t\t") catch {};
                },
                .required_keyword => |keyword| {
                    stdout.writeStreamingAll(io, keyword) catch {};
                    stdout.writeStreamingAll(io, "\t\t") catch {};
                },
                .optional_value => |value| {
                    stdout.writeStreamingAll(io, "?") catch {};
                    stdout.writeStreamingAll(io, value) catch {};
                    stdout.writeStreamingAll(io, "\t\t") catch {};
                },
                .required_value => |value| {
                    stdout.writeStreamingAll(io, value) catch {};
                    stdout.writeStreamingAll(io, "\t\t") catch {};
                },
            }
            args_printed += 1;
        }
        if (args_printed == 0) {
            stdout.writeStreamingAll(io, "<none>") catch {};
        }
        if (args_printed < longest_command_args) {
            for (0..(longest_command_args - args_printed)) |_| {
                stdout.writeStreamingAll(io, "\t\t") catch {};
            }
        }

        stdout.writeStreamingAll(io, command.description) catch {};
        stdout.writeStreamingAll(io, "\n") catch {};
    }
    return 0;
}

/// Runs the TAPE CLI with the given arguments.
pub fn cli_main(args: []const []const u8, allocator: std.mem.Allocator, io: std.Io) u8 {
    const stdout = std.Io.File.stdout();
    var possible_commands: std.ArrayList(Command) = .empty;
    defer possible_commands.deinit(allocator);
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, "repl")) {
            continue; // skip the repl command
        }
        possible_commands.append(allocator, command) catch {
            return 1;
        };
    }

    // check all of the possible commands against the args.
    // Loop through the args removing the commands that do not match.
    // At the end the remaining command is the one to run.
    //
    // If there are multiple commands at the end of the args, return an error.
    //
    // If there are no commands at the end of the args, return an error.

    var parsed_args: std.ArrayList([]const u8) = .empty;
    defer parsed_args.deinit(allocator);
    if (args.len == 1) {
        return run_repl(io, parsed_args.items, allocator);
    }

    var selected_command: ?Command = null;

    for (args, 0..) |arg, i| {
        if (i == 0) {
            continue; // skip the program path
        }

        var write_index: usize = 0;
        const current_commands = possible_commands.items;
        var arg_is_value = false;

        for (possible_commands.items) |command| {
            if (command.options.len < i) continue;

            const option = command.options[i - 1];
            var match = false;

            switch (option) {
                .optional_keyword => |keyword| {
                    if (std.mem.eql(u8, arg, keyword)) {
                        match = true;
                    }
                },
                .required_keyword => |keyword| {
                    if (std.mem.eql(u8, arg, keyword)) {
                        match = true;
                    }
                },
                .optional_value, .required_value => {
                    match = true;
                    arg_is_value = true;
                },
            }

            if (match) {
                current_commands[write_index] = command;
                write_index += 1;
            }
        }

        if (arg_is_value) {
            parsed_args.append(allocator, arg) catch {
                return 1;
            };
        }

        possible_commands.shrinkAndFree(allocator, write_index);
    }
    if (possible_commands.items.len == 1) {
        selected_command = possible_commands.items[0];
    } else if (possible_commands.items.len > 1) { // Can't tell what the user wants to do
        stdout.writeStreamingAll(io, RED ++ "Error: " ++ RESET ++ "Ambiguous command. -h for help.\n") catch {};
        return 1;
    }

    if (selected_command) |cmd| {
        return cmd.handler(io, parsed_args.items, allocator);
    } else {
        stdout.writeStreamingAll(io, RED ++ "Error: " ++ RESET ++ "Invalid command. -h for help.\n") catch {};
        return 1;
    }
    return 0;
}
