const std = @import("std");
const BindingResolver = @import("../../compiler/binding_resolver.zig").BindingResolver;
const CodeGenerator = @import("../../compiler/code_gen.zig").CodeGenerator;
const Environment = @import("../../compiler/environment.zig").Environment;
const Module = @import("../../compiler/workspace.zig").Module;
const Parser = @import("../../compiler/parser.zig").Parser;
const TypeChecker = @import("../../compiler/type_checker.zig").TypeChecker;
const TypeRegistry = @import("../../compiler/type_registry.zig").TypeRegistry;
const VM = @import("../../runtime/vm.zig").VM;
const RuntimePanic = @import("../../runtime/vm.zig").RuntimePanic;
const Workspace = @import("../../compiler/workspace.zig").Workspace;
const Entities = @import("../../runtime/entities.zig");

/// Compiles and runs `source` as an entrypoint script. Panics propagate as
/// errors so tests can assert on them.
fn runSource(allocator: std.mem.Allocator, source: []const u8) !void {
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

    var code_generator = try CodeGenerator.init(allocator, isolate, &mod.binding_resolution, &registry, mod.ast, &workspace.diagnostics, mod);
    const function = code_generator.generate() orelse return error.CodeGenerationFailed;

    isolate.isolate_closure = try Entities.new_closure_object(isolate, function);
    isolate.gc.activate_collector();
    _ = try isolate.execute();
}

test "Optional unwrap - a present value passes through unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try runSource(allocator,
        \\var m: ?Int = 41;
        \\if (1 + m.? != 42) { panic "unwrap should yield 41"; }
    );

    // Structural inner types survive the unwrap too.
    try runSource(allocator,
        \\struct P { pub value: Int }
        \\var box: ?P = new P { value = 7 };
        \\if (box.?.value != 7) { panic "field access after unwrap"; }
        \\var xs: ?Array[Int] = [3, 4];
        \\if (xs.?[1] != 4) { panic "index after unwrap"; }
    );
}

test "give returns values from expression blocks and if expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try runSource(allocator,
        \\var x = {
        \\  var a = 10;
        \\  if (a > 5) { give a * 2; }
        \\  give a;
        \\};
        \\if (x != 20) { panic "statement if did not give to its enclosing block"; }
        \\var y = if (x == 20) { var tmp = 1; give tmp + 1; } else { give 0; };
        \\if (y != 2) { panic "if expression result was incorrect"; }
        \\var maybe = if (false) { give 42; } else { give nil; };
        \\if (maybe != nil) { panic "nil arm should widen result to optional"; }
    );

    try runSource(allocator,
        \\fn cleanup() -> Int {
        \\  var x = 1;
        \\  var result = { defer { x = 9; } give 4; };
        \\  return x + result;
        \\}
        \\if (cleanup() != 13) { panic "give did not run deferred cleanup"; }
    );
}

test "Optional unwrap - unwrapping nil panics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(
        RuntimePanic.FailedOptionalUnwrap,
        runSource(allocator,
            \\var m: ?Int = nil;
            \\var x = m.?;
        ),
    );

    try std.testing.expectError(
        RuntimePanic.FailedOptionalUnwrap,
        runSource(allocator,
            \\fn missing() -> ?Int { return nil; }
            \\var x = missing().?;
        ),
    );
}

test "defer and errdefer run in LIFO order on the matching exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try runSource(allocator,
        \\fn deferred_value() -> Array[Int] {
        \\    var values = [0];
        \\    defer { values[0] = values[0] * 10 + 1; }
        \\    defer { values[0] = values[0] * 10 + 2; }
        \\    return values;
        \\}
        \\if (deferred_value()[0] != 21) { panic "defer order or return cleanup failed"; }
        \\fn increment(values: Array[Int]) -> Nil { values[0] += 1; }
        \\fn deferred_call() -> Array[Int] {
        \\    var values = [0];
        \\    defer increment(values);
        \\    return values;
        \\}
        \\if (deferred_call()[0] != 1) { panic "deferred call did not run"; }
        \\fn deferred_local() -> Array[Int] {
        \\    var values = [0];
        \\    var visible = 7;
        \\    defer { var temporary = [visible]; values[0] = temporary[0]; }
        \\    var later_local = 99;
        \\    return values;
        \\}
        \\if (deferred_local()[0] != 7) { panic "defer local slots overlapped live locals"; }
        \\fn conditional(flag: Bool) -> Array[Int] {
        \\    var values = [0];
        \\    if (flag) defer { values[0] = 1; }
        \\    return values;
        \\}
        \\if (conditional(false)[0] != 0 or conditional(true)[0] != 1) { panic "conditional defer registration failed"; }
        \\fn capture_defer() -> Array[Int] {
        \\    var values: ?Array[Int] = [0];
        \\    if (values) bind (captured) defer { captured[0] = 4; }
        \\    return values.?;
        \\}
        \\if (capture_defer()[0] != 4) { panic "capture scope defer failed"; }
        \\fn loop_defer() -> Array[Int] {
        \\    var values = [0];
        \\    var index = 0;
        \\    while (index < 2) {
        \\        defer { values[0] += 1; }
        \\        index += 1;
        \\    }
        \\    return values;
        \\}
        \\if (loop_defer()[0] != 2) { panic "loop defer scope failed"; }
        \\fn break_defer() -> Array[Int] {
        \\    var values = [0];
        \\    while (true) {
        \\        defer { values[0] = 3; }
        \\        break;
        \\    }
        \\    return values;
        \\}
        \\if (break_defer()[0] != 3) { panic "break did not run defer"; }
        \\error E { Bad }
        \\fn fail() -> E!Int { return E.Bad; }
        \\fn error_path() -> Array[Int] {
        \\    var values = [0];
        \\    fn inner() -> E!Int {
        \\        errdefer { values[0] = values[0] * 10 + 1; }
        \\        defer { values[0] = values[0] * 10 + 2; }
        \\        return try fail();
        \\    }
        \\    var ignored = inner() catch 0;
        \\    return values;
        \\}
        \\if (error_path()[0] != 21) { panic "defer and errdefer did not run on try propagation"; }
        \\fn success_path() -> Array[Int] {
        \\    var values = [0];
        \\    errdefer { values[0] = 1; }
        \\    defer { values[0] = 2; }
        \\    return values;
        \\}
        \\if (success_path()[0] != 2) { panic "errdefer ran on success or defer did not run"; }
    );
}
