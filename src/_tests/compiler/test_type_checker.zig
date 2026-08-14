const std = @import("std");
const TypeChecker = @import("../../compiler/type_checker.zig").TypeChecker;
const TypeCheckerError = @import("../../compiler/type_checker.zig").TypeCheckerError;
const Environment = @import("../../compiler/environment.zig").Environment;
const EnvironmentError = @import("../../compiler/environment.zig").EnvironmentError;
const TypeRegistry = @import("../../compiler/type_registry.zig").TypeRegistry;
const TypeId = @import("../../compiler/ast.zig").TypeId;
const Parser = @import("../../compiler/parser.zig").Parser;
const PrimitiveType = @import("../../compiler/type_registry.zig").PrimitiveType;
const DiagnosticsReporter = @import("../../diagnostics/diagnostics.zig").DiagnosticsReporter;
const Workspace = @import("../../compiler/workspace.zig").Workspace;
const Module = @import("../../compiler/workspace.zig").Module;

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !struct { registry: TypeRegistry, env: Environment } {
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();
    const mod = try Module.init("test", source, allocator);

    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    const program = try parser.parse();

    var env = Environment.init(allocator, null);
    var registry = try TypeRegistry.init(allocator);
    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(program);

    return .{ .registry = registry, .env = env };
}

const SourceEntry = struct { name: []const u8, source: []const u8 };

fn checkSourceMulti(allocator: std.mem.Allocator, sources: []const SourceEntry) !void {
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    var modules = std.ArrayList(*Module).empty;
    defer modules.deinit(allocator);

    for (sources) |entry| {
        const mod = try Module.init(entry.name, entry.source, allocator);
        try modules.append(allocator, mod);
        try workspace.modules.put(entry.name, mod);

        var parser = try Parser.init(allocator, &workspace, mod, io, &group);
        mod.ast = try parser.parse();
    }

    var type_registry = try TypeRegistry.init(allocator);
    defer type_registry.deinit();

    for (modules.items) |mod| {
        var env = Environment.init(allocator, null);
        defer env.deinit();
        var checker = TypeChecker.init(allocator, &type_registry, &env, &workspace.diagnostics, mod, &workspace);
        _ = try checker.check(mod.ast);
    }
}

test "Type Checker - Init works" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    const io = std.testing.io;

    var diagnostics = DiagnosticsReporter.init(arena_allocator);
    defer diagnostics.deinit();

    var workspace = Workspace.init(arena_allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test", "", arena_allocator);
    defer mod.deinit();

    var env = Environment.init(arena_allocator, null);
    defer env.deinit();

    var registry = try TypeRegistry.init(arena_allocator);
    defer registry.deinit();

    const type_checker = TypeChecker.init(arena_allocator, &registry, &env, &diagnostics, mod, &workspace);
    _ = type_checker;
}

test "Type Checker - checks typed variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator, "var x: Int = 1;");
    defer result.env.deinit();
    defer result.registry.deinit();

    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), try result.env.lookup("x"));
}

test "Type Checker - rejects mismatched variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "var x: String = 1;"));
}

test "Type Checker - rejects duplicate variable definition" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // should reject duplicate variable definition in the same scope
    try std.testing.expectError(TypeCheckerError.DuplicateSymbol, checkSource(allocator, "var x: Int = 1; var x: String = \"test\";"));
    // should allow duplicate variable definition in different scopes
    var result = try checkSource(allocator, "var test: Int = 1; { var test: String = \"test\"; }");
    defer result.env.deinit();
    defer result.registry.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.env.symbols.count());
}

test "Type Checker - checks function declaration and return type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator, "fn id(x: Int) -> Int { return x; }");
    defer result.env.deinit();
    defer result.registry.deinit();

    const fn_type = result.registry.get_type_info(try result.env.lookup("id"));
    try std.testing.expect(fn_type == .function);
    try std.testing.expectEqual(@as(usize, 1), fn_type.function.args.len);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), fn_type.function.args[0]);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), fn_type.function.ret);
}

