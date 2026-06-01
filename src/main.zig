const std = @import("std");
const Io = std.Io;

const TAPE_lang = @import("TAPE_lang");
const cli = TAPE_lang.cli;

pub fn main(init: std.process.Init) !void {
    const args = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());
    _ = try cli.cli_main(args, init.arena.allocator(), init.io);
}
