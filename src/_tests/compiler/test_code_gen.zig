const std = @import("std");
const BindingResolver = @import("../../compiler/binding_resolver.zig").BindingResolver;
const CodeGenerator = @import("../../compiler/code_gen.zig").CodeGenerator;
const Environment = @import("../../compiler/environment.zig").Environment;
const Module = @import("../../compiler/workspace.zig").Module;
const Opcode = @import("../../runtime/chunk.zig").Opcode;
const Parser = @import("../../compiler/parser.zig").Parser;
const TypeChecker = @import("../../compiler/type_checker.zig").TypeChecker;
const TypeRegistry = @import("../../compiler/type_registry.zig").TypeRegistry;
const VM = @import("../../runtime/vm.zig").VM;
const Workspace = @import("../../compiler/workspace.zig").Workspace;

fn generateSource(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test", source, allocator, true);
    defer {
        mod.deinit();
        allocator.destroy(mod);
    }

    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    mod.ast = try parser.parse();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    var env = Environment.init(allocator, null);
    defer env.deinit();

    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(mod.ast);

    mod.binding_resolution.deinit();
    mod.binding_resolution = try BindingResolver.resolve(allocator, &registry, &workspace.diagnostics, mod, &workspace, mod.ast);

    const vm = try VM.init(.{}, &workspace, allocator);
    defer vm.deinit();
    const isolate = try vm.new_isolate(mod.binding_resolution.globals_count, mod.binding_resolution.function_constants_count);

    var codeGenerator = try CodeGenerator.init(allocator, isolate, &mod.binding_resolution, &registry, mod.ast, &workspace.diagnostics, mod);
    const function = codeGenerator.generate() orelse return error.CodeGenerationFailed;
    return try allocator.dupe(u8, function.chunk.code.items);
}

fn expectOpcode(source: []const u8, opcode: Opcode) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const code = try generateSource(arena.allocator(), source);
    for (code) |byte| {
        if (byte == @backingInt(opcode)) return;
    }

    return error.ExpectedOpcodeNotFound;
}

test "Code Generator - emits collection index opcodes" {
    try expectOpcode("var x = [1, 2][0];", .OP_INDEX_ARRAY);
    try expectOpcode("var x = \"ab\"[0];", .OP_INDEX_STRING);
    try expectOpcode("var x = {\"a\": 1}[\"a\"];", .OP_INDEX_TABLE);
    try expectOpcode("var x = (1, true).0;", .OP_INDEX_TUPLE);
}

test "Code Generator - emits collection index assignment opcodes" {
    try expectOpcode("var xs: Array[Int] = [1, 2]; xs[0] = 3;", .OP_SET_INDEX_ARRAY);
    try expectOpcode("var values: Table[String, Int] = {\"a\": 1}; values[\"a\"] += 2;", .OP_SET_INDEX_TABLE);
    try expectOpcode("var xs: Array[Int] = [1, 2]; xs[0] += 3;", .OP_DUP_TWO);
}

test "Code Generator - emits coroutine creation and resume opcodes" {
    // the coroutine body compiles into its own chunk (OP_YIELD lives there);
    // the top-level chunk carries OP_COROUTINE and OP_RESUME
    try expectOpcode("co f() -> (Int, Nil, Int) { yield 1; return 1; } var c = f(); resume c;", .OP_COROUTINE);
    try expectOpcode("co f() -> (Int, Nil, Int) { yield 1; return 1; } var c = f(); resume c;", .OP_RESUME);
    try expectOpcode("co f() -> (String, String, String) { var r = yield \"yo\"; return r; } var c = f(); var x = resume c with \"hi\";", .OP_RESUME);
    try expectOpcode("co f() -> (Int, Int, Int) { var r = yield 1; return r; } var c = f(); var x = resume c with 5;", .OP_RESUME);
}