test "Type Checker - rejects function return mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "fn bad() -> String { return 1; }"));
}

test "Type Checker - match exhaustiveness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid: exhaustive match on enum with returns
    _ = try checkSource(allocator, "enum Color { Red, Green, Blue } fn f(c: Color) -> Int { match (c) { Color::Red => { return 1; }, Color::Green => { return 2; }, Color::Blue => { return 3; }, }; }");
    // valid: match on non-enum type (no exhaustiveness check needed)
    _ = try checkSource(allocator, "fn f(x: Int) -> Int { match (x) { 1 => { return 10; }, 2 => { return 20; }, }; }");

    // invalid: non-exhaustive match on enum
    try std.testing.expectError(TypeCheckerError.NonExhaustiveMatch, checkSource(allocator, "enum Color { Red, Green, Blue } fn f(c: Color) -> Int { match (c) { Color::Red => { return 1; }, Color::Green => { return 2; }, }; }"));

    // invalid: non-exhaustive match on error
    try std.testing.expectError(TypeCheckerError.NonExhaustiveMatch, checkSource(allocator, "error HttpError { NotFound, Unauthorized } fn f(e: HttpError) -> Int { match (e) { HttpError::NotFound => { return 404; }, }; }"));

    // valid: nested match with give — context isolation
    _ = try checkSource(allocator,
        \\enum Inner { A, B }
        \\enum Outer { X, Y }
        \\fn f(o: Outer) -> Int {
        \\  match (o) {
        \\    Outer::X => {
        \\      match (Inner::A) {
        \\        Inner::A => { give 1; },
        \\        Inner::B => { give 2; },
        \\      };
        \\    },
        \\    Outer::Y => { return 3; },
        \\  };
        \\  return 0;
        \\}
    );
}

test "Type Checker - missing return detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid: explicit return
    _ = try checkSource(allocator, "fn f() -> Int { return 1; }");
    // valid: no return needed for Nil return type
    _ = try checkSource(allocator, "fn f() -> Nil { var x = 1; }");
    // valid: if-else both return
    _ = try checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { return 1; } else { return 2; } }");
    // valid: panic is acceptable
    _ = try checkSource(allocator, "fn f() -> Int { panic \"no\"; }");
    // valid: return in block
    _ = try checkSource(allocator, "fn f() -> Int { { return 1; } }");

    // invalid: missing return
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "fn f() -> Int { var x = 1; }"));
    // invalid: if without else
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { return 1; } }"));
    // invalid: if-else with one branch missing return
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { return 1; } else { var y = 2; } }"));
}

test "Type Checker - compound assignment semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid compound assignments
    _ = try checkSource(allocator, "var x = 1; x += 2;");
    _ = try checkSource(allocator, "var x = 1; x -= 2;");
    _ = try checkSource(allocator, "var x = 1; x *= 2;");
    _ = try checkSource(allocator, "var x = 1; x /= 2;");
    _ = try checkSource(allocator, "var x = 1.0; x += 2.0;");

    // invalid compound assignments
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "var x = true; x += false;"));
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "var x = \"a\"; x += \"b\";"));
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "var x = \"a\"; x -= \"b\";"));
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "var x = \"a\"; x *= \"b\";"));
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "var x = \"a\"; x /= \"b\";"));
}

test "Type Checker - exponentiation with **" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try checkSource(allocator, "var x = 2 ** 3;");
    _ = try checkSource(allocator, "var x = 2.5 ** 1.5;");
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "var x = \"a\" ** \"b\";"));
}

test "Type Checker - checks struct construction and member access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator,
        \\struct Point { x: Int, y: Int }
        \\var p = new Point { x = 1, y = 2 };
        \\var px: Int = p.x;
    );
    defer result.env.deinit();
    defer result.registry.deinit();

    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), try result.env.lookup("px"));
}

