Things I need to do:

[x] - 2026/10/05: move vm and isolate into their own files
[x] - 2026/10/05: stress gc

[ ] - 2026/10/06: squash gc safety bugs

Crash with log gc + stress gc at examples/basics/anonymous_coroutines.tape

```
General protection exception (no address available)
/home/theo-arch/git/TAPE-lang/src/runtime/isolate.zig:258:76: 0x1245c78 in execution_loop (root.zig)
            const instruction: Opcode = @enumFromInt(frame.closure.function.chunk.code.items[frame.ip]);
                                                                           ^
/home/theo-arch/git/TAPE-lang/src/runtime/isolate.zig:951:55: 0x1253dc4 in execution_loop (root.zig)
                    const result = self.execution_loop(); // resume execution where you left off
                                                      ^
/home/theo-arch/git/TAPE-lang/src/runtime/isolate.zig:222:39: 0x123f9cd in execute (root.zig)
        return try self.execution_loop();
                                      ^
/home/theo-arch/git/TAPE-lang/src/compiler/workspace.zig:331:34: 0x123b51f in compile_workspace (root.zig)
        _ = first_isolate.execute() catch |err| {
                                 ^
/home/theo-arch/git/TAPE-lang/src/cli/cli.zig:374:50: 0x123cdc1 in run_compile_command (root.zig)
    const succeeded = workspace.compile_workspace(file_path, .{ .execute = execute, .debug = command_args.debug }) catch {
                                                 ^
/home/theo-arch/git/TAPE-lang/src/cli/cli.zig:392:31: 0x13d55e7 in run_file (root.zig)
    return run_compile_command(io, parsed_args, allocator, true);
                              ^
/home/theo-arch/git/TAPE-lang/src/cli/cli.zig:512:57: 0x122a349 in cli_main (root.zig)
    if (std.mem.eql(u8, command, "run")) return run_file(io, command_args, allocator);
                                                        ^
/home/theo-arch/git/TAPE-lang/src/main.zig:11:24: 0x122a074 in main (main.zig)
    return cli.cli_main(args, init.arena.allocator(), init.io);
                       ^
/home/theo-arch/.zvm/0.16.0/lib/std/start.zig:737:30: 0x1224a53 in callMain (std.zig)
    return wrapMain(root.main(.{
                             ^
/home/theo-arch/.zvm/0.16.0/lib/std/start.zig:190:5: 0x12240e1 in _start (std.zig)
    asm volatile (switch (native_arch) {
    ^
./scripts/run_examples.sh: line 31: 84525 Aborted                    (core dumped) ./zig-out/bin/TAPE_lang run "$f"
```


[ ] - 2026/10/07: allow anonymous functions at declaration position

[ ] - Remove the ability for functions to capture global scope
	[ ] - Remove the ability for functions to capture global mutable state - allow constant state iff that state has the same visibility of the function
[ ] - use type checker statement termination to determine whether or not we need to add a return to a function call
