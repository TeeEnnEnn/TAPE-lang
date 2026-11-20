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