test "Type Checker - use declaration validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // invalid: use declaration with undefined symbol
    _ = checkSource(allocator, "use foo from \"mymodule\";") catch |e| {
        if (e != TypeCheckerError.UndefinedSymbol) {
            return e;
        }
    };
}

test "Type Checker - break and continue context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid: break inside while loop
    _ = try checkSource(allocator, "while (true) { break; }");
    // valid: continue inside for loop
    _ = try checkSource(allocator, "var i = 0; while (i < 10) { i += 1; continue; }");
    // valid: break inside nested loops
    _ = try checkSource(allocator, "while (true) { while (true) { break; } break; }");

    // invalid: break outside loop
    try std.testing.expectError(TypeCheckerError.BreakOutsideLoop, checkSource(allocator, "break;"));
    // invalid: continue outside loop
    try std.testing.expectError(TypeCheckerError.ContinueOutsideLoop, checkSource(allocator, "continue;"));
}

test "Type Checker - panic as return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid: panic in place of return
    _ = try checkSource(allocator, "fn f() -> Int { panic \"error\"; }");
    // valid: if-else with panic in one branch and return in the other
    _ = try checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { return 1; } else { panic \"no\"; } }");
    // valid: match with panic cases
    _ = try checkSource(allocator, "enum Color { Red, Green } fn f(c: Color) -> Int { match (c) { Color::Red => { panic \"bad\"; }, Color::Green => { panic \"bad\"; }, }; }");
}

test "Type Checker - if-else return completeness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid: if-else both return
    _ = try checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { return 1; } else { return 2; } }");
    // valid: if-else both panic
    _ = try checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { panic \"a\"; } else { panic \"b\"; } }");
    // valid: nested if-else all return
    _ = try checkSource(allocator, "fn f(x: Bool, y: Bool) -> Int { if (x) { if (y) { return 1; } else { return 2; } } else { return 3; } }");

    // invalid: if without else on non-Nil return
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { return 1; } }"));
    // invalid: if-else with one branch missing return
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { return 1; } else { var y = 2; } }"));
    // invalid: nested if without else
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "fn f(x: Bool, z: Bool) -> Int { if (x) { if (z) { return 1; } } else { return 2; } }"));
}

test "Type Checker - match return completeness" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid: exhaustive match on enum with all returning
    _ = try checkSource(allocator, "enum Color { Red, Green, Blue } fn f(c: Color) -> Int { match (c) { Color::Red => { return 1; }, Color::Green => { return 2; }, Color::Blue => { return 3; }, }; }");
    // valid: match with one case panicking
    _ = try checkSource(allocator, "enum Color { Red, Green } fn f(c: Color) -> Int { match (c) { Color::Red => { return 1; }, Color::Green => { panic \"no\"; }, }; }");
    // valid: non-enum match (no exhaustiveness check needed)
    _ = try checkSource(allocator, "fn f(x: Int) -> Int { match (x) { 1 => { return 10; }, 2 => { return 20; }, }; return 0; }");

    // invalid: match case uses give not return — function missing return
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "enum Color { Red, Green } fn f(c: Color) -> Int { match (c) { Color::Red => { give 1; }, Color::Green => { give 2; }, }; }"));
}

test "Type Checker - block termination" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // valid: block with final return
    _ = try checkSource(allocator, "fn f() -> Int { { return 1; } }");
    // valid: block inside if-else returning
    _ = try checkSource(allocator, "fn f(x: Bool) -> Int { if (x) { { return 1; } } else { { return 2; } } }");
    // valid: nested blocks
    _ = try checkSource(allocator, "fn f() -> Int { { { return 1; } } }");
}

test "Type Checker - pub const is exported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test_pub_const", "pub const x: Int = 42;", allocator);
    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    mod.ast = try parser.parse();

    var env = Environment.init(allocator, null);
    defer env.deinit();
    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(mod.ast);

    const export_entry = mod.exports.get("x");
    try std.testing.expect(export_entry != null);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), export_entry.?);
}

