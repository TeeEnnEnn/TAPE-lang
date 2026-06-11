const std = @import("std");
const Io = std.Io;

const TAPE_lang = @import("TAPE_lang");
const cli = TAPE_lang.cli;

pub fn main(init: std.process.Init) u8 {
    const args = std.process.Args.toSlice(init.minimal.args, init.arena.allocator()) catch {
        return 1;
    };
    return cli.cli_main(args, init.arena.allocator(), init.io);
}
