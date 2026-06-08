const std = @import("std");
const AST = @import("ast.zig");
const TypeRegistry = @import("type_registry.zig");
const PrimitiveType = TypeRegistry.PrimitiveType;
const Environment = @import("environment.zig").Environment;
const EnvironmentError = @import("environment.zig").EnvironmentError;
const DiagnosticReporter = @import("../helpers/diagnostics.zig").DiagnosticsReporter;
const TypeRegistryError = TypeRegistry.TypeRegistryError;
const ShapeField = TypeRegistry.ShapeField;
const StructMethod = TypeRegistry.StructMethod;
const StructField = TypeRegistry.StructField;

pub const TypeCheckerError = error{
    /// The type of an expression does not match the expected type.
    TypeMismatch,
    /// The symbol is not defined in the current scope.
    UndefinedSymbol,
    /// The symbol is defined more than once in the current scope.
    DuplicateSymbol,
    /// The symbol is not callable.
    NotCallable,
    /// The number of arguments does not match the expected number.
    InvalidArgumentCount,
    /// The condition is not a boolean.
    NonBooleanCondition,
    /// The member access is not valid for the given type.
    InvalidMemberAccess,
    /// A return statement is missing in a function or coroutine.
    MissingReturn,
    /// The match expression is not exhaustive.
    NonExhaustiveMatch,
    /// The break statement is outside of a loop.
    BreakOutsideLoop,
    /// The continue statement is outside of a loop.
    ContinueOutsideLoop,
    /// The operation is not valid for the given type.
    InvalidOperation,
    /// The given expression is unknown.
    UnknownExpression,
    /// The index is out of bounds for the given type.
    IndexOutOfBounds,
} || EnvironmentError || TypeRegistryError || std.mem.Allocator.Error;

