//! Debug printing for the TAPE compiler.

const std = @import("std");
const AST = @import("ast.zig");

pub const ASTDebugPrinter = struct {
    var depth: usize = 0;
    var indent_amount: usize = 4;

    fn indent(d: usize) void {
        const to_print: usize = d * indent_amount;
        for (0..to_print) |_| {
            std.debug.print(" ", .{});
        }
    }

    pub fn print_node(node: *AST.ASTNode) void {
        indent(depth);
        depth += 1;
        switch (node.*) {
            .program => |program| {
                std.debug.print("Program: \n", .{});
                for (program.declarations) |decl| {
                    print_node(decl);
                }
            },

            .var_decl => |var_decl| {
                std.debug.print("VarDecl: {s}\n", .{var_decl.name.lexeme});
                if (var_decl.type_annotation) |type_annotation| {
                    print_node(type_annotation);
                }
                print_node(var_decl.initializer);
            },
            .fn_decl => |fn_decl| {
                std.debug.print("FnDecl: {s}\n", .{fn_decl.name.lexeme});
                for (fn_decl.params) |param| {
                    std.debug.print("  Param: {s}\n", .{param.name.lexeme});
                    print_node(param.type_annotation);
                }
                print_node(fn_decl.return_type_annotation);
                print_node(fn_decl.body);
            },
            .type_decl => |type_decl| {
                std.debug.print("TypeDecl: {s}\n", .{type_decl.name.lexeme});
                print_node(type_decl.type_annotation);
            },
            .struct_decl => |struct_decl| {
                std.debug.print("StructDecl: {s}\n", .{struct_decl.name.lexeme});
                for (struct_decl.fields) |field| {
                    std.debug.print("  Field: {s}\n", .{field.name.lexeme});
                    print_node(field.type_annotation);
                }
                for (struct_decl.methods) |method| {
                    std.debug.print("  Method: {s}\n", .{method.name.lexeme});
                    print_node(method.method);
                }
            },
            .enum_decl => |enum_decl| {
                std.debug.print("EnumDecl: {s}\n", .{enum_decl.name.lexeme});
                for (enum_decl.variants) |variant| {
                    std.debug.print("  Variant: {s}\n", .{variant.lexeme});
                }
            },
            .error_decl => |error_decl| {
                std.debug.print("ErrorDecl: {s}\n", .{error_decl.name.lexeme});
                for (error_decl.variants) |variant| {
                    std.debug.print("  Variant: {s}\n", .{variant.lexeme});
                }
            },
            .co_decl => |co_decl| {
                std.debug.print("CoDecl: {s}\n", .{co_decl.name.lexeme});
                print_node(co_decl.return_type_annotation);
                print_node(co_decl.body);
            },
            .use_decl => |use_decl| {
                std.debug.print("UseDecl: {s}\n", .{use_decl.module.lexeme});
                for (use_decl.items) |item| {
                    std.debug.print("  Item: {s}\n", .{item.name.lexeme});
                    if (item.alias) |alias| {
                        std.debug.print("    Alias: {s}\n", .{alias.lexeme});
                    }
                }
            },

            .anon_co_expr => |co_expr| {
                std.debug.print("AnonCoExpr: \n", .{});
                print_node(co_expr.return_type_annotation);
                print_node(co_expr.body);
            },
            .anon_fn_expr => |fn_expr| {
                std.debug.print("AnonFnExpr: \n", .{});
                print_node(fn_expr.return_type_annotation);
                print_node(fn_expr.body);
            },
            .array_expr => |array_expr| {
                std.debug.print("ArrayExpr: \n", .{});
                for (array_expr.elements) |element| {
                    print_node(element);
                }
            },
            .array_type => |array_type| {
                std.debug.print("ArrayType: \n", .{});
                print_node(array_type.element_type);
            },
            .assign_expr => |assign_expr| {
                std.debug.print("AssignExpr: \n", .{});
                print_node(assign_expr.left);
                print_node(assign_expr.right);
            },
            .binary_expr => |binary_expr| {
                std.debug.print("BinaryExpr: \n", .{});
                print_node(binary_expr.left);
                print_node(binary_expr.right);
            },
            .block_stmt => |block_stmt| {
                std.debug.print("BlockStmt: \n", .{});
                for (block_stmt.stmts) |stmt| {
                    print_node(stmt);
                }
            },
            .bool_lit => |bool_lit| {
                std.debug.print("BoolLit: \n", .{});
                if (bool_lit.value) {
                    std.debug.print("  true\n", .{});
                } else {
                    std.debug.print("  false\n", .{});
                }
            },
            .bool_type => {
                std.debug.print("BoolType: \n", .{});
            },
            .break_stmt => {
                std.debug.print("BreakStmt: \n", .{});
            },
            .continue_stmt => {
                std.debug.print("ContinueStmt: \n", .{});
            },
            .call_expr => |call_expr| {
                std.debug.print("CallExpr: \n", .{});
                print_node(call_expr.expr);
                std.debug.print("args: \n", .{});
                for (call_expr.args) |arg| {
                    print_node(arg);
                }
            },
            .cast_expr => |cast_expr| {
                std.debug.print("CastExpr: \n", .{});
                print_node(cast_expr.expr);
                print_node(cast_expr.type);
            },
            .co_type => |co_type| {
                std.debug.print("CoType: \n", .{});
                for (co_type.params) |param| {
                    print_node(param);
                }
                std.debug.print("return_type: \n", .{});
                print_node(co_type.return_type);
                std.debug.print("yield_type: \n", .{});
                print_node(co_type.yield_type);
            },
            .default_pat => {
                std.debug.print("DefaultPat: \n", .{});
            },
            .dot_expr => |dot_expr| {
                std.debug.print("DotExpr: \n", .{});
                print_node(dot_expr.expr);
                std.debug.print("member: \n", .{});
                std.debug.print("{s}\n", .{dot_expr.member.lexeme});
            },
            .expr_stmt => |expr_stmt| {
                std.debug.print("ExprStmt: \n", .{});
                print_node(expr_stmt.expr);
            },
            .float_lit => |float_lit| {
                std.debug.print("FloatLit: \n", .{});
                std.debug.print("{}\n", .{float_lit.value});
            },
            .float_type => {
                std.debug.print("FloatType: \n", .{});
            },
            .fn_type => |fn_type| {
                std.debug.print("FnType: \n", .{});
                std.debug.print("params: \n", .{});
                for (fn_type.params) |param| {
                    print_node(param);
                }
                std.debug.print("return_type: \n", .{});
                print_node(fn_type.return_type);
            },
            .for_stmt => |for_stmt| {
                std.debug.print("ForStmt: \n", .{});
                print_node(for_stmt.iterator_expr);
                print_node(for_stmt.body);
            },
            .give_stmt => |give_stmt| {
                std.debug.print("GiveStmt: \n", .{});
                print_node(give_stmt.expr);
            },
            .group_expr => |group_expr| {
                std.debug.print("GroupExpr: \n", .{});
                print_node(group_expr.expr);
            },
            .identifier_expr => |identifier_expr| {
                std.debug.print("IdentifierExpr: {s}\n", .{identifier_expr.name.lexeme});
            },
            .identifier_type => |identifier_type| {
                std.debug.print("IdentifierType: {s}\n", .{identifier_type.name.lexeme});
            },
            .index_expr => |index_expr| {
                std.debug.print("IndexExpr: \n", .{});
                print_node(index_expr.expr);
                print_node(index_expr.index);
            },
            .if_stmt => |if_stmt| {
                std.debug.print("IfStmt: \n", .{});
                print_node(if_stmt.condition);
                print_node(if_stmt.then_branch);
                if (if_stmt.else_branch) |else_branch| {
                    print_node(else_branch);
                }
            },
            .int_lit => |int_lit| {
                std.debug.print("IntLit: {}\n", .{int_lit.value});
            },
            .int_type => {
                std.debug.print("IntType: \n", .{});
            },
            .match_expr => |match_expr| {
                std.debug.print("MatchExpr: \n", .{});
                print_node(match_expr.expr);
                for (match_expr.cases) |case| {
                    std.debug.print("  Case: \n", .{});
                    print_node(case.pattern);
                    print_node(case.stmt);
                }
            },
            .never_type => {
                std.debug.print("NeverType: \n", .{});
            },
            .new_expr => |new_expr| {
                std.debug.print("NewExpr: \n", .{});
                std.debug.print("  struct_name: {s}\n", .{new_expr.struct_name.lexeme});
                for (new_expr.fields) |field| {
                    std.debug.print("  field: \n", .{});
                    std.debug.print("    name: {s}\n", .{field.name.lexeme});
                    print_node(field.value);
                }
            },
            .nil_lit => {
                std.debug.print("NilLit: \n", .{});
            },
            .nil_type => {
                std.debug.print("NilType: \n", .{});
            },
            .panic_stmt => |panic_stmt| {
                std.debug.print("PanicStmt: \n", .{});
                print_node(panic_stmt.expr);
            },
            .range_type => |range_type| {
                std.debug.print("RangeType: \n", .{});
                print_node(range_type.start);
                print_node(range_type.end);
            },
            .resume_expr => |resume_expr| {
                std.debug.print("ResumeExpr: \n", .{});
                print_node(resume_expr.expr);
            },
            .return_stmt => |return_stmt| {
                std.debug.print("ReturnStmt: \n", .{});
                if (return_stmt.expr) |expr| print_node(expr);
            },
            .shape_expr => |shape_expr| {
                std.debug.print("ShapeExpr: \n", .{});
                for (shape_expr.fields) |field| {
                    std.debug.print("  {s}: ", .{field.name.lexeme});
                    print_node(field.type_annotation);
                }
            },
            .shape_type => |shape_type| {
                std.debug.print("ShapeType: \n", .{});
                for (shape_type.fields) |field| {
                    std.debug.print("  {s}: ", .{field.name.lexeme});
                    print_node(field.type_annotation);
                }
            },
            .static_member_expr => |static_member_expr| {
                std.debug.print("StaticMemberExpr: \n", .{});
                std.debug.print("  {s}: ", .{static_member_expr.member.lexeme});
                print_node(static_member_expr.expr);
            },
            .str_lit => |str_lit| {
                std.debug.print("StrLit: {s}\n", .{str_lit.value});
            },
            .string_type => {
                std.debug.print("StringType\n", .{});
            },
            .table_expr => |table_expr| {
                std.debug.print("TableExpr: \n", .{});
                for (table_expr.keys) |key| {
                    std.debug.print("  key: ", .{});
                    print_node(key);
                }
                for (table_expr.values) |value| {
                    std.debug.print("  value: ", .{});
                    print_node(value);
                }
            },
            .table_type => |table_type| {
                std.debug.print("TableType: \n", .{});
                print_node(table_type.key_type);
                print_node(table_type.element_type);
            },
            .try_expr => |try_expr| {
                std.debug.print("TryExpr: \n", .{});
                print_node(try_expr.expr);
            },
            .tuple_expr => |tuple_expr| {
                std.debug.print("TupleExpr: \n", .{});
                for (tuple_expr.exprs) |expr| {
                    print_node(expr);
                }
            },
            .tuple_type => |tuple_type| {
                std.debug.print("TupleType: \n", .{});
                for (tuple_type.element_types) |tup| {
                    print_node(tup);
                }
            },
            .unary_expr => |unary_expr| {
                std.debug.print("UnaryExpr: \n", .{});
                print_node(unary_expr.expr);
            },
            .union_type => |union_type| {
                std.debug.print("UnionType: \n", .{});
                print_node(union_type.left);
                print_node(union_type.right);
            },
            .while_stmt => |while_stmt| {
                std.debug.print("WhileStmt: \n", .{});
                print_node(while_stmt.condition);
                print_node(while_stmt.body);
            },
            .yield_stmt => |yield_stmt| {
                std.debug.print("YieldStmt: \n", .{});
                if (yield_stmt.expr) |expr| {
                    print_node(expr);
                }
            },
        }
        depth -= 1;
    }
};

