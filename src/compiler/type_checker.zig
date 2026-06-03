const std = @import("std");
const AST = @import("ast.zig");
const TypeRegistry = @import("type_registry.zig");
const PrimitiveType = TypeRegistry.PrimitiveType;
const Environment = @import("environment.zig").Environment;
const EnvironmentError = @import("environment.zig").EnvironmentError;
const TypeRegistryError = TypeRegistry.TypeRegistryError;
const ShapeField = TypeRegistry.ShapeField;

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
    MissingReturn,
    ImmutableAssignment,
    NonExhaustiveMatch,
    InvalidOperation,
    UnknownExpression,
    /// The index is out of bounds for the given type.
    IndexOutOfBounds,
} || EnvironmentError || TypeRegistryError || std.mem.Allocator.Error;

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    registry: *TypeRegistry.TypeRegistry,
    environment: *Environment,

    expected_return_type: ?AST.TypeId = null,
    expected_give_type: ?AST.TypeId = null,
    expected_yield_type: ?AST.TypeId = null,

    pub fn init(allocator: std.mem.Allocator, registry: *TypeRegistry.TypeRegistry, global_environment: *Environment) TypeChecker {
        return .{ .allocator = allocator, .registry = registry, .environment = global_environment };
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
                var field_types: std.ArrayList(ShapeField) = .empty;

                for (decl.fields) |field| {
                    const field_type = try self.registry.resolve(field.type_annotation);
                    try field_types.append(self.allocator, .{ .name = field.name.lexeme, .type = field_type });
                }

                // Register shape type under the struct name
                const struct_id = try self.registry.add_struct_type(decl.name.lexeme, try field_types.toOwnedSlice(self.allocator));
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

    pub fn check(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!void {
        switch (node.*) {
            .program => |program| {
                try self.hoist(node);
                for (program.declarations) |decl| try self.check(decl);
            },
            .var_decl => |decl| {
                const expr_type = try self.check_expression(decl.initializer);
                var target_type = expr_type;

                if (decl.type_annotation) |annotated| {
                    target_type = try self.registry.resolve(annotated);
                    if (!try self.is_compatible(target_type, expr_type)) {
                        return TypeCheckerError.TypeMismatch;
                    }
                }
                if (self.environment.lookup(decl.name.lexeme)) |_| {
                    return;
                } else |_| {
                    try self.environment.define(decl.name.lexeme, target_type);
                }
            },
            .fn_decl => |decl| {
                const fn_id = self.environment.lookup(decl.name.lexeme) catch {
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(fn_id);
                if (type_info != .function) return TypeCheckerError.NotCallable;

                // Track expected return type
                const prev_return = self.expected_return_type;
                self.expected_return_type = type_info.function.ret;
                defer self.expected_return_type = prev_return;

                // Push function scope
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                // Define params locally
                for (decl.params, type_info.function.args) |param, param_id| {
                    try self.environment.define(param.name.lexeme, param_id);
                }

                try self.check(decl.body);
            },
            .type_decl => |decl| {
                try self.check(decl.type_annotation);
            },
            .struct_decl => |decl| {
                for (decl.fields) |field| {
                    try self.check(field.type_annotation);
                }
                for (decl.methods) |method| {
                    try self.check(method);
                }
            },
            .co_decl => |decl| {
                const fn_id = self.environment.lookup(decl.name.lexeme) catch {
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(fn_id);
                if (type_info != .coroutine) return TypeCheckerError.NotCallable;

                // Track expected return type
                const prev_return = self.expected_return_type;
                self.expected_return_type = type_info.coroutine.ret;
                defer self.expected_return_type = prev_return;

                // track expected yield type
                const prev_yield = self.expected_return_type;
                self.expected_return_type = type_info.coroutine.yield;
                defer self.expected_return_type = prev_yield;

                // Push function scope
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                // Define params locally
                for (decl.params, type_info.coroutine.args) |param, param_id| {
                    try self.environment.define(param.name.lexeme, param_id);
                }

                try self.check(decl.body);
            },
            .enum_decl => {}, // fully handled in the hoist phase
            .error_decl => {}, // fully handled in the hoist phase
            .use_decl => {
                // TODO: compilation of imported script
            },
            .block_stmt => |stmt| {
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();

                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;
                for (stmt.stmts) |child| {
                    try self.check(child);
                }
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
            },
            .give_stmt => |stmt| {
                const provided_type = try self.check_expression(stmt.expr);

                if (self.expected_give_type) |expected_type| {
                    if (!try self.is_compatible(expected_type, provided_type)) {
                        return TypeCheckerError.TypeMismatch;
                    }
                } else {
                    return TypeCheckerError.InvalidOperation; // give outside of match
                }
            },
            .while_stmt => |stmt| {
                const condition_type = try self.check_expression(stmt.condition);
                if (condition_type != @intFromEnum(PrimitiveType.Bool)) {
                    return TypeCheckerError.TypeMismatch;
                }
                try self.check(stmt.body);
            },
            .for_stmt => |stmt| {
                _ = stmt;
            },
            .if_stmt => |stmt| {
                const condition_type = try self.check_expression(stmt.condition);
                if (condition_type != @intFromEnum(PrimitiveType.Bool)) {
                    return TypeCheckerError.NonBooleanCondition;
                }
                try self.check(stmt.then_branch);
                if (stmt.else_branch) |else_branch| {
                    try self.check(else_branch);
                }
            },
            .expr_stmt => |stmt| {
                _ = try self.check_expression(stmt.expr); // any expression type is allowed - so we can ignore the result
            },
            .panic_stmt => |stmt| {
                _ = try self.check_expression(stmt.expr); // any expression type is allowed - so we can ignore the result
            },
            else => {},
        }
    }

    fn check_expression(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!AST.TypeId {
        return switch (node.*) {
            .assign_expr => |expr| {
                const right_type = try self.check_expression(expr.right);

                // if assigning to a variable
                if (expr.left.* == .identifier_expr or expr.left.* == .dot_expr) {
                    const left_type = try self.check_expression(expr.left);
                    if (!try self.is_compatible(left_type, right_type)) {
                        return TypeCheckerError.TypeMismatch;
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
            .binary_expr => |expr| {
                const left_type: AST.TypeId = try self.check_expression(expr.left);
                const right_type: AST.TypeId = try self.check_expression(expr.right);
                const op = expr.operator.lexeme;

                if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) {
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
                    if (std.mem.eql(u8, op, "+") and left_type == @intFromEnum(PrimitiveType.String) and right_type == @intFromEnum(PrimitiveType.String)) {
                        expr.resolved_type = @intFromEnum(PrimitiveType.String);
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
                }
                return TypeCheckerError.InvalidOperation;
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

                        // union type of return and yield type
                        const union_type = try self.registry.add_union_type(info.ret, info.yield);
                        expr.resolved_type = union_type;
                    },
                    else => {
                        return TypeCheckerError.InvalidOperation;
                    },
                }
                return TypeCheckerError.InvalidOperation;
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
                            if (std.mem.eql(u8, field.name, expr.member.lexeme)) {
                                expr.resolved_type = field.type;
                                return field.type;
                            }
                        }
                        return TypeCheckerError.InvalidMemberAccess;
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
                    .shape => |shape| {
                        for (shape) |field| {
                            if (std.mem.eql(u8, field.name, expr.member.lexeme)) {
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
                const tuple_type = try self.registry.add_tuple_type(inner_types.items);
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

                if (provided_count != shape_fields.len) return TypeCheckerError.InvalidArgumentCount;

                expr.resolved_type = struct_typeid;
                return struct_typeid;
            },
            .match_expr => |expr| {
                // TODO: add exhaustive checks
                defer self.expected_give_type = null;
                const expr_typeid = try self.check_expression(expr.expr);
                for (expr.cases) |case| {
                    // check if the case and the expression are compatible
                    const case_typeid = try self.check_expression(case.pattern);
                    if (!try self.is_compatible(expr_typeid, case_typeid)) {
                        return TypeCheckerError.TypeMismatch;
                    }
                    _ = try self.check_expression(case.stmts); // check the body of the case
                    // we are interested in the give type
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

                try self.check(expr.body);

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
            .option => |opt| {
                if (source == @intFromEnum(PrimitiveType.Nil)) return true; // Nil is compatible with Option (None)
                return try self.is_compatible(opt, source);
            },
            else => return false,
        };
    }
};
