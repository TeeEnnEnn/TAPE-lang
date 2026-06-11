const std = @import("std");
const Parser = @import("../parser.zig").Parser;
const AST = @import("../ast.zig");
const DiagnosticsReporter = @import("../../helpers/diagnostics.zig").DiagnosticsReporter;

fn parseFirstDecl(allocator: std.mem.Allocator, source: []const u8) !*AST.ASTNode {
    var diagnostics = DiagnosticsReporter.init(allocator);
    defer diagnostics.deinit();
    var p = try Parser.init(allocator, source, &diagnostics, "test");
    const node = try p.parse();
    try std.testing.expect(node.* == .program);
    try std.testing.expect(node.program.declarations.len > 0);
    return node.program.declarations[0];
}

test "Parser can parse basic variable declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "var x = 42;";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .var_decl);
    const var_decl = node.var_decl;
    try std.testing.expectEqualStrings("x", var_decl.name.lexeme);
    try std.testing.expect(var_decl.type_annotation == null);
    try std.testing.expect(var_decl.initializer.* == .int_lit);
    try std.testing.expectEqual(@as(i64, 42), var_decl.initializer.int_lit.value);
}

test "Parser can parse variable declaration with type annotation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "pub var name: String = \"Tape\";";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .var_decl);
    const var_decl = node.var_decl;
    try std.testing.expect(var_decl.modifier_pub);
    try std.testing.expectEqualStrings("name", var_decl.name.lexeme);

    try std.testing.expect(var_decl.type_annotation != null);
    try std.testing.expect(var_decl.type_annotation.?.* == .string_type);

    try std.testing.expect(var_decl.initializer.* == .str_lit);
    try std.testing.expectEqualStrings("Tape", var_decl.initializer.str_lit.value);
}

test "Parser can parse function declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "fn add(a: Int, b: Float) -> Int { return a; }";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .fn_decl);
    const fn_decl = node.fn_decl;
    try std.testing.expectEqualStrings("add", fn_decl.name.lexeme);

    try std.testing.expectEqual(@as(usize, 2), fn_decl.params.len);
    try std.testing.expectEqualStrings("a", fn_decl.params[0].name.lexeme);
    try std.testing.expect(fn_decl.params[0].type_annotation.* == .int_type);

    try std.testing.expectEqualStrings("b", fn_decl.params[1].name.lexeme);
    try std.testing.expect(fn_decl.params[1].type_annotation.* == .float_type);

    try std.testing.expect(fn_decl.return_type_annotation.* == .int_type);

    try std.testing.expect(fn_decl.body.* == .block_stmt);
    try std.testing.expectEqual(@as(usize, 1), fn_decl.body.block_stmt.stmts.len);
    try std.testing.expect(fn_decl.body.block_stmt.stmts[0].* == .return_stmt);
}

test "Parser can parse struct declaration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "struct Point { x: Float, y: Float }";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .struct_decl);
    const struct_decl = node.struct_decl;
    try std.testing.expectEqualStrings("Point", struct_decl.name.lexeme);
    try std.testing.expectEqual(@as(usize, 2), struct_decl.fields.len);
    try std.testing.expectEqualStrings("x", struct_decl.fields[0].name.lexeme);
    try std.testing.expectEqualStrings("y", struct_decl.fields[1].name.lexeme);
}

test "Parser can parse operator precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "2 + 3 * 4;";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .expr_stmt);
    const expr = node.expr_stmt.expr;
    try std.testing.expect(expr.* == .binary_expr);

    const root_bin = expr.binary_expr;
    try std.testing.expectEqualStrings("+", root_bin.operator.lexeme);

    try std.testing.expect(root_bin.left.* == .int_lit);
    try std.testing.expectEqual(@as(i64, 2), root_bin.left.int_lit.value);

    try std.testing.expect(root_bin.right.* == .binary_expr);
    const right_bin = root_bin.right.binary_expr;
    try std.testing.expectEqualStrings("*", right_bin.operator.lexeme);
    try std.testing.expectEqual(@as(i64, 3), right_bin.left.int_lit.value);
    try std.testing.expectEqual(@as(i64, 4), right_bin.right.int_lit.value);
}

test "Parser can parse exponentiation **" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "2 ** 3;";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .expr_stmt);
    const expr = node.expr_stmt.expr;
    try std.testing.expect(expr.* == .binary_expr);
    try std.testing.expectEqualStrings("**", expr.binary_expr.operator.lexeme);
    try std.testing.expectEqual(@as(i64, 2), expr.binary_expr.left.int_lit.value);
    try std.testing.expectEqual(@as(i64, 3), expr.binary_expr.right.int_lit.value);
}

test "Parser can parse unary expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "not true;";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .expr_stmt);
    const expr = node.expr_stmt.expr;
    try std.testing.expect(expr.* == .unary_expr);
    try std.testing.expectEqualStrings("not", expr.unary_expr.operator.lexeme);
    try std.testing.expect(expr.unary_expr.expr.* == .bool_lit);
    try std.testing.expectEqual(true, expr.unary_expr.expr.bool_lit.value);
}

