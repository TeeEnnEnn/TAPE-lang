const std = @import("std");
const AST = @import("ast.zig");

fn indent(depth: usize, amount: usize) void {
    for (0..depth * amount) |_| {
        std.debug.print(" ", .{});
    }
}

fn write_location(line: usize, column: usize) void {
    std.debug.print(" ({d}:{d})", .{ line, column });
}

pub fn print_node(node: *AST.ASTNode, depth: usize, indent_amt: usize) void {
    indent(depth, indent_amt);
    switch (node.*) {
        .program => |program| {
            std.debug.print("Program:\n", .{});
            for (program.declarations) |decl| {
                print_node(decl, depth + 1, indent_amt);
            }
        },

        .var_decl => |var_decl| {
            std.debug.print("VarDecl: {s}", .{var_decl.name.lexeme});
            write_location(var_decl.line, var_decl.column);
            std.debug.print("\n", .{});
            if (var_decl.type_annotation) |type_annotation| {
                print_node(type_annotation, depth + 1, indent_amt);
            }
            print_node(var_decl.initializer, depth + 1, indent_amt);
        },
        .fn_decl => |fn_decl| {
            std.debug.print("FnDecl: {s}", .{fn_decl.name.lexeme});
            write_location(fn_decl.line, fn_decl.column);
            if (fn_decl.modifier_pub) std.debug.print(" pub", .{});
            if (fn_decl.modifier_static) std.debug.print(" static", .{});
            std.debug.print("\n", .{});
            for (fn_decl.params) |param| {
                indent(depth + 1, indent_amt);
                std.debug.print("Param: {s}\n", .{param.name.lexeme});
                print_node(param.type_annotation, depth + 2, indent_amt);
            }
            print_node(fn_decl.return_type_annotation, depth + 1, indent_amt);
            print_node(fn_decl.body, depth + 1, indent_amt);
        },
        .type_decl => |type_decl| {
            std.debug.print("TypeDecl: {s}", .{type_decl.name.lexeme});
            write_location(type_decl.line, type_decl.column);
            if (type_decl.modifier_pub) std.debug.print(" pub", .{});
            std.debug.print("\n", .{});
            print_node(type_decl.type_annotation, depth + 1, indent_amt);
        },
        .struct_decl => |struct_decl| {
            std.debug.print("StructDecl: {s}", .{struct_decl.name.lexeme});
            write_location(struct_decl.line, struct_decl.column);
            if (struct_decl.modifier_pub) std.debug.print(" pub", .{});
            std.debug.print("\n", .{});
            for (struct_decl.fields) |field| {
                indent(depth + 1, indent_amt);
                std.debug.print("Field: {s}", .{field.name.lexeme});
                if (field.is_pub) std.debug.print(" pub", .{});
                if (field.is_static) std.debug.print(" static", .{});
                if (field.has_default) std.debug.print(" default", .{});
                std.debug.print("\n", .{});
                print_node(field.type_annotation, depth + 2, indent_amt);
                if (field.has_default) {
                    if (field.default_value) |dv| {
                        print_node(dv, depth + 2, indent_amt);
                    }
                }
            }
            for (struct_decl.methods) |method| {
                indent(depth + 1, indent_amt);
                std.debug.print("Method: {s}", .{method.name.lexeme});
                if (method.is_pub) std.debug.print(" pub", .{});
                if (method.is_static) std.debug.print(" static", .{});
                std.debug.print("\n", .{});
                print_node(method.method, depth + 2, indent_amt);
            }
        },
        .enum_decl => |enum_decl| {
            std.debug.print("EnumDecl: {s}", .{enum_decl.name.lexeme});
            write_location(enum_decl.line, enum_decl.column);
            if (enum_decl.modifier_pub) std.debug.print(" pub", .{});
            std.debug.print("\n", .{});
            for (enum_decl.variants) |variant| {
                indent(depth + 1, indent_amt);
                std.debug.print("Variant: {s}\n", .{variant.lexeme});
            }
        },
        .error_decl => |error_decl| {
            std.debug.print("ErrorDecl: {s}", .{error_decl.name.lexeme});
            write_location(error_decl.line, error_decl.column);
            if (error_decl.modifier_pub) std.debug.print(" pub", .{});
            std.debug.print("\n", .{});
            for (error_decl.variants) |variant| {
                indent(depth + 1, indent_amt);
                std.debug.print("Variant: {s}\n", .{variant.lexeme});
            }
        },
        .co_decl => |co_decl| {
            std.debug.print("CoDecl: {s}", .{co_decl.name.lexeme});
            write_location(co_decl.line, co_decl.column);
            if (co_decl.modifier_pub) std.debug.print(" pub", .{});
            if (co_decl.modifier_static) std.debug.print(" static", .{});
            std.debug.print("\n", .{});
            for (co_decl.params) |param| {
                indent(depth + 1, indent_amt);
                std.debug.print("Param: {s}\n", .{param.name.lexeme});
                print_node(param.type_annotation, depth + 2, indent_amt);
            }
            print_node(co_decl.return_type_annotation, depth + 1, indent_amt);
            print_node(co_decl.yield_type_annotation, depth + 1, indent_amt);
            print_node(co_decl.resume_with_type_annotation, depth + 1, indent_amt);
            print_node(co_decl.body, depth + 1, indent_amt);
        },
        .use_decl => |use_decl| {
            std.debug.print("UseDecl: {s}", .{use_decl.module.lexeme});
            write_location(use_decl.line, use_decl.column);
            if (use_decl.modifier_pub) std.debug.print(" pub", .{});
            std.debug.print("\n", .{});
            for (use_decl.items) |item| {
                indent(depth + 1, indent_amt);
                std.debug.print("Item: {s}", .{item.name.lexeme});
                if (item.alias) |alias| {
                    std.debug.print(" as {s}", .{alias.lexeme});
                }
                std.debug.print("\n", .{});
            }
        },

        .anon_co_expr => |co_expr| {
            std.debug.print("AnonCoExpr:", .{});
            write_location(co_expr.line, co_expr.column);
            std.debug.print("\n", .{});
            for (co_expr.params) |param| {
                indent(depth + 1, indent_amt);
                std.debug.print("Param: {s}\n", .{param.name.lexeme});
                print_node(param.type_annotation, depth + 2, indent_amt);
            }
            print_node(co_expr.return_type_annotation, depth + 1, indent_amt);
            print_node(co_expr.yield_type_annotation, depth + 1, indent_amt);
            print_node(co_expr.resume_with_type_annotation, depth + 1, indent_amt);
            print_node(co_expr.body, depth + 1, indent_amt);
        },
        .anon_fn_expr => |fn_expr| {
            std.debug.print("AnonFnExpr:", .{});
            write_location(fn_expr.line, fn_expr.column);
            std.debug.print("\n", .{});
            for (fn_expr.params) |param| {
                indent(depth + 1, indent_amt);
                std.debug.print("Param: {s}\n", .{param.name.lexeme});
                print_node(param.type_annotation, depth + 2, indent_amt);
            }
            print_node(fn_expr.return_type_annotation, depth + 1, indent_amt);
            print_node(fn_expr.body, depth + 1, indent_amt);
        },
        .array_expr => |array_expr| {
            std.debug.print("ArrayExpr:", .{});
            write_location(array_expr.line, array_expr.column);
            std.debug.print("\n", .{});
            for (array_expr.elements) |element| {
                print_node(element, depth + 1, indent_amt);
            }
        },
        .array_type => |array_type| {
            std.debug.print("ArrayType:\n", .{});
            print_node(array_type.element_type, depth + 1, indent_amt);
        },
        .assign_expr => |assign_expr| {
            std.debug.print("AssignExpr: {s}", .{assign_expr.operator.lexeme});
            write_location(assign_expr.line, assign_expr.column);
            std.debug.print("\n", .{});
            print_node(assign_expr.left, depth + 1, indent_amt);
            print_node(assign_expr.right, depth + 1, indent_amt);
        },
        .binary_expr => |binary_expr| {
            std.debug.print("BinaryExpr: {s}", .{binary_expr.operator.lexeme});
            write_location(binary_expr.line, binary_expr.column);
            std.debug.print("\n", .{});
            print_node(binary_expr.left, depth + 1, indent_amt);
            print_node(binary_expr.right, depth + 1, indent_amt);
        },
        .block_stmt => |block_stmt| {
            std.debug.print("BlockStmt:", .{});
            write_location(block_stmt.line, block_stmt.column);
            std.debug.print("\n", .{});
            for (block_stmt.stmts) |stmt| {
                print_node(stmt, depth + 1, indent_amt);
            }
        },
        .bool_lit => |bool_lit| {
            std.debug.print("BoolLit: {s}", .{if (bool_lit.value) "true" else "false"});
            write_location(bool_lit.line, bool_lit.column);
            std.debug.print("\n", .{});
        },
        .bool_type => {
            std.debug.print("BoolType:\n", .{});
        },
        .break_stmt => |break_stmt| {
            std.debug.print("BreakStmt:", .{});
            write_location(break_stmt.line, break_stmt.column);
            std.debug.print("\n", .{});
        },
        .continue_stmt => |continue_stmt| {
            std.debug.print("ContinueStmt:", .{});
            write_location(continue_stmt.line, continue_stmt.column);
            std.debug.print("\n", .{});
        },
        .call_expr => |call_expr| {
            std.debug.print("CallExpr:", .{});
            write_location(call_expr.line, call_expr.column);
            std.debug.print("\n", .{});
            print_node(call_expr.expr, depth + 1, indent_amt);
            for (call_expr.args) |arg| {
                print_node(arg, depth + 1, indent_amt);
            }
        },
        .co_type => |co_type| {
            std.debug.print("CoType:\n", .{});
            for (co_type.params) |param| {
                print_node(param, depth + 1, indent_amt);
            }
            indent(depth + 1, indent_amt);
            std.debug.print("return_type:\n", .{});
            print_node(co_type.return_type, depth + 2, indent_amt);
            indent(depth + 1, indent_amt);
            std.debug.print("yield_type:\n", .{});
            print_node(co_type.yield_type, depth + 2, indent_amt);
            indent(depth + 1, indent_amt);
            std.debug.print("resume_with_type:\n", .{});
            print_node(co_type.resume_with_type, depth + 2, indent_amt);
        },
        .default_pat => {
            std.debug.print("DefaultPat:\n", .{});
        },
        .dot_expr => |dot_expr| {
            std.debug.print("DotExpr: .{s}", .{dot_expr.member.lexeme});
            write_location(dot_expr.line, dot_expr.column);
            std.debug.print("\n", .{});
            print_node(dot_expr.expr, depth + 1, indent_amt);
        },
        .expr_stmt => |expr_stmt| {
            std.debug.print("ExprStmt:", .{});
            write_location(expr_stmt.line, expr_stmt.column);
            std.debug.print("\n", .{});
            print_node(expr_stmt.expr, depth + 1, indent_amt);
        },
        .float_lit => |float_lit| {
            std.debug.print("FloatLit: {}", .{float_lit.value});
            write_location(float_lit.line, float_lit.column);
            std.debug.print("\n", .{});
        },
        .float_type => {
            std.debug.print("FloatType:\n", .{});
        },
        .fn_type => |fn_type| {
            std.debug.print("FnType:\n", .{});
            for (fn_type.params) |param| {
                print_node(param, depth + 1, indent_amt);
            }
            indent(depth + 1, indent_amt);
            std.debug.print("return_type:\n", .{});
            print_node(fn_type.return_type, depth + 2, indent_amt);
        },
        .for_stmt => |for_stmt| {
            std.debug.print("ForStmt: {s}", .{for_stmt.iterator_name.lexeme});
            write_location(for_stmt.line, for_stmt.column);
            std.debug.print("\n", .{});
            print_node(for_stmt.iterator_expr, depth + 1, indent_amt);
            print_node(for_stmt.body, depth + 1, indent_amt);
        },
        .give_stmt => |give_stmt| {
            std.debug.print("GiveStmt:", .{});
            write_location(give_stmt.line, give_stmt.column);
            std.debug.print("\n", .{});
            print_node(give_stmt.expr, depth + 1, indent_amt);
        },
        .group_expr => |group_expr| {
            std.debug.print("GroupExpr:", .{});
            write_location(group_expr.line, group_expr.column);
            std.debug.print("\n", .{});
            print_node(group_expr.expr, depth + 1, indent_amt);
        },
        .identifier_expr => |identifier_expr| {
            std.debug.print("IdentifierExpr: {s}", .{identifier_expr.name.lexeme});
            write_location(identifier_expr.line, identifier_expr.column);
            std.debug.print("\n", .{});
        },
        .identifier_type => |identifier_type| {
            std.debug.print("IdentifierType: {s}", .{identifier_type.name.lexeme});
            if (identifier_type.generic_args) |args| {
                std.debug.print("<", .{});
                for (args, 0..) |arg, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    print_node(arg, 0, indent_amt);
                }
                std.debug.print(">", .{});
            }
            std.debug.print("\n", .{});
        },
        .index_expr => |index_expr| {
            std.debug.print("IndexExpr:", .{});
            write_location(index_expr.line, index_expr.column);
            std.debug.print("\n", .{});
            print_node(index_expr.expr, depth + 1, indent_amt);
            print_node(index_expr.index, depth + 1, indent_amt);
        },
        .if_stmt => |if_stmt| {
            std.debug.print("IfStmt:", .{});
            write_location(if_stmt.line, if_stmt.column);
            std.debug.print("\n", .{});
            print_node(if_stmt.condition, depth + 1, indent_amt);
            print_node(if_stmt.then_branch, depth + 1, indent_amt);
            if (if_stmt.else_branch) |else_branch| {
                print_node(else_branch, depth + 1, indent_amt);
            }
        },
        .int_lit => |int_lit| {
            std.debug.print("IntLit: {}", .{int_lit.value});
            write_location(int_lit.line, int_lit.column);
            std.debug.print("\n", .{});
        },
        .int_type => {
            std.debug.print("IntType:\n", .{});
        },
        .match_expr => |match_expr| {
            std.debug.print("MatchExpr:", .{});
            write_location(match_expr.line, match_expr.column);
            std.debug.print("\n", .{});
            print_node(match_expr.expr, depth + 1, indent_amt);
            for (match_expr.cases) |case| {
                indent(depth + 1, indent_amt);
                std.debug.print("Case:\n", .{});
                print_node(case.pattern, depth + 2, indent_amt);
                print_node(case.stmt, depth + 2, indent_amt);
            }
        },
        .never_type => {
            std.debug.print("NeverType:\n", .{});
        },
        .new_expr => |new_expr| {
            std.debug.print("NewExpr: {s}", .{new_expr.struct_name.lexeme});
            write_location(new_expr.line, new_expr.column);
            std.debug.print("\n", .{});
            for (new_expr.fields) |field| {
                indent(depth + 1, indent_amt);
                std.debug.print("Field: {s}\n", .{field.name.lexeme});
                print_node(field.value, depth + 2, indent_amt);
            }
        },
        .nil_lit => {
            std.debug.print("NilLit:\n", .{});
        },
        .nil_type => {
            std.debug.print("NilType:\n", .{});
        },
        .panic_stmt => |panic_stmt| {
            std.debug.print("PanicStmt:", .{});
            write_location(panic_stmt.line, panic_stmt.column);
            std.debug.print("\n", .{});
            print_node(panic_stmt.expr, depth + 1, indent_amt);
        },
        .range_type => |range_type| {
            std.debug.print("RangeType:\n", .{});
            print_node(range_type.start, depth + 1, indent_amt);
            print_node(range_type.end, depth + 1, indent_amt);
        },
        .resume_expr => |resume_expr| {
            std.debug.print("ResumeExpr:", .{});
            write_location(resume_expr.line, resume_expr.column);
            std.debug.print("\n", .{});
            print_node(resume_expr.expr, depth + 1, indent_amt);
            if (resume_expr.arg) |arg| {
                indent(depth + 1, indent_amt);
                std.debug.print("with:\n", .{});
                print_node(arg, depth + 2, indent_amt);
            }
        },
        .return_stmt => |return_stmt| {
            std.debug.print("ReturnStmt:", .{});
            write_location(return_stmt.line, return_stmt.column);
            std.debug.print("\n", .{});
            if (return_stmt.expr) |expr| print_node(expr, depth + 1, indent_amt);
        },
        .static_member_expr => |static_member_expr| {
            std.debug.print("StaticMemberExpr: ::{s}", .{static_member_expr.member.lexeme});
            write_location(static_member_expr.line, static_member_expr.column);
            std.debug.print("\n", .{});
            print_node(static_member_expr.expr, depth + 1, indent_amt);
        },
        .str_lit => |str_lit| {
            std.debug.print("StrLit: \"{s}\"", .{str_lit.value});
            write_location(str_lit.line, str_lit.column);
            std.debug.print("\n", .{});
        },
        .string_type => {
            std.debug.print("StringType:\n", .{});
        },
        .table_expr => |table_expr| {
            std.debug.print("TableExpr:", .{});
            write_location(table_expr.line, table_expr.column);
            std.debug.print("\n", .{});
            for (table_expr.keys) |key| {
                indent(depth + 1, indent_amt);
                std.debug.print("key:\n", .{});
                print_node(key, depth + 2, indent_amt);
            }
            for (table_expr.values) |value| {
                indent(depth + 1, indent_amt);
                std.debug.print("value:\n", .{});
                print_node(value, depth + 2, indent_amt);
            }
        },
        .table_type => |table_type| {
            std.debug.print("TableType:\n", .{});
            print_node(table_type.key_type, depth + 1, indent_amt);
            print_node(table_type.element_type, depth + 1, indent_amt);
        },
        .try_expr => |try_expr| {
            std.debug.print("TryExpr:", .{});
            write_location(try_expr.line, try_expr.column);
            std.debug.print("\n", .{});
            print_node(try_expr.expr, depth + 1, indent_amt);
        },
        .tuple_expr => |tuple_expr| {
            std.debug.print("TupleExpr:", .{});
            write_location(tuple_expr.line, tuple_expr.column);
            std.debug.print("\n", .{});
            for (tuple_expr.exprs) |expr| {
                print_node(expr, depth + 1, indent_amt);
            }
        },
        .tuple_type => |tuple_type| {
            std.debug.print("TupleType:\n", .{});
            for (tuple_type.element_types) |tup| {
                print_node(tup, depth + 1, indent_amt);
            }
        },
        .unary_expr => |unary_expr| {
            std.debug.print("UnaryExpr: {s}", .{unary_expr.operator.lexeme});
            write_location(unary_expr.line, unary_expr.column);
            std.debug.print("\n", .{});
            print_node(unary_expr.expr, depth + 1, indent_amt);
        },
        .union_type => |union_type| {
            std.debug.print("UnionType:\n", .{});
            print_node(union_type.left, depth + 1, indent_amt);
            print_node(union_type.right, depth + 1, indent_amt);
        },
        .while_stmt => |while_stmt| {
            std.debug.print("WhileStmt:", .{});
            write_location(while_stmt.line, while_stmt.column);
            std.debug.print("\n", .{});
            print_node(while_stmt.condition, depth + 1, indent_amt);
            print_node(while_stmt.body, depth + 1, indent_amt);
        },
        .yield_expr => |yield_expr| {
            std.debug.print("YieldExpr:", .{});
            write_location(yield_expr.line, yield_expr.column);
            std.debug.print("\n", .{});

            print_node(yield_expr.expr, depth + 1, indent_amt);
        },
    }
}