// fn print_node(node: *AST.ASTNode) void {
//     switch (node.*) {
//         .program => |program| {},

//         .var_decl => |var_decl| {},
//         .fn_decl => |fn_decl| {},
//         .type_decl => |type_decl| {},
//         .struct_decl => |struct_decl| {},
//         .enum_decl => |enum_decl| {},
//         .error_decl => |error_decl| {},
//         .co_decl => |co_decl| {},
//         .use_decl => |use_decl| {},

//         .anon_co_expr => |co_expr| {},
//         .anon_fn_expr => |fn_expr| {},
//         .array_expr => |array_expr| {},
//         .array_type => |array_type| {},
//         .assign_expr => |assign_expr| {},
//         .binary_expr => |binary_expr| {},
//         .block_stmt => |block_stmt| {},
//         .bool_lit => |bool_lit| {},
//         .bool_type => |bool_type| {},
//         .break_stmt => |break_stmt| {},
//         .continue_stmt => |continue_stmt| {},
//         .call_expr => |call_expr| {},
//         .cast_expr => |cast_expr| {},
//         .co_type => |co_type| {},
//         .default_pat => |default_pat| {},
//         .dot_expr => |dot_expr| {},
//         .expr_stmt => |expr_stmt| {},
//         .float_lit => |float_lit| {},
//         .float_type => |float_type| {},
//         .fn_type => |fn_type| {},
//         .for_stmt => |for_stmt| {},
//         .give_stmt => |give_stmt| {},
//         .group_expr => |group_expr| {},
//         .identifier_expr => |identifier_expr| {},
//         .identifier_type => |identifier_type| {},
//         .index_expr => |index_expr| {},
//         .if_stmt => |if_stmt| {},
//         .int_lit => |int_lit| {},
//         .int_type => |int_type| {},
//         .match_expr => |match_expr| {},
//         .never_type => |never_type| {},
//         .new_expr => |new_expr| {},
//         .nil_lit => |nil_lit| {},
//         .nil_type => |nil_type| {},
//         .panic_stmt => |panic_stmt| {},
//         .range_type => |range_type| {},
//         .resume_expr => |resume_expr| {},
//         .return_stmt => |return_stmt| {},
//         .shape_expr => |shape_expr| {},
//         .shape_type => |shape_type| {},
//         .static_member_expr => |static_member_expr| {},
//         .str_lit => |str_lit| {},
//         .string_type => |string_type| {},
//         .table_expr => |table_expr| {},
//         .table_type => |table_type| {},
//         .try_expr => |try_expr| {},
//         .tuple_expr => |tuple_expr| {},
//         .tuple_type => |tuple_type| {},
//         .unary_expr => |unary_expr| {},
//         .union_type => |union_type| {},
//         .while_stmt => |while_stmt| {},
//         .yield_stmt => |yield_stmt| {},
//         else => {
//             unreachable;
//         },
//     }
// }
