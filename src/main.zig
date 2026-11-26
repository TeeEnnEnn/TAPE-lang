const std = @import("std");
const Io = std.Io;

const CLI = @import("cli/cli.zig");

pub fn main(init: std.process.Init) u8 {
    const program_arena = init.arena.allocator();
    const gpa = init.gpa;
    const args = std.process.Args.toSlice(init.minimal.args, program_arena) catch {
        return 1;
    };
    return CLI.cli_main(args, gpa, init.io);
}