test "Parser can parse array literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "[1, 2, 3];";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .expr_stmt);
    const expr = node.expr_stmt.expr;
    try std.testing.expect(expr.* == .array_expr);
    try std.testing.expectEqual(@as(usize, 3), expr.array_expr.elements.len);
    try std.testing.expectEqual(@as(i64, 1), expr.array_expr.elements[0].int_lit.value);
    try std.testing.expectEqual(@as(i64, 2), expr.array_expr.elements[1].int_lit.value);
    try std.testing.expectEqual(@as(i64, 3), expr.array_expr.elements[2].int_lit.value);
}

test "Parser can parse table literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "{\"a\": 1, \"b\": 2};";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .expr_stmt);
    const expr = node.expr_stmt.expr;
    try std.testing.expect(expr.* == .table_expr);
    try std.testing.expectEqual(@as(usize, 2), expr.table_expr.keys.len);
    try std.testing.expectEqualStrings("a", expr.table_expr.keys[0].str_lit.value);
    try std.testing.expectEqual(@as(i64, 1), expr.table_expr.values[0].int_lit.value);
}

test "Parser can parse empty struct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "struct Empty {}";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .struct_decl);
    const struct_decl = node.struct_decl;
    try std.testing.expectEqualStrings("Empty", struct_decl.name.lexeme);
    try std.testing.expectEqual(@as(usize, 0), struct_decl.fields.len);
    try std.testing.expectEqual(@as(usize, 0), struct_decl.methods.len);
}

test "Parser can parse empty enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "enum Test {}";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .enum_decl);
    const enum_decl = node.enum_decl;
    try std.testing.expectEqualStrings("Test", enum_decl.name.lexeme);
    try std.testing.expectEqual(@as(usize, 0), enum_decl.variants.len);
}

test "Parser can parse empty error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "error Test {}";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .error_decl);
    const error_decl = node.error_decl;
    try std.testing.expectEqualStrings("Test", error_decl.name.lexeme);
    try std.testing.expectEqual(@as(usize, 0), error_decl.variants.len);
}

test "Parser can parse enum with variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const node = try parseFirstDecl(allocator, "enum Color { Red, Green, Blue }");
    try std.testing.expect(node.* == .enum_decl);
    const enum_decl = node.enum_decl;
    try std.testing.expectEqualStrings("Color", enum_decl.name.lexeme);
    try std.testing.expectEqual(@as(usize, 3), enum_decl.variants.len);
    try std.testing.expectEqualStrings("Red", enum_decl.variants[0].lexeme);
    try std.testing.expectEqualStrings("Green", enum_decl.variants[1].lexeme);
    try std.testing.expectEqualStrings("Blue", enum_decl.variants[2].lexeme);
}

test "Parser can parse error with variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const node = try parseFirstDecl(allocator, "error HttpError { NotFound, Unauthorized }");
    try std.testing.expect(node.* == .error_decl);
    const error_decl = node.error_decl;
    try std.testing.expectEqualStrings("HttpError", error_decl.name.lexeme);
    try std.testing.expectEqual(@as(usize, 2), error_decl.variants.len);
    try std.testing.expectEqualStrings("NotFound", error_decl.variants[0].lexeme);
    try std.testing.expectEqualStrings("Unauthorized", error_decl.variants[1].lexeme);
}

test "Parser can parse coroutine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "co test() -> (Nil, Nil) {}";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .co_decl);
    const coroutine_decl = node.co_decl;
    try std.testing.expectEqualStrings("test", coroutine_decl.name.lexeme);
    try std.testing.expect(coroutine_decl.yield_type_annotation.* == .nil_type);
    try std.testing.expect(coroutine_decl.return_type_annotation.* == .nil_type);
}

test "Parser can parse for statement with var iterator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "for (var i in 0..10) {}";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .for_stmt);
    try std.testing.expectEqualStrings("i", node.for_stmt.iterator_name.lexeme);
    try std.testing.expect(node.for_stmt.iterator_expr.* == .binary_expr);
    try std.testing.expectEqualStrings("..", node.for_stmt.iterator_expr.binary_expr.operator.lexeme);
}

test "Parser can parse Color::Red expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const node = try parseFirstDecl(allocator, "Color::Red;");
    try std.testing.expect(node.* == .expr_stmt);
    try std.testing.expect(node.expr_stmt.expr.* == .static_member_expr);
    try std.testing.expectEqualStrings("Red", node.expr_stmt.expr.static_member_expr.member.lexeme);
}

test "Parser can parse struct methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "struct Counter { value: Int, fn next(self: Counter) -> Int { return 1; } }";
    const node = try parseFirstDecl(allocator, source);

    try std.testing.expect(node.* == .struct_decl);
    const struct_decl = node.struct_decl;
    try std.testing.expectEqual(@as(usize, 1), struct_decl.fields.len);
    try std.testing.expectEqual(@as(usize, 1), struct_decl.methods.len);
    try std.testing.expect(struct_decl.methods[0].method.* == .fn_decl);
    try std.testing.expectEqualStrings("next", struct_decl.methods[0].method.fn_decl.name.lexeme);
}