test "Type Checker - pub fn is exported and importable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try checkSourceMulti(allocator, &.{
        SourceEntry{ .name = "lib", .source = "pub fn foo() -> Int { return 1; }" },
        SourceEntry{ .name = "main", .source = "use foo from \"lib\"; var x = foo();" },
    });
}

test "Type Checker - pub co is exported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test_co", "pub co bar() -> (Int, Nil) { yield 1; }", allocator);
    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    mod.ast = try parser.parse();

    var env = Environment.init(allocator, null);
    defer env.deinit();
    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(mod.ast);

    const export_entry = mod.exports.get("bar");
    try std.testing.expect(export_entry != null);
}

test "Type Checker - pub struct is exported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test_struct", "pub struct Point { x: Int, y: Int }", allocator);
    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    mod.ast = try parser.parse();

    var env = Environment.init(allocator, null);
    defer env.deinit();
    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(mod.ast);

    const export_entry = mod.exports.get("Point");
    try std.testing.expect(export_entry != null);
}

test "Type Checker - pub enum is exported" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test_enum", "pub enum Color { Red, Green }", allocator);
    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    mod.ast = try parser.parse();

    var env = Environment.init(allocator, null);
    defer env.deinit();
    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(mod.ast);

    const export_entry = mod.exports.get("Color");
    try std.testing.expect(export_entry != null);
}

test "Type Checker - use_decl errors on non-exported symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.UndefinedSymbol, checkSourceMulti(allocator, &.{
        SourceEntry{ .name = "lib", .source = "fn secret() -> Int { return 0; }" },
        SourceEntry{ .name = "main", .source = "use secret from \"lib\"; var x = secret();" },
    }));
}

test "Type Checker - pub const import via use_decl hoist looks up from exports map" {
    // Verify that use_decl hoist looks up symbols from the imported module's exports map,
    // not from registry.get_named_type (which only finds structs/enums/errors).
    // This test simulates the multi-module scenario using the TypeChecker directly.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    // Create and process the "lib" module with a pub var
    const lib_mod = try Module.init("lib", "pub const x: Int = 42;", allocator);
    var group = std.Io.Group.init;
    var parser = try Parser.init(allocator, &workspace, lib_mod, io, &group);
    lib_mod.ast = try parser.parse();
    try workspace.modules.put("lib", lib_mod);

    var type_registry = try TypeRegistry.init(allocator);
    defer type_registry.deinit();

    // Hoist and check lib module to populate its exports
    {
        var env = Environment.init(allocator, null);
        defer env.deinit();
        var checker = TypeChecker.init(allocator, &type_registry, &env, &workspace.diagnostics, lib_mod, &workspace);
        _ = try checker.check(lib_mod.ast);
    }

    // Verify the pub var was exported
    try std.testing.expect(lib_mod.exports.contains("x"));
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), lib_mod.exports.get("x").?);

    // Now simulate what use_decl hoist does: look up from lib's exports
    // and define in the importing module's environment
    var import_env = Environment.init(allocator, null);
    defer import_env.deinit();

    if (workspace.modules.get("lib")) |imported| {
        if (imported.exports.get("x")) |resolved_id| {
            try import_env.define("x", resolved_id);
        } else {
            return error.TestFailed;
        }
    } else {
        return error.TestFailed;
    }

    // Verify the imported symbol is usable (its type ID is correct)
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), try import_env.lookup("x"));
}

test "Functions cannot read global mutable state" {
    const allocator = std.testing.allocator;
    var result = checkSource(allocator, "var capture = 11; fn f() -> Int { return capture + 1; }") catch |err| {
        switch (err) {
            TypeCheckerError.MutableGlobalStateCaptureAttempt => return, // expected
            else => return err,
        }
    };
    result.env.deinit();
    result.registry.deinit();
    return error.TestExpectedError;
}

