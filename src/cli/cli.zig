const std = @import("std");

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
    handler: *const fn (io: std.Io, [][]const u8) anyerror!void,
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

pub fn run_repl(io: std.Io, parsed_args: [][]const u8) anyerror!void {
    _ = parsed_args;
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();
    _ = stdin;
    try stdout.writeStreamingAll(io, "This is the TAPE REPL. Type 'exit' to quit.");
}

pub fn run_file(io: std.Io, parsed_args: [][]const u8) anyerror!void {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();
    _ = stdin;
    try stdout.writeStreamingAll(io, "Run a file");
    for (parsed_args) |arg| {
        try stdout.writeStreamingAll(io, arg);
    }
}

pub fn run_check(io: std.Io, parsed_args: [][]const u8) anyerror!void {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();
    _ = stdin;
    try stdout.writeStreamingAll(io, "Run the parser and type checker.");
    for (parsed_args) |arg| {
        try stdout.writeStreamingAll(io, arg);
    }
}

pub fn get_version(io: std.Io, parsed_args: [][]const u8) anyerror!void {
    _ = parsed_args;
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();
    _ = stdin;
    try stdout.writeStreamingAll(io, "Get the version of TAPE.");
}

pub fn init_project(io: std.Io, parsed_args: [][]const u8) anyerror!void {
    const stdout = std.Io.File.stdout();
    const stdin = std.Io.File.stdin();
    _ = stdin;
    try stdout.writeStreamingAll(io, "Init a new TAPE project.");
    for (parsed_args) |arg| {
        try stdout.writeStreamingAll(io, arg);
    }
}

pub fn get_help(io: std.Io, parsed_args: [][]const u8) anyerror!void {
    _ = parsed_args;
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
            try stdout.writeStreamingAll(io, "<nil>");
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
        return try run_repl(io, parsed_args.items);
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
        try cmd.handler(io, parsed_args.items);
    } else {
        return CliError.InvalidCommand;
    }
}
