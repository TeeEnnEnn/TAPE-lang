const std = @import("std");
const options = @import("TAPE_lang_build_options");
const helpers = @import("helpers.zig");

const TapeScanner = @import("../compiler/scanner.zig");
const TapeParser = @import("../compiler/parser.zig");
const TapeTypeChecker = @import("../compiler/type_checker.zig");
const TapeEnvironment = @import("../compiler/environment.zig");
const TapeTypeRegistry = @import("../compiler/type_registry.zig");
const TapeDiagnostics = @import("../helpers/diagnostics.zig");

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
    handler: *const fn (io: std.Io, [][]const u8, allocator: std.mem.Allocator) anyerror!void,
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

pub fn run_repl(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) anyerror!void {
    _ = parsed_args;
    const stdout = std.Io.File.stdout();
    _ = allocator;
    try stdout.writeStreamingAll(io, "This is the TAPE REPL. Type 'exit' to quit.");
}

// TODO: run_flatten
// The flatten command flattens the pkg directory that might contain nested packages. into a flat directory structure.
// if conflicting packages are found the flatten command will error and force the user to resolve the conflicts before continuing.
// execution only works if the pkg directory is flat.

pub fn run_file(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) anyerror!void {
    const stdout = std.Io.File.stdout();
    _ = allocator;
    try stdout.writeStreamingAll(io, "Run a file");
    for (parsed_args) |arg| {
        try stdout.writeStreamingAll(io, arg);
    }
}

pub fn run_check(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) anyerror!void {
    const file_path = if (parsed_args.len == 0) blk: {
        break :blk try helpers.get_package_entrypoint(allocator, std.Io.Dir.cwd(), io);
    } else blk: {
        const relative_path = parsed_args[0];
        const current_dir = try helpers.get_current_dir_path(io, allocator);
        defer allocator.free(current_dir);
        break :blk try std.fs.path.join(allocator, &.{ current_dir, relative_path });
    };
    defer allocator.free(file_path);

    const file_contents = try helpers.read_file(file_path, std.Io.Dir.cwd(), io, allocator);
    defer allocator.free(file_contents);

    var diagnostics = TapeDiagnostics.DiagnosticsReporter.init(allocator);
    defer diagnostics.deinit();

    var parser = try TapeParser.Parser.init(allocator, file_contents, &diagnostics, file_path);
    const program = parser.parse() catch {
        if (diagnostics.has_errors) {
            try diagnostics.report_all(io);
        }
        return error.CompilationError;
    };

    var env = TapeEnvironment.Environment.init(allocator, null, &diagnostics, file_path);
    defer env.deinit();
    var registry = try TapeTypeRegistry.TypeRegistry.init(allocator, &diagnostics, file_path);
    defer registry.deinit();
    var checker = TapeTypeChecker.TypeChecker.init(allocator, &registry, &env, &diagnostics, file_path);
    _ = checker.check(program) catch {
        if (diagnostics.has_errors) {
            try diagnostics.report_all(io);
        }
        return error.CompilationError;
    };
}

pub fn get_version(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) anyerror!void {
    _ = parsed_args;
    _ = allocator;
    const stdout = std.Io.File.stdout();
    const version = options.version;
    try stdout.writeStreamingAll(io, version);
}

pub fn init_project(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) anyerror!void {
    const stdout = std.Io.File.stdout();
    var new_project_name: []const u8 = "tape_project";
    if (parsed_args.len > 0) {
        new_project_name = parsed_args[0];
    }
    helpers.create_tape_project(io, allocator, new_project_name) catch {
        try stdout.writeStreamingAll(io, "Failed to initialize TAPE project.\n");
        return;
    };
    try stdout.writeStreamingAll(io, "Initialized a new TAPE project.");
}

pub fn get_help(io: std.Io, parsed_args: [][]const u8, allocator: std.mem.Allocator) anyerror!void {
    _ = parsed_args;
    _ = allocator;
    const stdout = std.Io.File.stdout();

    try stdout.writeStreamingAll(io, "Usage: TAPE <command> [args]\n\n");
    try stdout.writeStreamingAll(io, "Available commands:\n");

    try stdout.writeStreamingAll(io, "\n");

    try stdout.writeStreamingAll(io, "Command\t\tArgs\n\n");

    var longest_command_args: usize = 0;

    for (commands) |command| {
        longest_command_args = if (longest_command_args > command.options.len) longest_command_args else command.options.len;
    }

    for (commands) |command| {
        var args_printed: usize = 0;
        // Print arguments
        for (command.options) |option| {
            switch (option) {
                .optional_keyword => |keyword| {
                    try stdout.writeStreamingAll(io, "?");
                    try stdout.writeStreamingAll(io, keyword);
                    try stdout.writeStreamingAll(io, "\t\t");
                },
                .required_keyword => |keyword| {
                    try stdout.writeStreamingAll(io, keyword);
                    try stdout.writeStreamingAll(io, "\t\t");
                },
                .optional_value => |value| {
                    try stdout.writeStreamingAll(io, "?");
                    try stdout.writeStreamingAll(io, value);
                    try stdout.writeStreamingAll(io, "\t\t");
                },
                .required_value => |value| {
                    try stdout.writeStreamingAll(io, value);
                    try stdout.writeStreamingAll(io, "\t\t");
                },
            }
            args_printed += 1;
        }
        if (args_printed == 0) {
            try stdout.writeStreamingAll(io, "<none>");
        }
        if (args_printed < longest_command_args) {
            for (0..(longest_command_args - args_printed)) |_| {
                try stdout.writeStreamingAll(io, "\t\t");
            }
        }

        try stdout.writeStreamingAll(io, command.description);
        try stdout.writeStreamingAll(io, "\n");
    }
}

/// Runs the TAPE CLI with the given arguments.
pub fn cli_main(args: []const []const u8, allocator: std.mem.Allocator, io: std.Io) anyerror!void {
    var possible_commands: std.ArrayList(Command) = .empty;
    defer possible_commands.deinit(allocator);
    for (commands) |command| {
        if (std.mem.eql(u8, command.name, "repl")) {
            continue; // skip the repl command
        }
        try possible_commands.append(allocator, command);
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
        return try run_repl(io, parsed_args.items, allocator);
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
            try parsed_args.append(allocator, arg);
        }

        possible_commands.shrinkAndFree(allocator, write_index);
    }
    if (possible_commands.items.len == 1) {
        selected_command = possible_commands.items[0];
    } else if (possible_commands.items.len > 1) { // Can't tell what the user wants to do
        return CliError.AmbiguousCommand;
    }

    if (selected_command) |cmd| {
        try cmd.handler(io, parsed_args.items, allocator);
    } else {
        return CliError.InvalidCommand;
    }
}