test "Functions cannot write global mutable state" {
    const allocator = std.testing.allocator;
    var result = checkSource(allocator, "var capture = 11; fn f() -> Nil { capture = 2; }") catch |err| {
        switch (err) {
            TypeCheckerError.MutableGlobalStateCaptureAttempt => return, // expected
            else => return err,
        }
    };
    result.env.deinit();
    result.registry.deinit();
    return error.TestExpectedError;
}

test "Functions may read global constants and call global functions" {
    const allocator = std.testing.allocator;
    var result = try checkSource(allocator, "const G = 5; fn helper(x: Int) -> Int { return x; } fn f() -> Int { return helper(G); }");
    result.env.deinit();
    result.registry.deinit();
}

test "Closures may capture function-local variables" {
    const allocator = std.testing.allocator;
    var result = try checkSource(allocator, "fn make() -> fn () -> Int { var counter = 0; fn inc() -> Int { counter += 1; return counter; } return inc; }");
    result.env.deinit();
    result.registry.deinit();
}

test "Type Checker - coroutine declaration creates coroutine type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator, "co add(a: Int, b: Int) -> (Int, Int) { yield a + b; return a + b; }");
    defer result.env.deinit();
    defer result.registry.deinit();

    const co_type = result.registry.get_type_info(try result.env.lookup("add"));
    try std.testing.expect(co_type == .coroutine);
    try std.testing.expectEqual(@as(usize, 2), co_type.coroutine.args.len);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), co_type.coroutine.args[0]);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), co_type.coroutine.args[1]);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), co_type.coroutine.yield);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), co_type.coroutine.ret);
}

test "Type Checker - coroutine yield and return combinations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // yield + explicit return
    _ = try checkSource(allocator, "co f() -> (Int, Nil) { yield 1; return nil; }");
    // yield + bare return
    _ = try checkSource(allocator, "co f() -> (Int, Nil) { yield 1; return; }");
    // yield only, Nil return type
    _ = try checkSource(allocator, "co f() -> (Int, Nil) { yield 1; }");
    // empty coroutine with Nil yield and Nil return
    _ = try checkSource(allocator, "co f() -> (Nil, Nil) { }");
    // yield in both branches of an if
    _ = try checkSource(allocator, "co g(x: Bool) -> (Int, Nil) { if (x) { yield 1; } else { yield 2; } }");
    // yield after a conditional
    _ = try checkSource(allocator, "co h(x: Bool) -> (Int, Nil) { if (x) { yield 1; } yield 2; }");
    // yield followed by return in a nested block (regression: yield flag must survive the return)
    _ = try checkSource(allocator, "co f() -> (Int, Int) { { yield 1; return 2; } }");
    // generator: yield inside a loop body is recognized (existential check)
    _ = try checkSource(allocator, "co gen(limit: Int) -> (Int, Nil) { var i = 0; while (i < limit) { yield i; i += 1; } return nil; }");
    // yield only in one branch of an if is enough
    _ = try checkSource(allocator, "co f(x: Bool) -> (Int, Nil) { if (x) { yield 1; } return nil; }");
}

test "Type Checker - coroutine missing yield and return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // missing yield when yield type is set
    try std.testing.expectError(TypeCheckerError.MissingYield, checkSource(allocator, "co f() -> (Int, Int) { return 5; }"));
    // missing return when return type is set
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "co f() -> (Int, Int) { yield 5; }"));
    // neither yield nor return
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "co f() -> (Int, Int) { var x = 1; }"));
}

test "Type Checker - yield and return outside coroutine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "yield 1;"));
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "return 1;"));
}

test "Type Checker - coroutine yield and return type mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "co f() -> (Int, Nil) { yield \"s\"; }"));
    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "co f() -> (Int, Int) { yield 1; return nil; }"));
}

