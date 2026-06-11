const std = @import("std");
const TypeChecker = @import("../type_checker.zig").TypeChecker;
const TypeCheckerError = @import("../type_checker.zig").TypeCheckerError;
const Environment = @import("../environment.zig").Environment;
const EnvironmentError = @import("../environment.zig").EnvironmentError;
const TypeRegistry = @import("../type_registry.zig").TypeRegistry;
const TypeId = @import("../ast.zig").TypeId;
const Parser = @import("../parser.zig").Parser;
const PrimitiveType = @import("../type_registry.zig").PrimitiveType;
const DiagnosticsReporter = @import("../../helpers/diagnostics.zig").DiagnosticsReporter;

fn checkSource(allocator: std.mem.Allocator, source: []const u8) !struct { registry: TypeRegistry, env: Environment } {
    var diagnostics = DiagnosticsReporter.init(allocator);
    defer diagnostics.deinit();

    var parser = try Parser.init(allocator, source, &diagnostics, "test");
    const program = try parser.parse();

    var env = Environment.init(allocator, null);
    var registry = try TypeRegistry.init(allocator);
    var checker = TypeChecker.init(allocator, &registry, &env, &diagnostics, "test");
    _ = try checker.check(program);

    return .{ .registry = registry, .env = env };
}

test "Type Checker - Init works" {
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var diagnostics = DiagnosticsReporter.init(allocator);
    defer diagnostics.deinit();

    var env = Environment.init(allocator, null);
    defer env.deinit();

    var registry = try TypeRegistry.init(arena_allocator);
    defer registry.deinit();

    const type_checker = TypeChecker.init(allocator, &registry, &env, &diagnostics, "test");
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

    // valid use declaration
    _ = try checkSource(allocator, "use foo from \"mymodule\";");

    // invalid: empty module path - but parser requires STRING token so len > 0 is guaranteed
    // invalid: empty import name - parser requires IDENTIFIER so len > 0 is guaranteed
    // Both cases are handled by the parser, so the type checker check is a safety net.
    // For now we just verify valid cases compile.
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