pub const StatementTermination = struct {
    return_: bool = false,
    panics: bool = false,
    break_: bool = false,
    continue_: bool = false,
    yield_: bool = false,
    give_: bool = false,
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    registry: *TypeRegistry.TypeRegistry,
    environment: *Environment,
    diagnostics: *DiagnosticReporter,
    file_path: []const u8,

    expected_return_type: ?AST.TypeId = null,
    expected_give_type: ?AST.TypeId = null,
    expected_yield_type: ?AST.TypeId = null,

    in_loop: bool = false,
    in_coroutine: bool = false,
    in_function: bool = false,

    pub fn init(allocator: std.mem.Allocator, registry: *TypeRegistry.TypeRegistry, global_environment: *Environment, diagnostics: *DiagnosticReporter, file_path: []const u8) TypeChecker {
        return .{ .allocator = allocator, .registry = registry, .environment = global_environment, .diagnostics = diagnostics, .file_path = file_path };
    }

    pub fn hoist(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!void {
        switch (node.*) {
            .program => |program| for (program.declarations) |decl| try self.hoist(decl),
            .fn_decl => |decl| {
                var param_types: std.ArrayList(AST.TypeId) = .empty;

                for (decl.params) |param| {
                    const param_id = try self.registry.resolve(param.type_annotation);
                    try param_types.append(self.allocator, param_id);
                }

                const return_id = try self.registry.resolve(decl.return_type_annotation);

                const fn_id = try self.registry.add_function_type(try param_types.toOwnedSlice(self.allocator), return_id);
                try self.environment.define(decl.name.lexeme, fn_id);
            },
            .co_decl => |decl| {
                var param_types: std.ArrayList(AST.TypeId) = .empty;

                for (decl.params) |param| {
                    const param_id = try self.registry.resolve(param.type_annotation);
                    try param_types.append(self.allocator, param_id);
                }

                const return_id = try self.registry.resolve(decl.return_type_annotation);
                const yield_id = try self.registry.resolve(decl.yield_type_annotation);
                const co_id = try self.registry.add_coroutine_type(try param_types.toOwnedSlice(self.allocator), return_id, yield_id);
                try self.environment.define(decl.name.lexeme, co_id);
            },
            .struct_decl => |decl| {
                var field_types: std.ArrayList(StructField) = .empty;
                var method_types: std.ArrayList(StructMethod) = .empty;

                for (decl.fields) |field| {
                    const field_type = try self.registry.resolve(field.type_annotation);
                    try field_types.append(self.allocator, .{ .name = field.name.lexeme, .type = field_type, .is_static = field.is_static, .is_pub = field.is_pub, .has_default = field.has_default });
                }
                for (decl.methods) |method| {
                    const method_type = try self.check_declaration_type(method.method);
                    try method_types.append(self.allocator, .{ .name = method.name.lexeme, .type = method_type, .is_static = method.is_static, .is_pub = method.is_pub });
                }

                // Register shape type under the struct name
                const struct_id = try self.registry.add_struct_type(decl.name.lexeme, try field_types.toOwnedSlice(self.allocator), try method_types.toOwnedSlice(self.allocator));
                try self.environment.define(decl.name.lexeme, struct_id);
            },
            .type_decl => |decl| {
                const type_id = try self.registry.resolve(decl.type_annotation);
                try self.environment.define(decl.name.lexeme, type_id);
            },
            .enum_decl => |decl| {
                var variants: std.ArrayList([]const u8) = .empty;
                for (decl.variants) |variant| {
                    try variants.append(self.allocator, variant.lexeme);
                }
                const enum_id = try self.registry.add_enum_type(decl.name.lexeme, try variants.toOwnedSlice(self.allocator));
                try self.environment.define(decl.name.lexeme, enum_id);
            },
            .error_decl => |decl| {
                var variants: std.ArrayList([]const u8) = .empty;
                for (decl.variants) |variant| {
                    try variants.append(self.allocator, variant.lexeme);
                }
                const error_id = try self.registry.add_error_type(decl.name.lexeme, try variants.toOwnedSlice(self.allocator));
                try self.environment.define(decl.name.lexeme, error_id);
            },
            else => {},
        }
    }

    pub fn check(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!StatementTermination {
        switch (node.*) {
            .program => |program| {
                try self.hoist(node);
                var last: StatementTermination = .{};
                for (program.declarations) |decl| {
                    last = try self.check(decl);
                }
                return last;
            },
            .var_decl => |decl| {
                const expr_type = try self.check_expression(decl.initializer);
                var target_type = expr_type;

                if (decl.type_annotation) |annotated| {
                    target_type = try self.registry.resolve(annotated);
                    if (!try self.is_compatible(target_type, expr_type)) {
                        try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.column, .line = decl.line, .stage = .TypeChecker, .severity = .Error, .message = "Type mismatch" });
                        return TypeCheckerError.TypeMismatch;
                    }
                }
                if (self.environment.contains(decl.name.lexeme)) {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.name.column, .line = decl.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Duplicate symbol", .hint = "Symbol is already defined." });
                    return TypeCheckerError.DuplicateSymbol;
                }
                try self.environment.define(decl.name.lexeme, target_type);

                return .{};
            },
            .fn_decl => |decl| {
                const fn_id = self.environment.lookup(decl.name.lexeme) catch {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.name.column, .line = decl.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Undefined symbol", .hint = "Symbol is not defined." });
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(fn_id);
                if (type_info != .function) {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.name.column, .line = decl.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Not callable", .hint = "Symbol is not a function." });
                    return TypeCheckerError.NotCallable;
                }

                // Track expected return type
                const prev_return = self.expected_return_type;
                self.expected_return_type = type_info.function.ret;
                defer self.expected_return_type = prev_return;

                // Push function scope
                var local_env = Environment.init(self.allocator, self.environment, self.diagnostics, self.file_path);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                // Define params locally
                for (decl.params, type_info.function.args) |param, param_id| {
                    try self.environment.define(param.name.lexeme, param_id);
                }

                const prev_in_func = self.in_function;
                self.in_function = true;
                defer self.in_function = prev_in_func;
                const body_term = try self.check(decl.body);

                const needs_return = type_info.function.ret != @intFromEnum(PrimitiveType.Nil) and type_info.function.ret != @intFromEnum(PrimitiveType.Never);

                if (needs_return and !body_term.return_ and !body_term.panics) {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.name.column, .line = decl.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Missing return", .hint = "Function is missing a return statement." });
                    return TypeCheckerError.MissingReturn;
                }
                return .{};
            },
            .type_decl => { // handled at hoist phase
                return .{};
            },

            .struct_decl => |decl| {
                for (decl.fields) |field| {
                    _ = try self.check(field.type_annotation);
                }
                for (decl.methods) |method| {
                    _ = try self.check(method.method);
                }
                return .{};
            },
            .co_decl => |decl| {
                const fn_id = self.environment.lookup(decl.name.lexeme) catch {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.name.column, .line = decl.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Undefined symbol", .hint = "Symbol is not defined." });
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(fn_id);
                if (type_info != .coroutine) {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.name.column, .line = decl.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Not callable", .hint = "Symbol is not a coroutine." });
                    return TypeCheckerError.NotCallable;
                }

                // Track expected return type
                const prev_return = self.expected_return_type;
                self.expected_return_type = type_info.coroutine.ret;
                defer self.expected_return_type = prev_return;

                // track expected yield type
                const prev_yield = self.expected_yield_type;
                self.expected_yield_type = type_info.coroutine.yield;
                defer self.expected_yield_type = prev_yield;

                // Push function scope
                var local_env = Environment.init(self.allocator, self.environment, self.diagnostics, self.file_path);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                // Define params locally
                for (decl.params, type_info.coroutine.args) |param, param_id| {
                    try self.environment.define(param.name.lexeme, param_id);
                }

                const body_term = try self.check(decl.body);
                const needs_return = type_info.coroutine.ret != @intFromEnum(PrimitiveType.Nil) and type_info.coroutine.ret != @intFromEnum(PrimitiveType.Never);
                if (needs_return and !body_term.return_ and !body_term.panics) {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.name.column, .line = decl.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Missing return", .hint = "Coroutine is missing a return statement." });
                    return TypeCheckerError.MissingReturn;
                }
                return .{};
            },
            .enum_decl => { // fully handled in the hoist phase
                return .{};
            },
            .error_decl => { // fully handled in the hoist phase
                return .{};
            },
            .use_decl => |decl| {
                if (decl.module.lexeme.len == 0) {
                    try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = decl.module.column, .line = decl.module.line, .stage = .TypeChecker, .severity = .Error, .message = "Invalid operation", .hint = "Module name cannot be empty." });
                    return TypeCheckerError.InvalidOperation;
                }
                for (decl.items) |item| {
                    if (item.name.lexeme.len == 0) {
                        try self.diagnostics.add_diagnostic(.{ .file_path = self.file_path, .column = item.name.column, .line = item.name.line, .stage = .TypeChecker, .severity = .Error, .message = "Invalid operation", .hint = "Import item name cannot be empty." });
                        return TypeCheckerError.InvalidOperation;
                    }
                }
                return .{};
            },
            .block_stmt => |stmt| {
                var local_env = Environment.init(self.allocator, self.environment, self.diagnostics, self.file_path);
                defer local_env.deinit();

                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;
                var last: StatementTermination = .{};
                for (stmt.stmts) |child| {
                    last = try self.check(child);
                }
                return last;
            },
            .return_stmt => |stmt| {
                var provided_type = @intFromEnum(PrimitiveType.Nil);
                if (stmt.expr) |v| {
                    provided_type = try self.check_expression(v);
                }

                if (self.expected_return_type) |expected_type| {
                    if (!try self.is_compatible(expected_type, provided_type)) {
                        return TypeCheckerError.TypeMismatch;
                    }
                } else {
                    return TypeCheckerError.InvalidOperation; // Return outside of function
                }
                return .{ .return_ = true };
            },
            .yield_stmt => |stmt| {
                var provided_type = @intFromEnum(PrimitiveType.Nil);
                if (stmt.expr) |v| {
                    provided_type = try self.check_expression(v);
                }

                if (self.expected_yield_type) |expected_type| {
                    if (!try self.is_compatible(expected_type, provided_type)) {
                        return TypeCheckerError.TypeMismatch;
                    }
                } else {
                    return TypeCheckerError.InvalidOperation; // Yield outside of coroutine
                }
                return .{ .yield_ = true };
            },
            .give_stmt => |stmt| {
                const provided_type = try self.check_expression(stmt.expr);

                if (self.expected_give_type) |expected_type| {
                    if (!try self.is_compatible(expected_type, provided_type)) {
                        return TypeCheckerError.TypeMismatch;
                    }
                } else {
                    // first give in a match — set the expected type
                    self.expected_give_type = provided_type;
                }
                return .{ .give_ = true };
            },
            .while_stmt => |stmt| {
                const condition_type = try self.check_expression(stmt.condition);
                if (condition_type != @intFromEnum(PrimitiveType.Bool)) {
                    return TypeCheckerError.TypeMismatch;
                }
                const prev_loop = self.in_loop;
                self.in_loop = true;
                _ = try self.check(stmt.body);
                self.in_loop = prev_loop;
                return .{};
            },
            .for_stmt => |stmt| {
                var local_env = Environment.init(self.allocator, self.environment, self.diagnostics, self.file_path);
                defer local_env.deinit();

                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                try self.environment.define(stmt.iterator_name.lexeme, @intFromEnum(PrimitiveType.Int));
                const prev_loop = self.in_loop;
                self.in_loop = true;
                _ = try self.check(stmt.body);
                self.in_loop = prev_loop;
                return .{};
            },
            .if_stmt => |stmt| {
                const condition_type = try self.check_expression(stmt.condition);
                if (condition_type != @intFromEnum(PrimitiveType.Bool)) {
                    return TypeCheckerError.NonBooleanCondition;
                }
                const then_term = try self.check(stmt.then_branch);
                if (stmt.else_branch) |else_branch| {
                    const else_term = try self.check(else_branch);
                    return .{
                        .return_ = then_term.return_ and else_term.return_,
                        .panics = then_term.panics and else_term.panics,
                        .break_ = then_term.break_ and else_term.break_,
                        .continue_ = then_term.continue_ and else_term.continue_,
                        .yield_ = then_term.yield_ and else_term.yield_,
                        .give_ = then_term.give_ and else_term.give_,
                    };
                }
                return .{};
            },
            .break_stmt => {
                if (!self.in_loop) return TypeCheckerError.BreakOutsideLoop;
                return .{ .break_ = true };
            },
            .continue_stmt => {
                if (!self.in_loop) return TypeCheckerError.ContinueOutsideLoop;
                return .{ .continue_ = true };
            },
            .expr_stmt => |stmt| {
                var term: StatementTermination = .{};
                _ = try self.checkExpressionTerm(stmt.expr, &term);
                return term;
            },
            .panic_stmt => |stmt| {
                _ = try self.check_expression(stmt.expr); // any expression type is allowed - so we can ignore the result
                return .{ .panics = true, .return_ = true };
            },
            else => {
                return .{};
            },
        }
    }

    fn check_declaration_type(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!AST.TypeId {
        switch (node.*) {
            .fn_decl => |decl| {
                var param_types: std.ArrayList(AST.TypeId) = .empty;
                defer param_types.deinit(self.allocator);
                for (decl.params) |param| {
                    const param_type = try self.registry.resolve(param.type_annotation);
                    try param_types.append(self.allocator, param_type);
                }
                const return_type = try self.registry.resolve(decl.return_type_annotation);
                const fn_type = try self.registry.add_function_type(try param_types.toOwnedSlice(self.allocator), return_type);
                return fn_type;
            },
            .co_decl => |decl| {
                var param_types: std.ArrayList(AST.TypeId) = .empty;
                defer param_types.deinit(self.allocator);
                for (decl.params) |param| {
                    const param_type = try self.registry.resolve(param.type_annotation);
                    try param_types.append(self.allocator, param_type);
                }
                const return_type = try self.registry.resolve(decl.return_type_annotation);
                const yield_type = try self.registry.resolve(decl.yield_type_annotation);
                const co_type = try self.registry.add_coroutine_type(try param_types.toOwnedSlice(self.allocator), return_type, yield_type);
                return co_type;
            },
            else => {
                return TypeCheckerError.UnknownExpression;
            },
        }
    }

    fn check_expression(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!AST.TypeId {
        return self.checkExpressionTerm(node, null);
    }

    fn checkExpressionTerm(self: *TypeChecker, node: *AST.ASTNode, out_term: ?*StatementTermination) TypeCheckerError!AST.TypeId {
        return switch (node.*) {
            .assign_expr => |expr| {
                const right_type = try self.check_expression(expr.right);

                // if assigning to a variable
                if (expr.left.* == .identifier_expr or expr.left.* == .dot_expr) {
                    const left_type = try self.check_expression(expr.left);
                    if (!try self.is_compatible(left_type, right_type)) {
                        return TypeCheckerError.TypeMismatch;
                    }

                    const op = expr.operator.lexeme;
                    if (!std.mem.eql(u8, op, "=")) {
                        const is_numeric = left_type == @intFromEnum(PrimitiveType.Int) or left_type == @intFromEnum(PrimitiveType.Float);

                        if (std.mem.eql(u8, op, "-=") or std.mem.eql(u8, op, "*=") or std.mem.eql(u8, op, "/=") or std.mem.eql(u8, op, "+=")) {
                            if (!is_numeric) {
                                return TypeCheckerError.InvalidOperation;
                            }
                        }
                        expr.resolved_type = left_type;
                        return left_type;
                    }

                    expr.resolved_type = right_type;
                    return right_type;
                }

                return TypeCheckerError.InvalidOperation; //
            },
            .identifier_expr => |expr| {
                const expr_type = self.environment.lookup(expr.name.lexeme) catch {
                    return TypeCheckerError.UndefinedSymbol;
                };
                expr.resolved_type = expr_type;
                return expr_type;
            },
            .cast_expr => |expr| {
                const left_type = try self.check_expression(expr.expr);
                const right_type = try self.registry.resolve(expr.type);

                if (!try self.is_compatible(right_type, left_type)) return TypeCheckerError.TypeMismatch;
                expr.resolved_type = right_type;
                return right_type;
            },
            .unary_expr => |expr| {
                const token = expr.operator;
                const expr_type = try self.check_expression(expr.expr);
                if (std.mem.eql(u8, token.lexeme, "-")) {
                    if (expr_type == @intFromEnum(PrimitiveType.Float) or expr_type == @intFromEnum(PrimitiveType.Int)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, token.lexeme, "~")) {
                    if (expr_type == @intFromEnum(PrimitiveType.Int)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, token.lexeme, "not")) {
                    if (expr_type == @intFromEnum(PrimitiveType.Bool)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    return TypeCheckerError.InvalidOperation;
                } else {
                    return TypeCheckerError.InvalidOperation;
                }
            },
            .resume_expr => |expr| {
                const expr_typeid = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(expr_typeid);
                if (type_info != .coroutine) return TypeCheckerError.InvalidOperation;
                const union_type = try self.registry.add_union_type(type_info.coroutine.yield, type_info.coroutine.ret);
                expr.resolved_type = union_type;
                return union_type;
            },
            .try_expr => |expr| {
                const expr_typeid = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(expr_typeid);
                if (type_info != ._union) return TypeCheckerError.InvalidOperation;
                const left_err = self.registry.get_type_info(type_info._union.left) == ._error;
                const right_err = self.registry.get_type_info(type_info._union.right) == ._error;
                if (!left_err and !right_err) return TypeCheckerError.InvalidOperation;
                const union_type = try self.registry.add_union_type(type_info._union.left, type_info._union.right);
                expr.resolved_type = union_type;
                return union_type;
            },

            .binary_expr => |expr| {
                const left_type: AST.TypeId = try self.check_expression(expr.left);
                const right_type: AST.TypeId = try self.check_expression(expr.right);
                const op = expr.operator.lexeme;

                if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "**") or std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) {
                    const is_int = left_type == @intFromEnum(PrimitiveType.Int) and right_type == @intFromEnum(PrimitiveType.Int);
                    const is_float = (left_type == @intFromEnum(PrimitiveType.Float) or left_type == @intFromEnum(PrimitiveType.Int)) and
                        (right_type == @intFromEnum(PrimitiveType.Float) or right_type == @intFromEnum(PrimitiveType.Int));

                    if (is_int) {
                        expr.resolved_type = @intFromEnum(PrimitiveType.Int);
                        return expr.resolved_type;
                    } else if (is_float) {
                        expr.resolved_type = @intFromEnum(PrimitiveType.Float);
                        return expr.resolved_type;
                    }
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=")) {
                    if (left_type != right_type) return TypeCheckerError.TypeMismatch;
                    expr.resolved_type = @intFromEnum(PrimitiveType.Bool);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "or")) {
                    if (left_type != @intFromEnum(PrimitiveType.Bool) or right_type != @intFromEnum(PrimitiveType.Bool)) return TypeCheckerError.TypeMismatch;
                    expr.resolved_type = @intFromEnum(PrimitiveType.Bool);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "++")) { // string concatenation
                    if (left_type != @intFromEnum(PrimitiveType.String) or right_type != @intFromEnum(PrimitiveType.String)) return TypeCheckerError.TypeMismatch;
                    expr.resolved_type = @intFromEnum(PrimitiveType.String);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "..")) { // range expression
                    if (left_type != @intFromEnum(PrimitiveType.Int) or right_type != @intFromEnum(PrimitiveType.Int)) return TypeCheckerError.TypeMismatch;
                    const range_type = try self.registry.add_range_type(left_type, right_type);

                    expr.resolved_type = range_type;
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, ">>") or std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, "|") or std.mem.eql(u8, op, "&") or std.mem.eql(u8, op, "^")) {
                    if (left_type != @intFromEnum(PrimitiveType.Int) or right_type != @intFromEnum(PrimitiveType.Int)) return TypeCheckerError.TypeMismatch;
                    expr.resolved_type = @intFromEnum(PrimitiveType.Int);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "orelse")) {
                    // orelse is only valid for T | Nil and T | Error
                    const left_type_info = self.registry.get_type_info(left_type);
                    const right_type_info = self.registry.get_type_info(right_type);

                    const left_nil = left_type == @intFromEnum(PrimitiveType.Nil);
                    const right_nil = right_type == @intFromEnum(PrimitiveType.Nil);
                    const left_error = left_type_info == ._error;
                    const right_error = right_type_info == ._error;
                    if (!(left_nil or right_nil) and !(left_error or right_error)) return TypeCheckerError.TypeMismatch;
                    if (left_nil) {
                        expr.resolved_type = right_type;
                        return expr.resolved_type;
                    } else if (right_nil) {
                        expr.resolved_type = left_type;
                        return expr.resolved_type;
                    } else if (left_error) {
                        expr.resolved_type = right_type;
                        return expr.resolved_type;
                    } else if (right_error) {
                        expr.resolved_type = left_type;
                        return expr.resolved_type;
                    }
                    return TypeCheckerError.TypeMismatch;
                } else {
                    return TypeCheckerError.InvalidOperation;
                }
            },
            .call_expr => |expr| {
                // check if the call target is a callable type. Otherwise error
                const expr_type = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(expr_type);
                switch (type_info) {
                    .function => |info| {
                        if (expr.args.len != info.args.len) {
                            return TypeCheckerError.InvalidArgumentCount;
                        }
                        for (expr.args, 0..) |arg, index| {
                            const arg_type = try self.check_expression(arg);
                            if (arg_type != info.args[index]) {
                                return TypeCheckerError.TypeMismatch;
                            }
                        }
                        expr.resolved_type = info.ret;
                    },
                    .coroutine => |info| {
                        if (expr.args.len != info.args.len) {
                            return TypeCheckerError.InvalidArgumentCount;
                        }
                        for (expr.args, 0..) |arg, index| {
                            const arg_type = try self.check_expression(arg);
                            if (arg_type != info.args[index]) {
                                return TypeCheckerError.TypeMismatch;
                            }
                        }
                        expr.resolved_type = expr_type;
                    },
                    else => {
                        return TypeCheckerError.InvalidOperation;
                    },
                }
                return expr.resolved_type;
            },
            .index_expr => |expr| {
                // check if the index target is an indexable type. Otherwise error
                const expr_type = try self.check_expression(expr.expr);
                const index_type = try self.check_expression(expr.index);

                const expr_info = self.registry.get_type_info(expr_type);

                switch (expr_info) {
                    .array => |arr_info| {
                        if (index_type != @intFromEnum(PrimitiveType.Int)) {
                            return TypeCheckerError.TypeMismatch;
                        }
                        expr.resolved_type = arr_info;
                        return arr_info;
                    },
                    .table => |tbl_info| {
                        if (index_type != tbl_info.key) {
                            return TypeCheckerError.TypeMismatch;
                        }
                        expr.resolved_type = tbl_info.value;
                        return tbl_info.value;
                    },
                    .primitive => |prim| {
                        switch (prim) {
                            .String => {
                                if (index_type != @intFromEnum(PrimitiveType.Int)) {
                                    return TypeCheckerError.TypeMismatch;
                                }
                                expr.resolved_type = @intFromEnum(PrimitiveType.String);
                                return @intFromEnum(PrimitiveType.String);
                            },
                            else => {
                                return TypeCheckerError.TypeMismatch;
                            },
                        }
                    },
                    else => {
                        return TypeCheckerError.TypeMismatch;
                    },
                }
            },
            .dot_expr => |expr| {
                const obj_type = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(obj_type);

                switch (type_info) {
                    .shape => |shape| {
                        for (shape) |field| {
                            if (std.mem.eql(u8, field.name, expr.member.lexeme)) {
                                expr.resolved_type = field.type;
                                return field.type;
                            }
                        }
                    },
                    .tuple => |tuple| {
                        const index_value = std.fmt.parseInt(u8, expr.member.lexeme, 10) catch {
                            return TypeCheckerError.InvalidMemberAccess;
                        };
                        if (index_value >= tuple.len) return TypeCheckerError.IndexOutOfBounds;
                        expr.resolved_type = tuple[index_value];
                        return tuple[index_value];
                    },
                    ._struct => |_struct| {
                        for (_struct.fields) |field| {
                            if (std.mem.eql(u8, field.name, expr.member.lexeme) and !field.is_static) {
                                expr.resolved_type = field.type;
                                return field.type;
                            }
                        }
                        for (_struct.methods) |method| {
                            if (std.mem.eql(u8, method.name, expr.member.lexeme) and !method.is_static) {
                                const method_type = self.registry.get_type_info(method.type);
                                if (method_type != .function and method_type != .coroutine) {
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                expr.resolved_type = method.type;
                                return method.type;
                            }
                        }
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                    .coroutine => {
                        // corotines have suspended, finished, and running members - which are boolean values
                        if (std.mem.eql(u8, expr.member.lexeme, "suspended") or std.mem.eql(u8, expr.member.lexeme, "finished") or std.mem.eql(u8, expr.member.lexeme, "running")) {
                            expr.resolved_type = @intFromEnum(PrimitiveType.Bool);
                            return @intFromEnum(PrimitiveType.Bool);
                        } else {
                            return TypeCheckerError.InvalidMemberAccess;
                        }
                    },
                    else => {
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                }
                return TypeCheckerError.InvalidMemberAccess;
            },
            .static_member_expr => |expr| {
                const obj_type = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(obj_type);

                switch (type_info) {
                    ._struct => |_struct| {
                        for (_struct.methods) |method| {
                            if (std.mem.eql(u8, method.name, expr.member.lexeme) and method.is_static) {
                                expr.resolved_type = method.type;
                                return method.type;
                            }
                        }
                        for (_struct.fields) |field| {
                            if (std.mem.eql(u8, field.name, expr.member.lexeme) and field.is_static) {
                                expr.resolved_type = field.type;
                                return field.type;
                            }
                        }
                    },
                    ._error => |existing_error| {
                        for (existing_error.variants) |variant| {
                            if (std.mem.eql(u8, variant, expr.member.lexeme)) {
                                expr.resolved_type = obj_type;
                                return obj_type;
                            }
                        }
                    },
                    ._enum => |existing_enum| {
                        for (existing_enum.variants) |variant| {
                            if (std.mem.eql(u8, variant, expr.member.lexeme)) {
                                expr.resolved_type = obj_type;
                                return obj_type;
                            }
                        }
                    },
                    else => {},
                }
                return TypeCheckerError.InvalidMemberAccess;
            },

            .array_expr => |expr| {
                var current_id: ?AST.TypeId = null;
                for (expr.elements) |element| {
                    if (current_id == null) {
                        current_id = try self.check_expression(element);
                        continue;
                    }
                    if (!try self.is_compatible(current_id.?, try self.check_expression(element))) {
                        return TypeCheckerError.TypeMismatch;
                    }
                }
                if (current_id == null) {
                    current_id = @intFromEnum(PrimitiveType.Nil); // nil
                }
                const array_type = try self.registry.add_array_type(current_id.?);
                expr.resolved_type = array_type;
                return array_type;
            },
            .shape_expr => |expr| {
                var field_types: std.ArrayList(ShapeField) = .empty;
                defer field_types.deinit(self.allocator);

                for (expr.fields) |field| {
                    const field_type = try self.registry.resolve(field.type_annotation);
                    try field_types.append(self.allocator, .{ .name = field.name.lexeme, .type = field_type });
                }

                const shape_type = try self.registry.add_shape_type(field_types.items);
                expr.resolved_type = shape_type;
                return shape_type;
            },
            .group_expr => |expr| {
                const expr_type = try self.check_expression(expr.expr);
                expr.resolved_type = expr_type;
                return expr_type;
            },
            .tuple_expr => |expr| {
                var inner_types: std.ArrayList(AST.TypeId) = .empty;
                defer inner_types.deinit(self.allocator);
                for (expr.exprs) |v| {
                    const expr_type = try self.check_expression(v);
                    try inner_types.append(self.allocator, expr_type);
                }
                const tuple_type = try self.registry.add_tuple_type(try inner_types.toOwnedSlice(self.allocator));
                expr.resolved_type = tuple_type;
                return tuple_type;
            },
            .table_expr => |expr| {
                var key_type: ?AST.TypeId = null;
                var value_type: ?AST.TypeId = null;

                for (expr.keys) |key| {
                    const key_type_id = try self.check_expression(key);
                    if (key_type == null) {
                        key_type = key_type_id;
                    } else if (key_type != null) {
                        if (key_type != key_type_id) {
                            return TypeCheckerError.TypeMismatch;
                        }
                    }
                }

                for (expr.values) |value| {
                    const value_type_id = try self.check_expression(value);
                    if (value_type == null) {
                        value_type = value_type_id;
                    } else if (value_type != null) {
                        if (value_type != value_type_id) {
                            return TypeCheckerError.TypeMismatch;
                        }
                    }
                }

                if (key_type == null) {
                    return TypeCheckerError.UnknownType;
                }
                if (value_type == null) {
                    return TypeCheckerError.UnknownType;
                }
                const table_type = try self.registry.add_table_type(key_type.?, value_type.?);
                expr.resolved_type = table_type;
                return table_type;
            },
            .new_expr => |expr| {
                const struct_typeid = self.environment.lookup(expr.struct_name.lexeme) catch {
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(struct_typeid);
                if (type_info != ._struct) return TypeCheckerError.InvalidOperation;

                const shape_fields = type_info._struct.fields;
                var provided_count: usize = 0;

                for (expr.fields) |provided_field| {
                    const val_type = try self.check_expression(provided_field.value);

                    var matched = false;
                    for (shape_fields) |sf| {
                        if (std.mem.eql(u8, sf.name, provided_field.name.lexeme)) {
                            if (!try self.is_compatible(sf.type, val_type)) return TypeCheckerError.TypeMismatch;
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) return TypeCheckerError.InvalidMemberAccess;
                    provided_count += 1;
                }

                // Count fields that have no default — those are required
                var required_count: usize = 0;
                for (shape_fields) |sf| {
                    if (!sf.has_default) required_count += 1;
                }
                if (provided_count < required_count or provided_count > shape_fields.len) return TypeCheckerError.InvalidArgumentCount;

                expr.resolved_type = struct_typeid;
                return struct_typeid;
            },
            .match_expr => |expr| {
                const prev_give = self.expected_give_type;
                self.expected_give_type = null;
                defer self.expected_give_type = prev_give;
                const expr_typeid = try self.check_expression(expr.expr);
                try self.check_match_exhaustiveness(expr_typeid, expr);
                var all_return = expr.cases.len > 0;
                for (expr.cases) |case| {
                    // default pattern is catch-all - skip type compatibility
                    if (case.pattern.* != .default_pat) {
                        const case_typeid = try self.check_expression(case.pattern);
                        if (!try self.is_compatible(expr_typeid, case_typeid)) {
                            return TypeCheckerError.TypeMismatch;
                        }
                    }
                    const case_term = try self.check(case.stmt); // check the body of the case
                    if (!case_term.return_ and !case_term.panics) {
                        all_return = false;
                    }
                }
                if (out_term) |t| {
                    t.* = if (all_return) .{ .return_ = true, .panics = false, .break_ = false, .continue_ = false, .yield_ = false, .give_ = false } else .{};
                }
                if (self.expected_give_type) |typeid| {
                    expr.resolved_type = typeid;
                    return typeid;
                } else {
                    // there was not a give type, so we return nil
                    expr.resolved_type = @intFromEnum(PrimitiveType.Nil);
                    return @intFromEnum(PrimitiveType.Nil);
                }
            },
            .anon_fn_expr => |expr| {
                var arg_types: std.ArrayList(u32) = .empty;
                defer arg_types.deinit(self.allocator);

                for (expr.params) |param| {
                    const param_typeid = try self.registry.resolve(param.type_annotation);
                    try arg_types.append(self.allocator, param_typeid);
                }
                var ret_typeid = @intFromEnum(PrimitiveType.Nil);
                if (expr.return_type_annotation) |ret_annot| {
                    ret_typeid = try self.registry.resolve(ret_annot);
                }

                const function_typeid = try self.registry.add_function_type(try arg_types.toOwnedSlice(self.allocator), ret_typeid);

                // Typecheck inner body
                const prev_ret = self.expected_return_type;
                self.expected_return_type = ret_typeid;
                defer self.expected_return_type = prev_ret;

                _ = try self.check(expr.body);

                expr.resolved_type = function_typeid;
                return function_typeid;
            },
            .int_lit => |lit| {
                lit.resolved_type = @intFromEnum(PrimitiveType.Int);
                return lit.resolved_type;
            },
            .float_lit => |lit| {
                lit.resolved_type = @intFromEnum(PrimitiveType.Float);
                return lit.resolved_type;
            },
            .str_lit => |lit| {
                lit.resolved_type = @intFromEnum(PrimitiveType.String);
                return lit.resolved_type;
            },
            .bool_lit => |lit| {
                lit.resolved_type = @intFromEnum(PrimitiveType.Bool);
                return lit.resolved_type;
            },
            .nil_lit => |lit| {
                lit.resolved_type = @intFromEnum(PrimitiveType.Nil);
                return lit.resolved_type;
            },
            else => {
                return TypeCheckerError.UnknownExpression;
            },
        };
    }

    fn check_match_exhaustiveness(self: *TypeChecker, matched_type: AST.TypeId, expr: *AST.MatchExpr) TypeCheckerError!void {
        const type_info = self.registry.get_type_info(matched_type);
        const variants: []const []const u8 = switch (type_info) {
            ._enum => |e| e.variants,
            ._error => |e| e.variants,
            else => return, // not an enum/error, skip exhaustiveness check
        };

        // If any case pattern is not a static_member_expr, assume catch-all and skip
        var has_catch_all = false;
        for (expr.cases) |case| {
            if (case.pattern.* != .static_member_expr) {
                has_catch_all = true;
                break;
            }
        }
        if (has_catch_all) return;

        // Collect covered variants
        var covered = std.ArrayList([]const u8).empty;
        defer covered.deinit(self.allocator);
        for (expr.cases) |case| {
            if (case.pattern.* == .static_member_expr) {
                try covered.append(self.allocator, case.pattern.static_member_expr.member.lexeme);
            }
        }

        // Check all variants are covered
        for (variants) |variant| {
            var found = false;
            for (covered.items) |covered_variant| {
                if (std.mem.eql(u8, covered_variant, variant)) {
                    found = true;
                    break;
                }
            }
            if (!found) return TypeCheckerError.NonExhaustiveMatch;
        }
    }

    fn is_compatible(self: *TypeChecker, target: AST.TypeId, source: AST.TypeId) TypeCheckerError!bool {
        if (target == source) return true;

        const source_info = self.registry.get_type_info(source);
        if (source_info == ._union) {
            return (try self.is_compatible(target, source_info._union.left)) and (try self.is_compatible(target, source_info._union.right));
        }

        const target_info = self.registry.get_type_info(target);
        return switch (target_info) {
            ._union => |u| {
                // source is compatible if it fits either side of target union
                return (try self.is_compatible(u.left, source)) or (try self.is_compatible(u.right, source));
            },
            else => return false,
        };
    }
};
