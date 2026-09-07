const std = @import("std");
const AST = @import("ast.zig");
const TypeRegistry = @import("type_registry.zig");
const PrimitiveType = TypeRegistry.PrimitiveType;
const Environment = @import("environment.zig").Environment;
const EnvironmentError = @import("environment.zig").EnvironmentError;
const SymbolInfo = @import("environment.zig").SymbolInfo;
const DiagnosticReporter = @import("../diagnostics/diagnostics.zig").DiagnosticsReporter;
const TypeRegistryError = TypeRegistry.TypeRegistryError;
const StructMethod = TypeRegistry.StructMethod;
const StructField = TypeRegistry.StructField;
const Module = @import("workspace.zig").Module;
const Workspace = @import("workspace.zig").Workspace;

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
    /// A yield statement is missing in a coroutine.
    MissingYield,
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
    /// Trying to reassignment a constant
    ConstantReassignmentAttempt,
    /// An exported constant was initialized with a non constant value
    NonConstantExport,
    /// A try statement used outside of a function
    TryOutsideFunction,
    /// Invalid function return type
    InvalidReturnType,
    /// Attempting to mutable variable global scope
    MutableGlobalStateCaptureAttempt,
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
    module: *Module,
    workspace: *Workspace,

    expected_return_type: ?AST.TypeId = null,
    expected_give_type: ?AST.TypeId = null,
    expected_yield_type: ?AST.TypeId = null,
    expected_resume_with_type: ?AST.TypeId = null,

    in_loop: bool = false,
    in_coroutine: bool = false,
    in_function: bool = false,

    /// Set whenever a `yield` expression is type-checked so the enclosing
    /// statement/block can propagate the (existential) yield signal.
    saw_yield: bool = false,

    pub fn init(allocator: std.mem.Allocator, registry: *TypeRegistry.TypeRegistry, global_environment: *Environment, diagnostics: *DiagnosticReporter, module: *Module, workspace: *Workspace) TypeChecker {
        return .{ .allocator = allocator, .registry = registry, .environment = global_environment, .diagnostics = diagnostics, .module = module, .workspace = workspace };
    }

    fn fn_hoist(self: *TypeChecker, node: *AST.ASTNode, decl: *AST.FnDecl) !u32 {
        var param_types: std.ArrayList(AST.TypeId) = .empty;
        defer param_types.deinit(self.allocator);

        for (decl.params) |param| {
            const param_id = try self.registry.resolve(param.type_annotation);
            try param_types.append(self.allocator, param_id);
        }

        const return_id = try self.registry.resolve(decl.return_type_annotation);
        const fn_id = try self.registry.add_function_type(try param_types.toOwnedSlice(self.allocator), return_id);
        try self.environment.define_binding(decl.name.lexeme, fn_id, .{ .node = node }, true);
        return fn_id;
    }

    fn co_hoist(self: *TypeChecker, node: *AST.ASTNode, decl: *AST.CoDecl) !u32 {
        var param_types: std.ArrayList(AST.TypeId) = .empty;
        defer param_types.deinit(self.allocator);

        for (decl.params) |param| {
            const param_id = try self.registry.resolve(param.type_annotation);
            try param_types.append(self.allocator, param_id);
        }

        const return_id = try self.registry.resolve(decl.return_type_annotation);
        const yield_id = try self.registry.resolve(decl.yield_type_annotation);
        const resume_with_id = try self.registry.resolve(decl.resume_with_type_annotation);
        const co_id = try self.registry.add_coroutine_type(try param_types.toOwnedSlice(self.allocator), yield_id, resume_with_id, return_id);
        try self.environment.define_binding(decl.name.lexeme, co_id, .{ .node = node }, true);
        return co_id;
    }

    fn hoist(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!void {
        switch (node.*) {
            .program => |program| for (program.declarations) |decl| try self.hoist(decl),
            .use_decl => |decl| {
                const imported_module = self.workspace.modules.get(decl.resolved_module_path) orelse {
                    return TypeCheckerError.UndefinedSymbol;
                };

                for (decl.items, 0..) |item, index| {
                    const alias = item.alias orelse item.name;
                    if (imported_module.exports.get(item.name.lexeme)) |resolved_id| {
                        try self.environment.define_binding(alias.lexeme, resolved_id, .{ .import = .{ .use_decl = node, .index = @as(u32, @intCast(index)) } }, true);
                    } else {
                        try self.fail("Failed to import symbol from external module.", "Check that the module path is correct and that the symbol is exported with the 'pub' keyword.", alias.line, alias.column);
                        return TypeCheckerError.UndefinedSymbol;
                    }
                }
            },
            .fn_decl => |decl| {
                const fn_id = try self.fn_hoist(node, decl);
                if (decl.modifier_pub) {
                    try self.module.exports.put(decl.name.lexeme, fn_id);
                }
            },
            .co_decl => |decl| {
                const co_id = try self.co_hoist(node, decl);

                if (decl.modifier_pub) {
                    try self.module.exports.put(decl.name.lexeme, co_id);
                }
            },
            .struct_decl => |decl| {
                var field_types: std.ArrayList(StructField) = .empty;
                defer field_types.deinit(self.allocator);

                for (decl.fields) |field| {
                    const field_type = try self.registry.resolve(field.type_annotation);
                    // store the default value if there is one
                    try field_types.append(self.allocator, .{ .name = field.name.lexeme, .type = field_type, .is_static = field.is_static, .is_pub = field.is_pub, .default_value = field.default_value });
                }

                // Create struct with empty methods first to get its type_id for self
                const struct_id = try self.registry.add_struct_type(decl.name.lexeme, try field_types.toOwnedSlice(self.allocator), &.{}, self.module.filepath);

                var method_types: std.ArrayList(StructMethod) = .empty;
                defer method_types.deinit(self.allocator);

                for (decl.methods) |method| {
                    const self_type: ?AST.TypeId = if (method.is_static) null else struct_id;
                    const method_type = try self.check_declaration_type(method.method, self_type);
                    // store the node with the method definition
                    try method_types.append(self.allocator, .{ .name = method.name.lexeme, .type = method_type, .is_static = method.is_static, .is_pub = method.is_pub, .method_node = method.method });
                }

                // Update the struct with actual methods
                self.registry.types.items[struct_id]._struct.methods = try method_types.toOwnedSlice(self.allocator);

                try self.environment.define_binding(decl.name.lexeme, struct_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.module.exports.put(decl.name.lexeme, struct_id);
                }
            },
            .type_decl => |decl| {
                const type_annot_id = try self.registry.resolve(decl.type_annotation);
                const type_id = try self.registry.add_type_type(decl.name.lexeme, type_annot_id, self.module.filepath);
                try self.environment.define_binding(decl.name.lexeme, type_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.module.exports.put(decl.name.lexeme, type_id);
                }
            },
            .enum_decl => |decl| {
                var variants: std.ArrayList([]const u8) = .empty;
                defer variants.deinit(self.allocator);
                for (decl.variants) |variant| {
                    try variants.append(self.allocator, variant.lexeme);
                }
                const enum_id = try self.registry.add_enum_type(decl.name.lexeme, try variants.toOwnedSlice(self.allocator), self.module.filepath);
                try self.environment.define_binding(decl.name.lexeme, enum_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.module.exports.put(decl.name.lexeme, enum_id);
                }
            },
            .error_decl => |decl| {
                var variants: std.ArrayList([]const u8) = .empty;
                defer variants.deinit(self.allocator);
                for (decl.variants) |variant| {
                    try variants.append(self.allocator, variant.lexeme);
                }
                const error_id = try self.registry.add_error_type(decl.name.lexeme, try variants.toOwnedSlice(self.allocator), self.module.filepath);
                try self.environment.define_binding(decl.name.lexeme, error_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.module.exports.put(decl.name.lexeme, error_id);
                }
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
                        try self.fail("Type Mismatch", "Ensure that the initializer type and the annotated type are the same", decl.line, decl.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                }
                if (self.environment.contains(decl.name.lexeme)) {
                    try self.fail("Duplicate symbol", "Symbol is already defined.", decl.name.line, decl.name.column);
                    return TypeCheckerError.DuplicateSymbol;
                }

                try self.environment.define_binding(decl.name.lexeme, target_type, .{ .node = node }, decl.is_const);

                if (decl.modifier_pub) {
                    if (!is_constant_literal(decl.initializer)) {
                        try self.fail("Exported constants must be initialized with a literal value.", "Only literals (numbers, strings, booleans, nil, and their negation) are allowed for exported constants.", decl.line, decl.column);
                        return TypeCheckerError.NonConstantExport;
                    }
                    try self.module.exports.put(decl.name.lexeme, target_type);
                }

                return .{};
            },
            .fn_decl => |decl| {
                const fn_id = self.environment.lookup(decl.name.lexeme) catch {
                    try self.fail("Undefined symbol", "Symbol is not defined.", decl.name.line, decl.name.column);
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(fn_id);
                if (type_info != .function) {
                    try self.fail("Not callable", "Symbol is not a function. Functions are defined with the `fn` keyword.", decl.name.line, decl.name.column);
                    return TypeCheckerError.NotCallable;
                }

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

                // Define self if this is a method
                const has_self = type_info.function.args.len == decl.params.len + 1;
                if (has_self) {
                    try self.environment.define_binding(
                        "self",
                        type_info.function.args[0],
                        .{ .param = .{ .func = node, .index = 0 } },
                        true,
                    );
                }

                // Define params locally
                const param_offset: usize = if (has_self) 1 else 0;
                for (decl.params, type_info.function.args[param_offset..], 0..) |param, param_id, index| {
                    try self.environment.define_binding(param.name.lexeme, param_id, .{ .param = .{ .func = node, .index = @as(u32, @intCast(index + param_offset)) } }, false);
                }

                const prev_in_func = self.in_function;
                self.in_function = true;
                defer self.in_function = prev_in_func;
                const body_term = try self.check(decl.body);

                const needs_return = type_info.function.ret != @intFromEnum(PrimitiveType.Nil) and type_info.function.ret != @intFromEnum(PrimitiveType.Never);

                if (needs_return and !body_term.return_ and !body_term.panics) {
                    try self.fail("Missing return", "Function is missing a `return` statement.", decl.name.line, decl.name.column);
                    return TypeCheckerError.MissingReturn;
                }
                return .{};
            },
            .type_decl => { // handled at hoist phase
                return .{};
            },

            .struct_decl => |decl| {
                const struct_typeid = self.environment.lookup(decl.name.lexeme) catch {
                    try self.fail("Undefined symbol", "Symbol is not defined.", decl.name.line, decl.name.column);
                    return TypeCheckerError.UndefinedSymbol;
                };

                for (decl.fields) |field| {
                    _ = try self.check(field.type_annotation);
                }

                // Type-check the initializer and ensure it matches the field type.
                const struct_info_for_defaults = self.registry.get_type_info(struct_typeid)._struct;
                for (decl.fields, struct_info_for_defaults.fields) |field, sfield| {
                    if (field.default_value) |def| {
                        const def_type = try self.check_expression(def);
                        if (!try self.is_compatible(sfield.type, def_type)) {
                            try self.fail("Type Mismatch", "Default value type does not match field type.", decl.line, decl.column);
                            return TypeCheckerError.TypeMismatch;
                        }
                    }
                }

                // Push scope for method bodies
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                const type_info = self.registry.get_type_info(struct_typeid);
                try self.environment.define_binding("self", struct_typeid, .{ .node = node }, true);
                for (decl.methods, type_info._struct.methods) |method_decl, sm| {
                    try self.environment.define_binding(sm.name, sm.type, .{ .node = method_decl.method }, true);
                }

                for (decl.methods) |method| {
                    _ = try self.check(method.method);
                }
                return .{};
            },
            .co_decl => |decl| {
                const fn_id = self.environment.lookup(decl.name.lexeme) catch {
                    try self.fail("Undefined symbol", "Symbol is not defined.", decl.name.line, decl.name.column);
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(fn_id);
                if (type_info != .coroutine) {
                    try self.fail("Not callable", "Symbol is not a coroutine. Coroutines are defined with the `co` keyword.", decl.name.line, decl.name.column);
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

                // track expected resume_with type (the type of the yield expression)
                const prev_resume_with = self.expected_resume_with_type;
                self.expected_resume_with_type = type_info.coroutine.resume_with;
                defer self.expected_resume_with_type = prev_resume_with;

                // Push function scope
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                // Define self if this is a method
                const has_self = type_info.coroutine.args.len == decl.params.len + 1;
                if (has_self) {
                    try self.environment.define_binding("self", type_info.coroutine.args[0], .{ .param = .{ .func = node, .index = 0 } }, true);
                }

                // Define params locally
                const param_offset: usize = if (has_self) 1 else 0;
                for (decl.params, type_info.coroutine.args[param_offset..], 0..) |param, param_id, index| {
                    try self.environment.define_binding(param.name.lexeme, param_id, .{ .param = .{ .func = node, .index = @as(u32, @intCast(index + param_offset)) } }, false);
                }

                const prev_in_coroutine = self.in_coroutine;
                self.in_coroutine = true;
                defer self.in_coroutine = prev_in_coroutine;
                const body_term = try self.check(decl.body);
                const needs_return = type_info.coroutine.ret != @intFromEnum(PrimitiveType.Nil) and type_info.coroutine.ret != @intFromEnum(PrimitiveType.Never);
                const needs_yield = type_info.coroutine.yield != @intFromEnum(PrimitiveType.Nil);
                if (needs_return and !body_term.return_ and !body_term.panics) {
                    try self.fail("Missing return", "Coroutine is missing a return statement.", decl.name.line, decl.name.column);
                    return TypeCheckerError.MissingReturn;
                }
                if (needs_yield and !body_term.yield_) {
                    try self.fail("Missing yield", "Coroutine is missing a yield statement.", decl.line, decl.column);
                    return TypeCheckerError.MissingYield;
                }
                return .{};
            },
            .enum_decl => { // fully handled in the hoist phase
                return .{};
            },
            .error_decl => { // fully handled in the hoist phase
                return .{};
            },
            .use_decl => { // fully handled in the hoist phase
                return .{};
            },
            .block_stmt => |stmt| {
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();

                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;
                var last: StatementTermination = .{};

                for (stmt.stmts) |statement| {
                    switch (statement.*) {
                        .fn_decl => |decl| {
                            _ = try self.fn_hoist(statement, decl);
                        },
                        .co_decl => |decl| {
                            _ = try self.co_hoist(statement, decl);
                        },
                        else => {}, // we don't hoist every node type
                    }
                }

                var terminated = false;
                for (stmt.stmts) |child| {
                    // `yield` is now an expression, so yields nested anywhere in a
                    // statement (var initializer, condition, call arg, ...) are
                    // tracked via the saw_yield flag rather than a statement flag.
                    self.saw_yield = false;
                    const term = try self.check(child);
                    if (terminated) continue; // unreachable code doesn't contribute to termination
                    last.return_ = last.return_ or term.return_;
                    last.panics = last.panics or term.panics;
                    last.break_ = last.break_ or term.break_;
                    last.continue_ = last.continue_ or term.continue_;
                    last.yield_ = last.yield_ or term.yield_ or self.saw_yield;
                    last.give_ = last.give_ or term.give_;
                    if (term.return_ or term.panics or term.break_ or term.continue_) {
                        terminated = true;
                    }
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
                        try self.fail("Type Mismatch", "Returned value does not match the declared return type.", stmt.line, stmt.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                } else {
                    try self.fail("Invalid Operation", "Return statement used outside of a function or coroutine.", stmt.line, stmt.column);
                    return TypeCheckerError.InvalidOperation; // Return outside of function
                }
                return .{ .return_ = true };
            },
            .give_stmt => |stmt| {
                const provided_type = try self.check_expression(stmt.expr);

                if (self.expected_give_type) |expected_type| {
                    if (!try self.is_compatible(expected_type, provided_type)) {
                        try self.fail("Type Mismatch", "Gave value does not match the type of earlier give statements.", stmt.line, stmt.column);
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
                    try self.fail("Type Mismatch", "While condition must be a boolean.", stmt.line, stmt.column);
                    return TypeCheckerError.TypeMismatch;
                }
                const prev_loop = self.in_loop;
                self.in_loop = true;
                const body_term = try self.check(stmt.body);
                self.in_loop = prev_loop;
                // The loop body may or may not execute, so only the yield flag is
                // propagated (existentially) — a yield inside a loop means the
                // coroutine *can* yield. Return/panic/break/continue are not
                // guaranteed and are intentionally dropped.
                return .{ .yield_ = body_term.yield_ };
            },
            .for_stmt => |stmt| {
                // ensure that iterator expression produces a range
                const iter_type = try self.check_expression(stmt.iterator_expr);
                const iter_info = self.registry.get_type_info(iter_type);
                if (iter_info != .range) {
                    try self.fail("Type Mismatch", "`for` iterator expression must be a Range.", stmt.iterator_name.line, stmt.iterator_name.column);
                    return TypeCheckerError.TypeMismatch;
                }

                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();

                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                try self.environment.define_binding(stmt.iterator_name.lexeme, @intFromEnum(PrimitiveType.Int), .{ .node = node }, true);
                const prev_loop = self.in_loop;
                self.in_loop = true;
                const body_term = try self.check(stmt.body);
                self.in_loop = prev_loop;

                return .{ .yield_ = body_term.yield_ };
            },
            .if_stmt => |stmt| {
                const condition_type = try self.check_expression(stmt.condition);
                if (condition_type != @intFromEnum(PrimitiveType.Bool)) {
                    try self.fail("Non-boolean condition", "If condition must be a boolean.", stmt.line, stmt.column);
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
                        // yields are existential: either branch yielding means the
                        // coroutine can yield
                        .yield_ = then_term.yield_ or else_term.yield_,
                        .give_ = then_term.give_ and else_term.give_,
                    };
                }
                // no else: the then branch may or may not run, so only yield is
                // propagated existentially
                return .{ .yield_ = then_term.yield_ };
            },
            .break_stmt => |stmt| {
                if (!self.in_loop) {
                    try self.fail("Invalid Operation", "Break statement used outside of a loop.", stmt.line, stmt.column);
                    return TypeCheckerError.BreakOutsideLoop;
                }
                return .{ .break_ = true };
            },
            .continue_stmt => |stmt| {
                if (!self.in_loop) {
                    try self.fail("Invalid Operation", "Continue statement used outside of a loop.", stmt.line, stmt.column);
                    return TypeCheckerError.ContinueOutsideLoop;
                }
                return .{ .continue_ = true };
            },
            .expr_stmt => |stmt| {
                var term: StatementTermination = .{};
                _ = try self.check_expression_term(stmt.expr, &term);
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

    fn check_declaration_type(self: *TypeChecker, node: *AST.ASTNode, self_type: ?AST.TypeId) TypeCheckerError!AST.TypeId {
        switch (node.*) {
            .fn_decl => |decl| {
                var param_types: std.ArrayList(AST.TypeId) = .empty;
                defer param_types.deinit(self.allocator);

                if (self_type) |st| try param_types.append(self.allocator, st);

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

                if (self_type) |st| try param_types.append(self.allocator, st);

                for (decl.params) |param| {
                    const param_type = try self.registry.resolve(param.type_annotation);
                    try param_types.append(self.allocator, param_type);
                }
                const return_type = try self.registry.resolve(decl.return_type_annotation);
                const yield_type = try self.registry.resolve(decl.yield_type_annotation);
                const resume_with_type = try self.registry.resolve(decl.resume_with_type_annotation);
                const co_type = try self.registry.add_coroutine_type(try param_types.toOwnedSlice(self.allocator), yield_type, resume_with_type, return_type);
                return co_type;
            },
            else => {
                return TypeCheckerError.UnknownExpression;
            },
        }
    }

    /// Rejects reads/writes of module-global mutable state from within a function or
    /// coroutine body. Functions must be fully compile-time knowable.
    /// TODO: make this more strict (dot expr etc)
    fn reject_global_state_access(self: *TypeChecker, name: []const u8, info: SymbolInfo, scope: *Environment, line: usize, column: usize) TypeCheckerError!void {
        if (!self.in_function and !self.in_coroutine) return;
        if (scope.parent != null) return; // local / upvalue, allowed (closures)
        if (info.is_const) return; // global const, fn, type, enum, error — all fine
        _ = name;
        try self.fail("Functions cannot access global state", "A function must be fully compile-time knowable, so it cannot read or write mutable module-level variables.", line, column);
        return TypeCheckerError.MutableGlobalStateCaptureAttempt;
    }

    fn check_expression(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!AST.TypeId {
        return self.check_expression_term(node, null);
    }

    fn check_expression_term(self: *TypeChecker, node: *AST.ASTNode, out_term: ?*StatementTermination) TypeCheckerError!AST.TypeId {
        return switch (node.*) {
            .assign_expr => |expr| {
                if (expr.left.* == .identifier_expr) {
                    const info = self.environment.lookup_binding(expr.left.identifier_expr.name.lexeme) catch {
                        try self.fail("Undefined symbol", "Symbol is not defined. Use `var` or `const` to define the symbol.", expr.line, expr.column);
                        return TypeCheckerError.UndefinedSymbol;
                    };
                    if (info.is_const) {
                        try self.fail("Constant Reassignment Attempt", "Symbols defined with `const` cannot be reassigned. Use `var` instead.", expr.line, expr.column);
                        return TypeCheckerError.ConstantReassignmentAttempt;
                    }
                }

                const right_type = try self.check_expression(expr.right);

                // Only mutable l-values can be assigned. Arrays and tables are
                // mutable through an index; strings and tuples are not.
                if (expr.left.* == .identifier_expr or expr.left.* == .dot_expr or expr.left.* == .static_member_expr or expr.left.* == .index_expr) {
                    const left_type = try self.check_expression(expr.left);
                    if (expr.left.* == .index_expr) {
                        const collection_type = try self.check_expression(expr.left.index_expr.expr);
                        switch (self.registry.get_type_info(collection_type)) {
                            .array, .table => {},
                            else => {
                                try self.fail("Invalid assignment target", "Only array and table elements can be assigned through an index.", expr.line, expr.column);
                                return TypeCheckerError.InvalidOperation;
                            },
                        }
                    }
                    if (!try self.is_compatible(left_type, right_type)) {
                        try self.fail("Type Mismatch", "Ensure that the assigned value type matches the variable's declared type.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }

                    const op = expr.operator.lexeme;
                    if (!std.mem.eql(u8, op, "=")) {
                        const is_numeric = left_type == @intFromEnum(PrimitiveType.Int) or left_type == @intFromEnum(PrimitiveType.Float);

                        if (std.mem.eql(u8, op, "-=") or std.mem.eql(u8, op, "*=") or std.mem.eql(u8, op, "/=") or std.mem.eql(u8, op, "+=") or std.mem.eql(u8, op, "%=") or std.mem.eql(u8, op, "**=")) {
                            if (!is_numeric) {
                                try self.fail("Invalid Operation", "Compound arithmetic assignment requires a numeric left-hand side.", expr.line, expr.column);
                                return TypeCheckerError.InvalidOperation;
                            }
                        }

                        if (std.mem.eql(u8, op, "++=")) {
                            if (!(left_type == @intFromEnum(PrimitiveType.String) and right_type == @intFromEnum(PrimitiveType.String))) {
                                // ++= can only be used for strings
                                try self.fail("Invalid Operation", "`++=` can only be used to concatenate strings.", expr.line, expr.column);
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
                const resolved = self.environment.lookup_binding_scope(expr.name.lexeme) catch {
                    try self.fail("Undefined symbol", "Symbol is not defined.", expr.line, expr.column);
                    return TypeCheckerError.UndefinedSymbol;
                };
                try self.reject_global_state_access(expr.name.lexeme, resolved.info, resolved.scope, expr.line, expr.column);
                expr.resolved_type = resolved.info.type_id;
                expr.resolved_decl = resolved.info.decl;
                return resolved.info.type_id;
            },
            .unary_expr => |expr| {
                const token = expr.operator;
                const expr_type = try self.check_expression(expr.expr);
                if (std.mem.eql(u8, token.lexeme, "-")) {
                    if (expr_type == @intFromEnum(PrimitiveType.Float) or expr_type == @intFromEnum(PrimitiveType.Int)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    try self.fail("Invalid Operation", "Unary `-` requires a numeric operand.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, token.lexeme, "~")) {
                    if (expr_type == @intFromEnum(PrimitiveType.Int)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    try self.fail("Invalid Operation", "Unary `~` requires an integer operand.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, token.lexeme, "not")) {
                    if (expr_type == @intFromEnum(PrimitiveType.Bool)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    try self.fail("Invalid Operation", "`not` requires a boolean operand.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                } else {
                    try self.fail("Invalid Operation", "Unsupported unary operator.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                }
            },
            .resume_expr => |expr| {
                const expr_typeid = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(expr_typeid);
                if (type_info != .coroutine) {
                    try self.fail("Invalid Operation", "`resume` can only be applied to a coroutine.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                }
                // The value passed in (`resume co with V`) becomes the yield
                // expression's value, so it must match the resume_with type.
                // Omitting `with V` passes nil.
                var resume_value_type = @intFromEnum(PrimitiveType.Nil);
                if (expr.arg) |arg| {
                    resume_value_type = try self.check_expression(arg);
                }
                if (!try self.is_compatible(type_info.coroutine.resume_with, resume_value_type)) {
                    try self.fail("Type Mismatch", "Resumed value does not match the coroutine's resume_with type.", expr.line, expr.column);
                    return TypeCheckerError.TypeMismatch;
                }

                const union_type = try self.registry.add_union_type(type_info.coroutine.yield, type_info.coroutine.ret);
                expr.resolved_type = union_type;
                return union_type;
            },
            .try_expr => |expr| {
                const expected = self.expected_return_type orelse {
                    try self.fail("`try` used outside function or coroutine", "`try` returns an error and so must be within a function or coroutine.", expr.line, expr.column);
                    return TypeCheckerError.TryOutsideFunction;
                };
                if (self.split_error_union(expected) == null) {
                    try self.fail("Invalid Return Type", "A function that contains a `try` expression must have a union as its return type with an Error on one side.", expr.line, expr.column);
                    return TypeCheckerError.InvalidReturnType;
                }

                const expr_typeid = try self.check_expression(expr.expr);
                const parts = self.split_error_union(expr_typeid) orelse {
                    try self.fail("Invalid Operation", "`try` can only be used on a union which contains an Error.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                };

                if (!try self.is_compatible(expected, parts.err)) {
                    try self.fail("Invalid Return Type", "The possibly returned error's type does not match the function return type.", expr.line, expr.column);
                    return TypeCheckerError.InvalidReturnType;
                }

                expr.resolved_type = parts.success;
                return expr.resolved_type;
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
                    try self.fail("Invalid Operation", "Arithmetic operators require numeric operands.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=")) {
                    if (left_type != right_type) {
                        try self.fail("Type Mismatch", "Comparison operators require operands of the same type.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @intFromEnum(PrimitiveType.Bool);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "or")) {
                    if (left_type != @intFromEnum(PrimitiveType.Bool) or right_type != @intFromEnum(PrimitiveType.Bool)) {
                        try self.fail("Type Mismatch", "`and` and `or` require boolean operands.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @intFromEnum(PrimitiveType.Bool);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "++")) { // string concatenation
                    if (left_type != @intFromEnum(PrimitiveType.String) or right_type != @intFromEnum(PrimitiveType.String)) {
                        try self.fail("Type Mismatch", "`++` can only concatenate strings.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @intFromEnum(PrimitiveType.String);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "..")) { // range expression
                    if (left_type != @intFromEnum(PrimitiveType.Int) or right_type != @intFromEnum(PrimitiveType.Int)) {
                        try self.fail("Type Mismatch", "Range operator `..` requires integer operands.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    const range_type = try self.registry.add_range_type(left_type, right_type);

                    expr.resolved_type = range_type;
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, ">>") or std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, "|") or std.mem.eql(u8, op, "&") or std.mem.eql(u8, op, "^")) {
                    if (left_type != @intFromEnum(PrimitiveType.Int) or right_type != @intFromEnum(PrimitiveType.Int)) {
                        try self.fail("Type Mismatch", "Bitwise operators require integer operands.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @intFromEnum(PrimitiveType.Int);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "orelse")) {
                    // a orelse b
                    // if a is nil then give me b

                    // a must be a union with Nil

                    const left_info = self.registry.get_type_info(left_type);
                    if (left_info != ._union) {
                        try self.fail("Invalid Operation", "`orelse` requires a union with Nil on one side.", expr.line, expr.column);
                        return TypeCheckerError.InvalidOperation;
                    }

                    if (!((left_info._union.left == @intFromEnum(PrimitiveType.Nil) and left_info._union.right != @intFromEnum(PrimitiveType.Nil)) or (left_info._union.left != @intFromEnum(PrimitiveType.Nil) and left_info._union.right == @intFromEnum(PrimitiveType.Nil)))) {
                        try self.fail("Invalid Operation", "`orelse` requires exactly one side of the union to be Nil.", expr.line, expr.column);
                        return TypeCheckerError.InvalidOperation;
                    }
                    const non_nil_side = if (left_info._union.left == @intFromEnum(PrimitiveType.Nil)) left_info._union.right else left_info._union.left;
                    const result_union = try self.registry.add_union_type(non_nil_side, right_type);
                    expr.resolved_type = result_union;
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "catch")) {
                    // a catch b
                    // if a is error then give me b

                    // a must be a union with Error

                    const left_info = self.registry.get_type_info(left_type);
                    if (left_info != ._union) {
                        try self.fail("Invalid Operation", "`catch` requires a union with an Error on one side.", expr.line, expr.column);
                        return TypeCheckerError.InvalidOperation;
                    }

                    const union_left = self.registry.get_type_info(left_info._union.left);
                    const union_right = self.registry.get_type_info(left_info._union.right);

                    if (!((union_left == ._error and union_right != ._error) or (union_left != ._error and union_right == ._error))) {
                        try self.fail("Invalid Operation", "`catch` requires exactly one side of the union to be an Error.", expr.line, expr.column);
                        return TypeCheckerError.InvalidOperation;
                    }
                    const non_error_side = if (union_left == ._error) left_info._union.right else left_info._union.left;
                    const result_union = try self.registry.add_union_type(non_error_side, right_type);
                    expr.resolved_type = result_union;
                    return expr.resolved_type;
                } else {
                    try self.fail("Invalid Operation", "Unsupported binary operator.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                }
            },
            .call_expr => |expr| {
                // check if this is an instance method - if so, it needs an implicit self
                if (expr.expr.* == .dot_expr) {
                    const dot = expr.expr.dot_expr;
                    const receiver_type = try self.check_expression(dot.expr);
                    const receiver_info = self.registry.get_type_info(receiver_type);

                    if (receiver_info == ._struct) {
                        for (receiver_info._struct.methods) |method| {
                            if (!method.is_static and std.mem.eql(u8, method.name, dot.member.lexeme)) {
                                const method_info = self.registry.get_type_info(method.type);
                                const args = switch (method_info) {
                                    .function => |f| f.args,
                                    .coroutine => |c| c.args,
                                    else => return TypeCheckerError.NotCallable,
                                };
                                const return_type = switch (method_info) {
                                    .function => |f| f.ret,
                                    .coroutine => method.type,
                                    else => return TypeCheckerError.NotCallable,
                                };

                                // args[0] is the implicut`self`. args start at index 1.
                                const expected_arg_count = args.len - 1;
                                if (expr.args.len != expected_arg_count) {
                                    try self.fail("Invalid argument count", "Method expects a different number of arguments.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidArgumentCount;
                                }

                                for (expr.args, 0..) |arg, index| {
                                    const arg_type = try self.check_expression(arg);
                                    if (arg_type != args[index + 1]) {
                                        try self.fail("Type Mismatch", "Argument type does not match method parameter type.", expr.line, expr.column);
                                        return TypeCheckerError.TypeMismatch;
                                    }
                                }

                                dot.resolved_type = method.type;
                                expr.resolved_type = return_type;
                                return expr.resolved_type;
                            }
                        }
                    }
                }

                const expr_type = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(expr_type);
                switch (type_info) {
                    .function => |info| {
                        if (expr.args.len != info.args.len) {
                            try self.fail("Invalid argument count", "Function expects a different number of arguments.", expr.line, expr.column);
                            return TypeCheckerError.InvalidArgumentCount;
                        }
                        for (expr.args, 0..) |arg, index| {
                            const arg_type = try self.check_expression(arg);
                            if (arg_type != info.args[index]) {
                                try self.fail("Type Mismatch", "Argument type does not match the function parameter type.", expr.line, expr.column);
                                return TypeCheckerError.TypeMismatch;
                            }
                        }
                        expr.resolved_type = info.ret;
                    },
                    .coroutine => |info| {
                        if (expr.args.len != info.args.len) {
                            try self.fail("Invalid argument count", "Coroutine expects a different number of arguments.", expr.line, expr.column);
                            return TypeCheckerError.InvalidArgumentCount;
                        }
                        for (expr.args, 0..) |arg, index| {
                            const arg_type = try self.check_expression(arg);
                            if (arg_type != info.args[index]) {
                                try self.fail("Type Mismatch", "Argument type does not match the coroutine parameter type.", expr.line, expr.column);
                                return TypeCheckerError.TypeMismatch;
                            }
                        }
                        expr.resolved_type = expr_type;
                    },
                    else => {
                        try self.fail("Invalid Operation", "Attempted to call a value that is not a function or coroutine.", expr.line, expr.column);
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
                            try self.fail("Type Mismatch", "Array index must be an integer.", expr.line, expr.column);
                            return TypeCheckerError.TypeMismatch;
                        }
                        expr.resolved_type = arr_info;
                        return arr_info;
                    },
                    .table => |tbl_info| {
                        if (index_type != tbl_info.key) {
                            try self.fail("Type Mismatch", "Table index type does not match the table's key type.", expr.line, expr.column);
                            return TypeCheckerError.TypeMismatch;
                        }
                        expr.resolved_type = tbl_info.value;
                        return tbl_info.value;
                    },
                    .primitive => |prim| {
                        switch (prim) {
                            .String => {
                                if (index_type != @intFromEnum(PrimitiveType.Int)) {
                                    try self.fail("Type Mismatch", "String index must be an integer.", expr.line, expr.column);
                                    return TypeCheckerError.TypeMismatch;
                                }
                                expr.resolved_type = @intFromEnum(PrimitiveType.String);
                                return @intFromEnum(PrimitiveType.String);
                            },
                            else => {
                                try self.fail("Type Mismatch", "This primitive type cannot be indexed.", expr.line, expr.column);
                                return TypeCheckerError.TypeMismatch;
                            },
                        }
                    },
                    else => {
                        try self.fail("Type Mismatch", "Type cannot be indexed.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    },
                }
            },
            .yield_expr => |expr| {
                const provided_type = try self.check_expression(expr.expr);

                if (self.expected_yield_type) |expected_type| {
                    if (!try self.is_compatible(expected_type, provided_type)) {
                        try self.fail("Type Mismatch", "Yielded value does not match the declared yield type.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                } else {
                    try self.fail("Invalid Operation", "Yield expression used outside of a coroutine.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation; // Yield outside of coroutine
                }

                // The yield expression's value is whatever the next `resume co with V`
                // passes in, so its type is the coroutine's resume_with type.
                expr.resolved_type = self.expected_resume_with_type.?;
                self.saw_yield = true;
                if (out_term) |term| term.yield_ = true;
                return expr.resolved_type;
            },
            .dot_expr => |expr| {
                const obj_type = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(obj_type);

                switch (type_info) {
                    .tuple => |tuple| {
                        const index_value = std.fmt.parseInt(u8, expr.member.lexeme, 10) catch {
                            try self.fail("Invalid Member Access", "Tuple member access must be a numeric index.", expr.line, expr.column);
                            return TypeCheckerError.InvalidMemberAccess;
                        };
                        if (index_value >= tuple.len) {
                            try self.fail("Index Out Of Bounds", "Tuple index is out of bounds.", expr.line, expr.column);
                            return TypeCheckerError.IndexOutOfBounds;
                        }
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
                                    try self.fail("Invalid Member Access", "Member is not a callable method.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                expr.resolved_type = method.type;
                                return method.type;
                            }
                        }
                        try self.fail("Invalid Member Access", "Struct has no non-static member with this name.", expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                    .coroutine => {
                        // corotines have suspended, finished, and running members - which are boolean values
                        if (std.mem.eql(u8, expr.member.lexeme, "suspended") or std.mem.eql(u8, expr.member.lexeme, "finished") or std.mem.eql(u8, expr.member.lexeme, "running") or std.mem.eql(u8, expr.member.lexeme, "started")) {
                            expr.resolved_type = @intFromEnum(PrimitiveType.Bool);
                            return @intFromEnum(PrimitiveType.Bool);
                        } else {
                            try self.fail("Invalid Member Access", "Coroutines only expose `started`, `suspended`, `finished`, and `running` members.", expr.line, expr.column);
                            return TypeCheckerError.InvalidMemberAccess;
                        }
                    },
                    else => {
                        try self.fail("Invalid Member Access", "Type does not support member access.", expr.line, expr.column);
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
                        try self.fail("Struct has no static member with this name.", null, expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                    ._error => |existing_error| {
                        for (existing_error.variants) |variant| {
                            if (std.mem.eql(u8, variant, expr.member.lexeme)) {
                                expr.resolved_type = obj_type;
                                return obj_type;
                            }
                        }
                        try self.fail("Error type has no variant with this name.", null, expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                    ._enum => |existing_enum| {
                        for (existing_enum.variants) |variant| {
                            if (std.mem.eql(u8, variant, expr.member.lexeme)) {
                                expr.resolved_type = obj_type;
                                return obj_type;
                            }
                        }
                        try self.fail("Enum has no variant with this name.", null, expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                    else => {
                        try self.fail("Type does not support static member access.", null, expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                }
            },
            .array_expr => |expr| {
                var current_id: ?AST.TypeId = null;
                for (expr.elements) |element| {
                    if (current_id == null) {
                        current_id = try self.check_expression(element);
                        continue;
                    }
                    if (!try self.is_compatible(current_id.?, try self.check_expression(element))) {
                        try self.fail("Type Mismatch", "All array elements must be the same type.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                }
                // if this array has no initial values it is Array[Never]
                // Array[Never] is compatible with anything
                if (current_id == null) {
                    current_id = @intFromEnum(PrimitiveType.Never);
                }
                const array_type = try self.registry.add_array_type(current_id.?);
                expr.resolved_type = array_type;
                return array_type;
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
                            try self.fail("Type Mismatch", "All table keys must be the same type.", expr.line, expr.column);
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
                            try self.fail("Type Mismatch", "All table values must be the same type.", expr.line, expr.column);
                            return TypeCheckerError.TypeMismatch;
                        }
                    }
                }

                var table_type: AST.TypeId = undefined;
                // if table has not initial values it is `Table[Never, Never]`
                // Table[Never, Never] is compatible with anything
                if (key_type == null or value_type == null) {
                    table_type = try self.registry.add_table_type(
                        @intFromEnum(PrimitiveType.Never),
                        @intFromEnum(PrimitiveType.Never),
                    );
                    expr.resolved_type = table_type;
                } else {
                    table_type = try self.registry.add_table_type(key_type.?, value_type.?);
                    expr.resolved_type = table_type;
                }

                return table_type;
            },
            .new_expr => |expr| {
                const struct_typeid = self.environment.lookup(expr.struct_name.lexeme) catch {
                    try self.fail("Undefined symbol", "Symbol is not defined.", expr.line, expr.column);
                    return TypeCheckerError.UndefinedSymbol;
                };

                const type_info = self.registry.get_type_info(struct_typeid);
                if (type_info != ._struct) {
                    try self.fail("Invalid Operation", "`new` can only be used to construct a struct.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                }

                const struct_fields = type_info._struct.fields;

                for (struct_fields) |struct_field| {
                    if (struct_field.is_static) continue; // static fields should not appear in the `new` construction - error will come

                    if (struct_field.default_value == null) {
                        var found = false;
                        for (expr.fields) |provided| {
                            if (std.mem.eql(u8, provided.name.lexeme, struct_field.name)) {
                                found = true;
                                break;
                            }
                        }

                        if (!found) {
                            const msg = try std.fmt.allocPrint(self.allocator, "Missing required field '{s}' in struct constructor.", .{struct_field.name});
                            defer self.allocator.free(msg);
                            try self.fail("Missing Required Field", msg, expr.line, expr.column);
                            return TypeCheckerError.InvalidArgumentCount;
                        }
                    }
                }

                // Verify no unknown or duplicate fields were provided
                for (expr.fields) |provided_field| {
                    const val_type = try self.check_expression(provided_field.value);

                    var matched = false;
                    for (struct_fields) |struct_field| {
                        if (std.mem.eql(u8, struct_field.name, provided_field.name.lexeme)) {
                            if (struct_field.is_static) {
                                try self.fail("Invalid Field", "Cannot initialize static field in struct instance constructor.", expr.line, expr.column);
                                return TypeCheckerError.InvalidMemberAccess;
                            }
                            if (!try self.is_compatible(struct_field.type, val_type)) {
                                try self.fail("Type Mismatch", "Field value type does not match the struct field type.", expr.line, expr.column);
                                return TypeCheckerError.TypeMismatch;
                            }
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        try self.fail("Invalid Member Access", "Struct has no field with this name.", expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    }
                }
                expr.resolved_type = struct_typeid;
                return struct_typeid;
            },
            .match_expr => |expr| {
                const prev_give = self.expected_give_type;
                self.expected_give_type = null;
                defer self.expected_give_type = prev_give;
                const expr_typeid = try self.check_expression(expr.expr);
                // duplicate default detection
                {
                    var default_count: usize = 0;
                    for (expr.cases) |case| {
                        if (case.pattern.* == .default_pat) default_count += 1;
                    }
                    if (default_count > 1) {
                        try self.fail("Duplicate default", "Match expression cannot have more than one `default` case.", expr.line, expr.column);
                        return TypeCheckerError.DuplicateSymbol;
                    }
                }
                try self.check_match_exhaustiveness(expr_typeid, expr);
                var all_return = expr.cases.len > 0;
                for (expr.cases) |case| {
                    // default pattern is catch-all - skip type compatibility
                    if (case.pattern.* != .default_pat) {
                        const case_typeid = try self.check_expression(case.pattern);
                        if (!try self.is_compatible(expr_typeid, case_typeid)) {
                            try self.fail("Type Mismatch", "Match case pattern does not match the matched expression type.", expr.line, expr.column);
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

                const ret_typeid = try self.registry.resolve(expr.return_type_annotation);

                const owned_for_registry = try self.allocator.dupe(AST.TypeId, arg_types.items);
                const function_typeid = try self.registry.add_function_type(owned_for_registry, ret_typeid);

                // Push function scope
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                // Define params locally
                for (expr.params, arg_types.items, 0..) |param, param_id, index| {
                    try self.environment.define_binding(param.name.lexeme, param_id, .{ .param = .{ .func = node, .index = @as(u32, @intCast(index)) } }, false);
                }

                // Typecheck inner body
                const prev_ret = self.expected_return_type;
                self.expected_return_type = ret_typeid;
                defer self.expected_return_type = prev_ret;

                const body_term = try self.check(expr.body);
                const needs_return = ret_typeid != @intFromEnum(PrimitiveType.Nil) and ret_typeid != @intFromEnum(PrimitiveType.Never);
                if (needs_return and !body_term.return_ and !body_term.panics) {
                    try self.fail("Missing return", "Anonymous function is missing a return statement.", expr.line, expr.column);
                    return TypeCheckerError.MissingReturn;
                }
                expr.resolved_type = function_typeid;
                return function_typeid;
            },
            .anon_co_expr => |expr| {
                var arg_types: std.ArrayList(u32) = .empty;
                defer arg_types.deinit(self.allocator);

                for (expr.params) |param| {
                    const param_typeid = try self.registry.resolve(param.type_annotation);
                    try arg_types.append(self.allocator, param_typeid);
                }

                const ret_typeid = try self.registry.resolve(expr.return_type_annotation);
                const yield_typeid = try self.registry.resolve(expr.yield_type_annotation);
                const resume_with_typeid = try self.registry.resolve(expr.resume_with_type_annotation);

                const prev_ret = self.expected_return_type;
                self.expected_return_type = ret_typeid;
                defer self.expected_return_type = prev_ret;

                const prev_yield = self.expected_yield_type;
                self.expected_yield_type = yield_typeid;
                defer self.expected_yield_type = prev_yield;

                const prev_resume_with = self.expected_resume_with_type;
                self.expected_resume_with_type = resume_with_typeid;
                defer self.expected_resume_with_type = prev_resume_with;

                const owned_for_registry_co = try self.allocator.dupe(AST.TypeId, arg_types.items);
                const coroutine_typeid = try self.registry.add_coroutine_type(owned_for_registry_co, yield_typeid, resume_with_typeid, ret_typeid);

                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                for (expr.params, arg_types.items, 0..) |param, param_id, index| {
                    try self.environment.define_binding(param.name.lexeme, param_id, .{ .param = .{ .func = node, .index = @as(u32, @intCast(index)) } }, false);
                }

                const body_term = try self.check(expr.body);
                const needs_return = ret_typeid != @intFromEnum(PrimitiveType.Nil) and ret_typeid != @intFromEnum(PrimitiveType.Never);
                const needs_yield = yield_typeid != @intFromEnum(PrimitiveType.Nil);
                if (needs_return and !body_term.return_ and !body_term.panics) {
                    try self.fail("Missing return", "Coroutine is missing a return statement.", expr.line, expr.column);
                    return TypeCheckerError.MissingReturn;
                }
                if (needs_yield and !body_term.yield_) {
                    try self.fail("Missing yield", "Coroutine is missing a yield statement.", expr.line, expr.column);
                    return TypeCheckerError.MissingYield;
                }
                expr.resolved_type = coroutine_typeid;
                return coroutine_typeid;
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

    fn hasDefault(self: *TypeChecker, expr: *AST.MatchExpr) bool {
        _ = self;
        for (expr.cases) |case| {
            if (case.pattern.* == .default_pat) return true;
        }
        return false;
    }

    fn isPrimitiveTypeId(self: *TypeChecker, id: AST.TypeId) bool {
        if (id == @intFromEnum(PrimitiveType.Never)) return false;
        const info = self.registry.get_type_info(id);
        return switch (info) {
            .primitive => true,
            .array, .table, .range, .tuple, .function, .coroutine, ._struct, ._type => true,
            else => false,
        };
    }

    fn unionContainsPrimitive(self: *TypeChecker, id: AST.TypeId) bool {
        const info = self.registry.get_type_info(id);
        if (info == ._union) {
            return self.unionContainsPrimitive(info._union.left) or self.unionContainsPrimitive(info._union.right);
        }
        return self.isPrimitiveTypeId(id);
    }

    fn isNeverTypeId(self: *TypeChecker, id: AST.TypeId) bool {
        _ = self;
        return id == @intFromEnum(PrimitiveType.Never);
    }

    fn check_match_exhaustiveness(self: *TypeChecker, matched_type: AST.TypeId, expr: *AST.MatchExpr) TypeCheckerError!void {
        const has_default = self.hasDefault(expr);

        // Never is exhaustive even with empty cases
        if (self.isNeverTypeId(matched_type)) return;

        // Empty match without default is non-exhaustive (unless Never)
        if (expr.cases.len == 0) {
            if (!has_default) {
                try self.fail("Non-exhaustive match", "Empty match requires `default` unless matched type is `Never`.", expr.line, expr.column);
                return TypeCheckerError.NonExhaustiveMatch;
            }
            return;
        }

        if (has_default) return; // default covers remaining values, anywhere

        // Bool and Nil are finite - check exhaustive without default
        if (matched_type == @intFromEnum(PrimitiveType.Bool)) {
            var has_true = false;
            var has_false = false;
            for (expr.cases) |case| {
                if (case.pattern.* == .bool_lit) {
                    if (case.pattern.bool_lit.value) has_true = true else has_false = true;
                }
            }
            if (has_true and has_false) return;
            try self.fail("Non-exhaustive match", "Bool match must cover `true` and `false` or have `default`.", expr.line, expr.column);
            return TypeCheckerError.NonExhaustiveMatch;
        }
        if (matched_type == @intFromEnum(PrimitiveType.Nil)) {
            var has_nil = false;
            for (expr.cases) |case| {
                if (case.pattern.* == .nil_lit) has_nil = true;
            }
            if (has_nil) return;
            try self.fail("Non-exhaustive match", "Nil match must cover `nil` or have `default`.", expr.line, expr.column);
            return TypeCheckerError.NonExhaustiveMatch;
        }

        _ = self.registry.get_type_info(matched_type);

        // Primitive, union containing primitive, array, table, tuple, etc. -> requires default
        if (self.unionContainsPrimitive(matched_type)) {
            try self.fail("Non-exhaustive match", "Match on primitive or union containing primitive requires `default`.", expr.line, expr.column);
            return TypeCheckerError.NonExhaustiveMatch;
        }

        // Pure enum/error (or union of them) - check variant coverage
        // Collect all enum/error variants from (possibly union) type
        var expected_variants: std.ArrayList([]const u8) = .empty;
        defer expected_variants.deinit(self.allocator);
        var has_enum_error = false;

        // Helper to collect variants from a type id
        const collect = struct {
            fn run(s: *TypeChecker, id: AST.TypeId, out: *std.ArrayList([]const u8), has: *bool) TypeCheckerError!void {
                const inf = s.registry.get_type_info(id);
                switch (inf) {
                    ._enum => |e| {
                        has.* = true;
                        for (e.variants) |v| try out.append(s.allocator, v);
                    },
                    ._error => |e| {
                        has.* = true;
                        for (e.variants) |v| try out.append(s.allocator, v);
                    },
                    ._union => |u| {
                        try run(s, u.left, out, has);
                        try run(s, u.right, out, has);
                    },
                    else => {},
                }
            }
        }.run;

        try collect(self, matched_type, &expected_variants, &has_enum_error);

        if (!has_enum_error) {
            // Should have been caught by primitive check, but be safe
            try self.fail("Non-exhaustive match", "Match requires `default` for this type.", expr.line, expr.column);
            return TypeCheckerError.NonExhaustiveMatch;
        }

        // Collect covered variants (only static_member patterns contribute)
        var covered = std.ArrayList([]const u8).empty;
        defer covered.deinit(self.allocator);
        for (expr.cases) |case| {
            if (case.pattern.* == .static_member_expr) {
                try covered.append(self.allocator, case.pattern.static_member_expr.member.lexeme);
            } else if (case.pattern.* == .default_pat) {
                // already handled has_default
            } else {
                // Non-static pattern (e.g., literal 1 on enum) does not count as covering;
                // type mismatch already reported via is_compatible check, but for exhaustiveness
                // we treat it as not covering any variant (needs default which we don't have)
            }
        }

        for (expected_variants.items) |variant| {
            var found = false;
            for (covered.items) |c| {
                if (std.mem.eql(u8, c, variant)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try self.fail("Non-exhaustive match", "Match does not cover every variant of this type.", expr.line, expr.column);
                return TypeCheckerError.NonExhaustiveMatch;
            }
        }
    }

    fn is_compatible(self: *TypeChecker, target: AST.TypeId, source: AST.TypeId) TypeCheckerError!bool {
        if (target == source) return true;

        const source_info = self.registry.get_type_info(source);
        if (source_info == ._union) {
            return (try self.is_compatible(target, source_info._union.left)) and (try self.is_compatible(target, source_info._union.right));
        }

        const target_info = self.registry.get_type_info(target);

        //  Array[Never] matches Array[T] for any T
        if (target_info == .array and source_info == .array) {
            if (source_info.array == @intFromEnum(PrimitiveType.Never)) {
                return true;
            }
            return try self.is_compatible(target_info.array, source_info.array);
        }

        // Table[Never, Never] matches Table[K, V] for any K, V
        if (target_info == .table and source_info == .table) {
            const key_compat = (source_info.table.key == @intFromEnum(PrimitiveType.Never)) or (try self.is_compatible(target_info.table.key, source_info.table.key));
            const val_compat = (source_info.table.value == @intFromEnum(PrimitiveType.Never)) or (try self.is_compatible(target_info.table.value, source_info.table.value));
            return key_compat and val_compat;
        }

        return switch (target_info) {
            ._union => |u| {
                // source is compatible if it fits either side of target union
                return (try self.is_compatible(u.left, source)) or (try self.is_compatible(u.right, source));
            },
            else => return false,
        };
    }

    fn is_constant_literal(node: *AST.ASTNode) bool {
        return switch (node.*) {
            .int_lit, .float_lit, .str_lit, .bool_lit, .nil_lit => true,
            .unary_expr => |expr| switch (expr.expr.*) {
                .int_lit, .float_lit => std.mem.eql(u8, expr.operator.lexeme, "-") or std.mem.eql(u8, expr.operator.lexeme, "~"),
                else => false,
            },
            else => false,
        };
    }

    fn fail(self: *TypeChecker, message: []const u8, hint: ?[]const u8, line: usize, column: usize) !void {
        try self.diagnostics.add_diagnostic(.{ .file_path = self.module.filepath, .column = column, .line = line, .stage = .TypeChecker, .severity = .Error, .message = message, .hint = hint });
    }

    fn split_error_union(self: *TypeChecker, id: AST.TypeId) ?struct { success: AST.TypeId, err: AST.TypeId } {
        const info = self.registry.get_type_info(id);
        if (info != ._union) return null;
        const left_err = self.registry.get_type_info(info._union.left) == ._error;
        const right_err = self.registry.get_type_info(info._union.right) == ._error;
        if (!left_err and !right_err) return null;
        // NOTE: if both sides are errors - take the left hand side.
        return .{
            .err = if (left_err) info._union.left else info._union.right,
            .success = if (left_err) info._union.right else info._union.left,
        };
    }
};