test "Type Checker - coroutine call argument checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // too few arguments
    try std.testing.expectError(TypeCheckerError.InvalidArgumentCount, checkSource(allocator, "co f(x: Int) -> (Int, Nil) { yield x; } var c = f();"));
    // too many arguments
    try std.testing.expectError(TypeCheckerError.InvalidArgumentCount, checkSource(allocator, "co f(x: Int) -> (Int, Nil) { yield x; } var c = f(1, 2);"));
    // argument type mismatch
    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "co f(x: Int) -> (Int, Nil) { yield x; } var c = f(\"s\");"));
    // calling a coroutine produces a coroutine value
    var result = try checkSource(allocator, "co f(x: Int) -> (Int, Nil) { yield x; } var c = f(5);");
    defer result.env.deinit();
    defer result.registry.deinit();
    const c_type = result.registry.get_type_info(try result.env.lookup("c"));
    try std.testing.expect(c_type == .coroutine);
}

test "Type Checker - resume on non-coroutine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "fn f() -> Int { return 1; } var x = resume f;"));
    try std.testing.expectError(TypeCheckerError.InvalidOperation, checkSource(allocator, "var x = 5; var y = resume x;"));
}

test "Type Checker - resume result is union of yield and return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator,
        \\co gen() -> (Int, String) { yield 1; return "done"; }
        \\var c = gen();
        \\var v = resume c;
    );
    defer result.env.deinit();
    defer result.registry.deinit();

    const v_type = try result.env.lookup("v");
    const info = result.registry.get_type_info(v_type);
    try std.testing.expect(info == ._union);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Int), info._union.left);
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.String), info._union.right);
}

test "Type Checker - coroutine member access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var result = try checkSource(allocator,
        \\co f() -> (Int, Nil) { yield 1; }
        \\var c = f();
        \\var a: Bool = c.suspended;
        \\var b: Bool = c.finished;
        \\var d: Bool = c.running;
    );
    defer result.env.deinit();
    defer result.registry.deinit();
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Bool), try result.env.lookup("a"));
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Bool), try result.env.lookup("b"));
    try std.testing.expectEqual(@intFromEnum(PrimitiveType.Bool), try result.env.lookup("d"));

    // unknown member
    try std.testing.expectError(TypeCheckerError.InvalidMemberAccess, checkSource(allocator, "co f() -> (Int, Nil) { yield 1; } var c = f(); var x = c.nope;"));
}

test "Type Checker - anonymous coroutine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    _ = try checkSource(allocator, "var c = co () -> (Int, Nil) { yield 1; };");
    try std.testing.expectError(TypeCheckerError.MissingYield, checkSource(allocator, "var c = co () -> (Int, Int) { return 5; };"));
    try std.testing.expectError(TypeCheckerError.MissingReturn, checkSource(allocator, "var c = co () -> (Int, Int) { yield 5; };"));
}

test "Type Checker - nested coroutines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // coroutine calling another coroutine
    _ = try checkSource(allocator, "co inner() -> (Int, Nil) { yield 1; } co outer() -> (Int, Nil) { yield 1; var c = inner(); resume c; }");
    // coroutine declared inside a block within a coroutine
    _ = try checkSource(allocator, "co outer() -> (Int, Nil) { yield 1; { co inner() -> (Int, Nil) { yield 2; } var c = inner(); resume c; } }");
}

test "Type Checker - function call argument checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // too few arguments
    try std.testing.expectError(TypeCheckerError.InvalidArgumentCount, checkSource(allocator, "fn f(x: Int) -> Int { return x; } var c = f();"));
    // too many arguments
    try std.testing.expectError(TypeCheckerError.InvalidArgumentCount, checkSource(allocator, "fn f(x: Int) -> Int { return x; } var c = f(1, 2);"));
    // argument type mismatch
    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "fn f(x: Int) -> Int { return x; } var c = f(\"s\");"));
}

test "Type Checker - non-boolean conditions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectError(TypeCheckerError.NonBooleanCondition, checkSource(allocator, "if (1) { var x = 0; }"));
    try std.testing.expectError(TypeCheckerError.TypeMismatch, checkSource(allocator, "while (1) { break; }"));
}
