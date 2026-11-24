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
const ConstValue = @import("const_value.zig").ConstValue;

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
    /// The export would leak state that is not compile-time knowable.
    NonConstantExport,
    /// A public fn/co signature names a type that is not itself public.
    NonPublicTypeExport,
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
    falls_through: bool = true,
};

const GiveContext = struct {
    expected_type: ?AST.TypeId = null,
    saw_give: bool = false,
};

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    registry: *TypeRegistry.TypeRegistry,
    environment: *Environment,
    diagnostics: *DiagnosticReporter,
    module: *Module,
    workspace: *Workspace,

    expected_return_type: ?AST.TypeId = null,
    current_give: ?*GiveContext = null,
    expected_yield_type: ?AST.TypeId = null,
    expected_resume_with_type: ?AST.TypeId = null,

    in_loop: bool = false,
    in_defer: bool = false,
    in_coroutine: bool = false,
    in_function: bool = false,
    current_struct_type: ?AST.TypeId = null,
    current_struct_is_pub: bool = false,

    /// Set whenever a `yield` expression is type-checked so the enclosing
    /// statement/block can propagate the (existential) yield signal.
    saw_yield: bool = false,

    pub fn init(allocator: std.mem.Allocator, registry: *TypeRegistry.TypeRegistry, global_environment: *Environment, diagnostics: *DiagnosticReporter, module: *Module, workspace: *Workspace) TypeChecker {
        return .{ .allocator = allocator, .registry = registry, .environment = global_environment, .diagnostics = diagnostics, .module = module, .workspace = workspace };
    }

    fn native_fn_hoist(self: *TypeChecker, node: *AST.ASTNode, decl: *AST.NativeFnDecl) !u32 {
        var param_types: std.ArrayList(AST.TypeId) = .empty;
        defer param_types.deinit(self.allocator);

        for (decl.params) |param| {
            const param_id = try self.registry.resolve(param.type_annotation);
            try param_types.append(self.allocator, param_id);
        }

        const return_id = try self.registry.resolve(decl.return_type_annotation);
        const fn_id = try self.registry.add_native_function_type(try param_types.toOwnedSlice(self.allocator), return_id);
        try self.environment.define_binding(decl.name.lexeme, fn_id, .{ .node = node }, true);
        return fn_id;
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

    fn export_symbol(self: *TypeChecker, name: []const u8, type_id: AST.TypeId, node: *AST.ASTNode) !void {
        try self.module.exports.put(name, type_id);
        try self.module.export_nodes.put(name, node);
    }

    /// Private fields and methods are accessible only while checking a method of
    /// their declaring struct. File location does not affect member visibility.
    fn can_access_private_members(self: *TypeChecker, struct_type: AST.TypeId) bool {
        return self.current_struct_type != null and self.current_struct_type.? == struct_type;
    }

    /// A `pub fn`/`pub co` signature may only name types that are themselves exported:
    /// importers must be able to name every type they touch.
    /// Ensure that all types named in a pub signature are exported
    fn check_pub_signature(self: *TypeChecker, type_ids: []const AST.TypeId, line: usize, column: usize) TypeCheckerError!void {
        var visited = std.AutoHashMap(AST.TypeId, void).init(self.allocator);
        defer visited.deinit();
        for (type_ids) |type_id| {
            try self.require_pub_type(type_id, line, column, &visited);
        }
    }

    fn require_pub_type(self: *TypeChecker, type_id: AST.TypeId, line: usize, column: usize, visited: *std.AutoHashMap(AST.TypeId, void)) TypeCheckerError!void {
        if (visited.get(type_id) != null) return; // recursive alias/type cycle guard
        try visited.put(type_id, {});

        const type_info = self.registry.get_type_info(type_id);
        if (self.named_type_of(type_info)) |named| {
            const decl_module = self.workspace.modules.get(named.source_file) orelse return;
            if (!decl_module.exports.contains(named.name)) {
                try self.fail("Non-public type in public signature", "Every named type in a public signature must also be public.", line, column);
                return TypeCheckerError.NonPublicTypeExport;
            }
            // a public alias must not launder a non-public underlying type either
            if (type_info == ._type) {
                try self.require_pub_type(type_info._type.resolved_type, line, column, visited);
            }
            return;
        }
        switch (type_info) {
            .optional => |o| try self.require_pub_type(o.inner, line, column, visited),
            .error_union => |eu| {
                if (eu.err) |e| {
                    try self.require_pub_type(e, line, column, visited);
                }
                try self.require_pub_type(eu.ok, line, column, visited);
            },
            .array => |elem| try self.require_pub_type(elem, line, column, visited),
            .tuple => |items| {
                for (items) |item| try self.require_pub_type(item, line, column, visited);
            },
            .table => |t| {
                try self.require_pub_type(t.key, line, column, visited);
                try self.require_pub_type(t.value, line, column, visited);
            },
            .function => |f| {
                for (f.args) |arg| try self.require_pub_type(arg, line, column, visited);
                try self.require_pub_type(f.ret, line, column, visited);
            },
            .coroutine => |c| {
                for (c.args) |arg| try self.require_pub_type(arg, line, column, visited);
                try self.require_pub_type(c.ret, line, column, visited);
            },
            else => {}, // primitives are always public
        }
    }

    /// Extracts `name`/`source_file` from the named type shapes, or null for
    /// structural/primitive types.
    fn named_type_of(self: *TypeChecker, type_info: TypeRegistry.TypeInfo) ?struct { name: []const u8, source_file: []const u8 } {
        _ = self;
        return switch (type_info) {
            ._struct => |s| .{ .name = s.name, .source_file = s.source_file },
            ._enum => |e| .{ .name = e.name, .source_file = e.source_file },
            ._error => |e| .{ .name = e.name, .source_file = e.source_file },
            ._type => |t| .{ .name = t.name, .source_file = t.source_file },
            .native_type => |n| .{ .name = n.name, .source_file = n.source_file },
            .identifier => |i| .{ .name = i.name, .source_file = i.source_file },
            else => null,
        };
    }

    fn hoist(self: *TypeChecker, node: *AST.ASTNode) TypeCheckerError!void {
        switch (node.*) {
            .program => |program| {
                for (program.declarations) |decl| {
                    if (decl.* == .enum_decl) try self.pre_register_enum(decl, decl.enum_decl);
                }
                for (program.declarations) |decl| try self.hoist(decl);
            },
            .use_decl => |decl| {
                const imported_module = self.workspace.modules.get(decl.resolved_module_path) orelse {
                    return TypeCheckerError.UndefinedSymbol;
                };

                for (decl.items, 0..) |item, index| {
                    const alias = item.alias orelse item.name;
                    if (imported_module.exports.get(item.name.lexeme)) |resolved_id| {
                        const exported_node = imported_module.export_nodes.get(item.name.lexeme) orelse {
                            try self.fail("Imported symbol has no export declaration.", null, item.name.line, item.name.column);
                            return TypeCheckerError.UndefinedSymbol;
                        };
                        // A type symbol (not a value of that type) keeps its identity
                        // across the module boundary, so variant access stays type-name-only.
                        const is_type_symbol = switch (exported_node.*) {
                            .struct_decl, .enum_decl, .error_decl, .type_decl => true,
                            else => false,
                        };
                        try self.environment.define_symbol(alias.lexeme, resolved_id, .{ .import = .{ .use_decl = node, .index = @as(u32, @intCast(index)) } }, true, is_type_symbol);
                        if (decl.modifier_pub) {
                            // Re-export the original declaration node so further importers
                            // retain the defining module's type identity and binding.
                            try self.export_symbol(alias.lexeme, resolved_id, exported_node);
                        }
                    } else {
                        try self.fail("Failed to import symbol from external module.", "Check that the module path is correct and that the symbol is exported with the 'pub' keyword.", alias.line, alias.column);
                        return TypeCheckerError.UndefinedSymbol;
                    }
                }
            },
            .fn_decl => |decl| {
                const fn_id = try self.fn_hoist(node, decl);
                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, fn_id, node);
                }
            },
            .native_fn_decl => |decl| {
                const fn_id = try self.native_fn_hoist(node, decl);
                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, fn_id, node);
                }
            },
            .co_decl => |decl| {
                const co_id = try self.co_hoist(node, decl);

                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, co_id, node);
                }
            },
            .struct_decl => |decl| {
                if (decl.modifier_pub) {
                    for (decl.fields) |field| {
                        if (field.default_value) |def| {
                            if (ConstValue.from_literal(def) == null) {
                                try self.fail("Exported struct defaults must be literals.", "The default is inlined into the importing module.", field.name.line, field.name.column);
                                return TypeCheckerError.NonConstantExport;
                            }
                        }
                    }
                }
                var field_types: std.ArrayList(StructField) = .empty;
                defer field_types.deinit(self.allocator);

                for (decl.fields) |field| {
                    const field_type = try self.registry.resolve(field.type_annotation);
                    // store the default value if there is one
                    try field_types.append(self.allocator, .{ .name = field.name.lexeme, .type = field_type, .is_pub = field.is_pub, .default_value = field.default_value });
                }

                // Create struct with empty methods first to get its type_id for self
                const struct_id = try self.registry.add_struct_type(decl.name.lexeme, try field_types.toOwnedSlice(self.allocator), &.{}, self.module.filepath);

                var method_types: std.ArrayList(StructMethod) = .empty;
                defer method_types.deinit(self.allocator);

                for (decl.methods) |method| {
                    const method_type = try self.check_declaration_type(method.method, struct_id);
                    // store the node with the method definition
                    try method_types.append(self.allocator, .{ .name = method.name.lexeme, .type = method_type, .is_pub = method.is_pub, .method_node = method.method });
                }

                // Update the struct with actual methods
                self.registry.types.items[struct_id]._struct.methods = try method_types.toOwnedSlice(self.allocator);

                try self.environment.define_type_binding(decl.name.lexeme, struct_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, struct_id, node);
                }
            },
            .type_decl => |decl| {
                const type_annot_id = try self.registry.resolve(decl.type_annotation);
                const type_id = try self.registry.add_type_type(decl.name.lexeme, type_annot_id, self.module.filepath);
                try self.environment.define_type_binding(decl.name.lexeme, type_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, type_id, node);
                }
            },
            .native_type_decl => |decl| {
                const type_id = try self.registry.add_native_type_type(decl.name.lexeme, self.module.filepath);
                try self.environment.define_type_binding(decl.name.lexeme, type_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, type_id, node);
                }
            },
            .enum_decl => |decl| {
                const enum_id = try self.environment.lookup(decl.name.lexeme);
                const has_payloads = for (decl.variants) |variant| {
                    if (variant.type_annotation != null) break true;
                } else false;
                var variants: std.ArrayList(TypeRegistry.EnumVariant) = .empty;
                for (decl.variants) |variant| {
                    const payload_type = if (variant.type_annotation) |annotation| try self.registry.resolve(annotation) else null;
                    try variants.append(self.allocator, .{ .name = variant.variant_name.lexeme, .type = payload_type });
                }
                try self.registry.set_enum_variants(enum_id, try variants.toOwnedSlice(self.allocator), has_payloads);
                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, enum_id, node);
                }
            },
            .error_decl => |decl| {
                var variants: std.ArrayList([]const u8) = .empty;
                defer variants.deinit(self.allocator);
                for (decl.variants) |variant| {
                    try variants.append(self.allocator, variant.lexeme);
                }
                const error_id = try self.registry.add_error_type(decl.name.lexeme, try variants.toOwnedSlice(self.allocator), self.module.filepath);
                try self.environment.define_type_binding(decl.name.lexeme, error_id, .{ .node = node }, true);
                if (decl.modifier_pub) {
                    try self.export_symbol(decl.name.lexeme, error_id, node);
                }
            },
            else => {},
        }
    }

    fn pre_register_enum(self: *TypeChecker, node: *AST.ASTNode, decl: *AST.EnumDecl) TypeCheckerError!void {
        const has_payloads = for (decl.variants) |variant| {
            if (variant.type_annotation != null) break true;
        } else false;
        var placeholders: std.ArrayList(TypeRegistry.EnumVariant) = .empty;
        for (decl.variants) |variant| try placeholders.append(self.allocator, .{ .name = variant.variant_name.lexeme, .type = null });
        const enum_id = try self.registry.add_enum_type(decl.name.lexeme, try placeholders.toOwnedSlice(self.allocator), self.module.filepath, has_payloads);
        try self.environment.define_type_binding(decl.name.lexeme, enum_id, .{ .node = node }, true);
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

                if (self.environment.parent == null and decl.is_const and ConstValue.from_literal(decl.initializer) == null) {
                    try self.fail("Module-level constants must be literals.", "Use a number, string, bool or nil literal. Compile-time evaluation is not supported yet.", decl.line, decl.column);
                    return TypeCheckerError.NonConstantExport;
                }

                if (decl.modifier_pub) {
                    if (!decl.is_const) {
                        try self.fail("Exported variables must be `const`.", "A `pub var` is shared mutable state.", decl.line, decl.column);
                        return TypeCheckerError.NonConstantExport;
                    }
                    try self.export_symbol(decl.name.lexeme, target_type, node);
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

                // Every type in a public signature must itself be public,
                if (decl.modifier_pub and (self.current_struct_type == null or self.current_struct_is_pub)) {
                    var signature: std.ArrayList(AST.TypeId) = .empty;
                    defer signature.deinit(self.allocator);
                    try signature.appendSlice(self.allocator, type_info.function.args);
                    try signature.append(self.allocator, type_info.function.ret);
                    try self.check_pub_signature(signature.items, decl.name.line, decl.name.column);
                }

                // Track expected return type
                const prev_return = self.expected_return_type;
                const prev_give_context = self.current_give;
                self.expected_return_type = type_info.function.ret;
                self.current_give = null;
                defer self.expected_return_type = prev_return;
                defer self.current_give = prev_give_context;

                // Push function scope
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();
                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;

                // Define self if this is a method
                const has_self = decl.params.len > 0 and std.mem.eql(u8, decl.params[0].name.lexeme, "self");
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
                const source_params = if (has_self) decl.params[1..] else decl.params;
                for (source_params, type_info.function.args[param_offset..], 0..) |param, param_id, index| {
                    try self.environment.define_binding(param.name.lexeme, param_id, .{ .param = .{ .func = node, .index = @as(u32, @intCast(index + param_offset)) } }, false);
                }

                const prev_in_func = self.in_function;
                const prev_in_defer = self.in_defer;
                self.in_function = true;
                self.in_defer = false;
                defer self.in_function = prev_in_func;
                defer self.in_defer = prev_in_defer;
                const body_term = try self.check(decl.body);

                const needs_return = type_info.function.ret != @backingInt(PrimitiveType.Nil) and type_info.function.ret != @backingInt(PrimitiveType.Never);

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

                const prev_struct_type = self.current_struct_type;
                const prev_struct_is_pub = self.current_struct_is_pub;
                self.current_struct_type = struct_typeid;
                self.current_struct_is_pub = decl.modifier_pub;
                defer self.current_struct_type = prev_struct_type;
                defer self.current_struct_is_pub = prev_struct_is_pub;

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

                // Every type named in a public signature must itself be public
                if (decl.modifier_pub and (self.current_struct_type == null or self.current_struct_is_pub)) {
                    var signature: std.ArrayList(AST.TypeId) = .empty;
                    defer signature.deinit(self.allocator);
                    try signature.appendSlice(self.allocator, type_info.coroutine.args);
                    try signature.append(self.allocator, type_info.coroutine.ret);
                    try self.check_pub_signature(signature.items, decl.name.line, decl.name.column);
                }

                // Track expected return type
                const prev_return = self.expected_return_type;
                const prev_give_context = self.current_give;
                self.expected_return_type = type_info.coroutine.ret;
                self.current_give = null;
                defer self.expected_return_type = prev_return;
                defer self.current_give = prev_give_context;

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
                const has_self = decl.params.len > 0 and std.mem.eql(u8, decl.params[0].name.lexeme, "self");
                if (has_self) {
                    try self.environment.define_binding("self", type_info.coroutine.args[0], .{ .param = .{ .func = node, .index = 0 } }, true);
                }

                // Define params locally
                const param_offset: usize = if (has_self) 1 else 0;
                const source_params = if (has_self) decl.params[1..] else decl.params;
                for (source_params, type_info.coroutine.args[param_offset..], 0..) |param, param_id, index| {
                    try self.environment.define_binding(param.name.lexeme, param_id, .{ .param = .{ .func = node, .index = @as(u32, @intCast(index + param_offset)) } }, false);
                }

                const prev_in_coroutine = self.in_coroutine;
                const prev_in_defer = self.in_defer;
                self.in_coroutine = true;
                self.in_defer = false;
                defer self.in_coroutine = prev_in_coroutine;
                defer self.in_defer = prev_in_defer;
                const body_term = try self.check(decl.body);
                const needs_return = type_info.coroutine.ret != @backingInt(PrimitiveType.Nil) and type_info.coroutine.ret != @backingInt(PrimitiveType.Never);
                const needs_yield = type_info.coroutine.yield != @backingInt(PrimitiveType.Nil);
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
            // fully handled in hoist phase
            .anon_struct_decl, .enum_decl, .use_decl, .error_decl => return .{},

            .block_stmt => |stmt| {
                var local_env = Environment.init(self.allocator, self.environment);
                defer local_env.deinit();

                const prev_env = self.environment;
                self.environment = &local_env;
                defer self.environment = prev_env;
                var give_context: GiveContext = .{};
                const previous_give = self.current_give;
                if (stmt.is_expr) self.current_give = &give_context;
                defer self.current_give = previous_give;
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

                for (stmt.stmts) |child| {
                    // `yield` is now an expression, so yields nested anywhere in a
                    // statement (var initializer, condition, call arg, ...) are
                    // tracked via the saw_yield flag rather than a statement flag.
                    self.saw_yield = false;
                    const term = try self.check(child);
                    if (!last.falls_through) continue; // unreachable code doesn't contribute to flow
                    last.return_ = last.return_ or term.return_;
                    last.panics = last.panics or term.panics;
                    last.break_ = last.break_ or term.break_;
                    last.continue_ = last.continue_ or term.continue_;
                    last.yield_ = last.yield_ or term.yield_ or self.saw_yield;
                    last.give_ = last.give_ or term.give_;
                    last.falls_through = term.falls_through;
                }
                if (stmt.is_expr) {
                    if (last.falls_through) {
                        try self.fail("Incomplete give expression", "An expression block must `give` a value or diverge on every path.", stmt.line, stmt.column);
                        return TypeCheckerError.InvalidOperation;
                    }
                    stmt.resolved_type = give_context.expected_type orelse @backingInt(PrimitiveType.Never);
                }
                return last;
            },
            .return_stmt => |stmt| {
                var provided_type = @backingInt(PrimitiveType.Nil);
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
                return .{ .return_ = true, .falls_through = false };
            },
            .give_stmt => |stmt| {
                if (self.in_defer) {
                    try self.fail("Invalid Operation", "`give` cannot be used inside a deferred action.", stmt.line, stmt.column);
                    return TypeCheckerError.InvalidOperation;
                }
                const provided_type = try self.check_expression(stmt.expr);
                const context = self.current_give orelse {
                    try self.fail("Invalid Operation", "`give` must be inside a match or expression-position if/block.", stmt.line, stmt.column);
                    return TypeCheckerError.InvalidOperation;
                };
                context.saw_give = true;
                if (provided_type != @backingInt(PrimitiveType.Never)) {
                    if (context.expected_type) |expected_type| {
                        const merged = try self.merge_give_types(expected_type, provided_type);
                        if (merged) |type_id| {
                            context.expected_type = type_id;
                        } else {
                            try self.fail("Type Mismatch", "Gave value does not match the type of earlier give statements.", stmt.line, stmt.column);
                            return TypeCheckerError.TypeMismatch;
                        }
                    } else {
                        context.expected_type = provided_type;
                    }
                }
                return .{ .give_ = true, .falls_through = false };
            },
            .defer_stmt => |stmt| {
                if (!self.in_function and !self.in_coroutine) {
                    try self.fail("Invalid Operation", "`defer` and `errdefer` must be used inside a function or coroutine.", stmt.line, stmt.column);
                    return TypeCheckerError.InvalidOperation;
                }
                const prev_return = self.expected_return_type;
                const prev_yield = self.expected_yield_type;
                const prev_resume = self.expected_resume_with_type;
                const prev_give = self.current_give;
                const prev_loop = self.in_loop;
                const prev_in_defer = self.in_defer;
                self.expected_return_type = null;
                self.expected_yield_type = null;
                self.expected_resume_with_type = null;
                self.current_give = null;
                self.in_loop = false;
                self.in_defer = true;
                defer self.expected_return_type = prev_return;
                defer self.expected_yield_type = prev_yield;
                defer self.expected_resume_with_type = prev_resume;
                defer self.current_give = prev_give;
                defer self.in_loop = prev_loop;
                defer self.in_defer = prev_in_defer;
                _ = try self.check(stmt.body);
                return .{};
            },
            .while_stmt => |stmt| {
                const condition_type = try self.check_expression(stmt.condition);

                // Without a capture the condition must be a plain boolean. With a
                // capture it must be an optional, and the body sees the inner value.
                var capture_inner: ?AST.TypeId = null;
                if (stmt.capture != null) {
                    capture_inner = self.registry.unwrap_optional(condition_type) orelse {
                        try self.fail("Type Mismatch", "`bind` requires an optional (`?T`) condition.", stmt.line, stmt.column);
                        return TypeCheckerError.TypeMismatch;
                    };
                } else if (condition_type != @backingInt(PrimitiveType.Bool)) {
                    try self.fail("Type Mismatch", "While condition must be a boolean.", stmt.line, stmt.column);
                    return TypeCheckerError.TypeMismatch;
                }

                const prev_loop = self.in_loop;
                self.in_loop = true;
                defer self.in_loop = prev_loop;

                var body_term: StatementTermination = undefined;
                if (stmt.capture) |capture| {
                    capture.resolved_type = capture_inner.?;
                    var capture_env = Environment.init(self.allocator, self.environment);
                    defer capture_env.deinit();
                    try capture_env.define_binding(capture.name.lexeme, capture_inner.?, .{ .capture = capture }, true);

                    const prev_env = self.environment;
                    self.environment = &capture_env;
                    defer self.environment = prev_env;
                    body_term = try self.check(stmt.body);
                } else {
                    body_term = try self.check(stmt.body);
                }

                // The loop body may or may not execute, so only the yield flag is
                // propagated. Return/panic/break/continue are not guaranteed so are dropped.
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

                try self.environment.define_binding(stmt.iterator_name.lexeme, @backingInt(PrimitiveType.Int), .{ .node = node }, true);
                const prev_loop = self.in_loop;
                self.in_loop = true;
                const body_term = try self.check(stmt.body);
                self.in_loop = prev_loop;

                return .{ .yield_ = body_term.yield_ };
            },
            .if_stmt => |stmt| {
                const condition_type = try self.check_expression(stmt.condition);
                var give_context: GiveContext = .{};
                const previous_give = self.current_give;
                if (stmt.is_expr) self.current_give = &give_context;
                defer self.current_give = previous_give;

                // A plain `if` requires a boolean. A capture requires an optional
                // condition and binds the inner value inside the body only.
                var capture_inner: ?AST.TypeId = null;
                if (stmt.capture != null) {
                    capture_inner = self.registry.unwrap_optional(condition_type) orelse {
                        try self.fail("Type Mismatch", "`bind` requires an optional (`?T`) condition.", stmt.line, stmt.column);
                        return TypeCheckerError.TypeMismatch;
                    };
                } else if (condition_type != @backingInt(PrimitiveType.Bool)) {
                    try self.fail("Non-boolean condition", "If condition must be a boolean.", stmt.line, stmt.column);
                    return TypeCheckerError.NonBooleanCondition;
                }

                var then_term: StatementTermination = undefined;
                if (stmt.capture) |capture| {
                    capture.resolved_type = capture_inner.?;
                    var capture_env = Environment.init(self.allocator, self.environment);
                    defer capture_env.deinit();
                    try capture_env.define_binding(capture.name.lexeme, capture_inner.?, .{ .capture = capture }, true);

                    const prev_env = self.environment;
                    self.environment = &capture_env;
                    defer self.environment = prev_env;
                    then_term = try self.check(stmt.then_branch);
                } else {
                    then_term = try self.check(stmt.then_branch);
                }

                const else_term = if (stmt.else_branch) |else_branch|
                    try self.check(else_branch)
                else
                    StatementTermination{};

                if (stmt.is_expr) {
                    if (stmt.else_branch == null or then_term.falls_through or else_term.falls_through) {
                        try self.fail("Incomplete if expression", "An if expression needs an else branch, and each branch must `give` or diverge.", stmt.line, stmt.column);
                        return TypeCheckerError.InvalidOperation;
                    }
                    stmt.resolved_type = give_context.expected_type orelse @backingInt(PrimitiveType.Never);
                    return .{ .give_ = give_context.saw_give, .yield_ = then_term.yield_ or else_term.yield_, .falls_through = false };
                }
                if (stmt.condition.* == .bool_lit) {
                    return if (stmt.condition.bool_lit.value) then_term else else_term;
                }
                return .{
                    .return_ = then_term.return_ and else_term.return_,
                    .panics = then_term.panics and else_term.panics,
                    .break_ = then_term.break_ and else_term.break_,
                    .continue_ = then_term.continue_ and else_term.continue_,
                    .yield_ = then_term.yield_ or else_term.yield_,
                    .give_ = then_term.give_ or else_term.give_,
                    .falls_through = then_term.falls_through or else_term.falls_through,
                };
            },
            .break_stmt => |stmt| {
                if (!self.in_loop) {
                    try self.fail("Invalid Operation", "Break statement used outside of a loop.", stmt.line, stmt.column);
                    return TypeCheckerError.BreakOutsideLoop;
                }
                return .{ .break_ = true, .falls_through = false };
            },
            .continue_stmt => |stmt| {
                if (!self.in_loop) {
                    try self.fail("Invalid Operation", "Continue statement used outside of a loop.", stmt.line, stmt.column);
                    return TypeCheckerError.ContinueOutsideLoop;
                }
                return .{ .continue_ = true, .falls_through = false };
            },
            .expr_stmt => |stmt| {
                var term: StatementTermination = .{};
                _ = try self.check_expression_term(stmt.expr, &term);
                return term;
            },
            .panic_stmt => |stmt| {
                _ = try self.check_expression(stmt.expr); // any expression type is allowed - so we can ignore the result
                return .{ .panics = true, .return_ = true, .falls_through = false };
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

                const has_self = self_type != null and decl.params.len > 0 and std.mem.eql(u8, decl.params[0].name.lexeme, "self");
                if (has_self) try param_types.append(self.allocator, self_type.?);
                for (decl.params, 0..) |param, index| {
                    if (std.mem.eql(u8, param.name.lexeme, "self")) {
                        if (!has_self or index != 0 or param.type_annotation.* != .nil_type) {
                            try self.fail("Invalid self parameter", "A struct method receiver must be the first parameter, named `self`, with no type annotation.", param.name.line, param.name.column);
                            return TypeCheckerError.InvalidOperation;
                        }
                        continue;
                    }
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

                const has_self = self_type != null and decl.params.len > 0 and std.mem.eql(u8, decl.params[0].name.lexeme, "self");
                if (has_self) try param_types.append(self.allocator, self_type.?);
                for (decl.params, 0..) |param, index| {
                    if (std.mem.eql(u8, param.name.lexeme, "self")) {
                        if (!has_self or index != 0 or param.type_annotation.* != .nil_type) {
                            try self.fail("Invalid self parameter", "A struct method receiver must be the first parameter, named `self`, with no type annotation.", param.name.line, param.name.column);
                            return TypeCheckerError.InvalidOperation;
                        }
                        continue;
                    }
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
            .block_stmt => |stmt| {
                if (!stmt.is_expr) return TypeCheckerError.UnknownExpression;
                const term = try self.check(node);
                if (out_term) |out| out.* = term;
                return stmt.resolved_type;
            },
            .if_stmt => |stmt| {
                if (!stmt.is_expr) return TypeCheckerError.UnknownExpression;
                const term = try self.check(node);
                if (out_term) |out| out.* = term;
                return stmt.resolved_type;
            },
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
                if (expr.left.* == .identifier_expr or expr.left.* == .dot_expr or expr.left.* == .index_expr) {
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
                        const is_numeric = left_type == @backingInt(PrimitiveType.Int) or left_type == @backingInt(PrimitiveType.Float);

                        if (std.mem.eql(u8, op, "-=") or std.mem.eql(u8, op, "*=") or std.mem.eql(u8, op, "/=") or std.mem.eql(u8, op, "+=") or std.mem.eql(u8, op, "%=") or std.mem.eql(u8, op, "**=")) {
                            if (!is_numeric) {
                                try self.fail("Invalid Operation", "Compound arithmetic assignment requires a numeric left-hand side.", expr.line, expr.column);
                                return TypeCheckerError.InvalidOperation;
                            }
                        }

                        if (std.mem.eql(u8, op, "++=")) {
                            if (!(left_type == @backingInt(PrimitiveType.String) and right_type == @backingInt(PrimitiveType.String))) {
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
                    if (expr_type == @backingInt(PrimitiveType.Float) or expr_type == @backingInt(PrimitiveType.Int)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    try self.fail("Invalid Operation", "Unary `-` requires a numeric operand.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, token.lexeme, "~")) {
                    if (expr_type == @backingInt(PrimitiveType.Int)) {
                        expr.resolved_type = expr_type;
                        return expr_type;
                    }
                    try self.fail("Invalid Operation", "Unary `~` requires an integer operand.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, token.lexeme, "not")) {
                    if (expr_type == @backingInt(PrimitiveType.Bool)) {
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
                var resume_value_type = @backingInt(PrimitiveType.Nil);
                if (expr.arg) |arg| {
                    resume_value_type = try self.check_expression(arg);
                }
                if (!try self.is_compatible(type_info.coroutine.resume_with, resume_value_type)) {
                    try self.fail("Type Mismatch", "Resumed value does not match the coroutine's resume_with type.", expr.line, expr.column);
                    return TypeCheckerError.TypeMismatch;
                }

                expr.resolved_type = try self.coroutine_observation_type(type_info.coroutine.yield);
                return expr.resolved_type;
            },
            .try_expr => |expr| {
                if (self.expected_return_type == null) {
                    try self.fail("`try` used outside function or coroutine", "`try` returns an error and so must be within a function or coroutine.", expr.line, expr.column);
                    return TypeCheckerError.TryOutsideFunction;
                }
                const return_type_info = self.registry.get_type_info(self.expected_return_type.?);
                if (return_type_info != .error_union) {
                    try self.fail("Type Mismatch", "`try` can only be used in a function that returns an error union.", expr.line, expr.column);
                    return TypeCheckerError.TypeMismatch;
                }
                const expr_type = try self.check_expression(expr.expr);
                const type_info = self.registry.get_type_info(expr_type);
                if (type_info != .error_union) {
                    try self.fail("Type Mismatch", "`try` must be used with an error union type: `E!T`", expr.line, expr.column);
                    return TypeCheckerError.TypeMismatch;
                }
                if (return_type_info.error_union.err) |return_err| {
                    const expr_err = type_info.error_union.err orelse {
                        try self.fail("Type Mismatch", "`try` cannot narrow an any-error union into a specific error set.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    };
                    if (return_err != expr_err) {
                        try self.fail("Type Mismatch", "`try` error set does not match the enclosing function's error set.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                }
                expr.resolved_type = type_info.error_union.ok;
                return type_info.error_union.ok;
            },
            .binary_expr => |expr| {
                const left_type: AST.TypeId = try self.check_expression(expr.left);
                const right_type: AST.TypeId = try self.check_expression(expr.right);
                const op = expr.operator.lexeme;

                if (std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "**") or std.mem.eql(u8, op, "/") or std.mem.eql(u8, op, "%")) {
                    const is_int = left_type == @backingInt(PrimitiveType.Int) and right_type == @backingInt(PrimitiveType.Int);
                    const is_float = (left_type == @backingInt(PrimitiveType.Float) or left_type == @backingInt(PrimitiveType.Int)) and
                        (right_type == @backingInt(PrimitiveType.Float) or right_type == @backingInt(PrimitiveType.Int));

                    if (is_int) {
                        expr.resolved_type = @backingInt(PrimitiveType.Int);
                        return expr.resolved_type;
                    } else if (is_float) {
                        expr.resolved_type = @backingInt(PrimitiveType.Float);
                        return expr.resolved_type;
                    }
                    try self.fail("Invalid Operation", "Arithmetic operators require numeric operands.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                } else if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=") or std.mem.eql(u8, op, "<") or std.mem.eql(u8, op, "<=") or std.mem.eql(u8, op, ">") or std.mem.eql(u8, op, ">=")) {
                    if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "!=")) {
                        // Equality also accepts `?T == nil` and `?T == T`
                        const compatible = try self.is_compatible(left_type, right_type) or
                            try self.is_compatible(right_type, left_type);
                        if (!compatible) {
                            try self.fail("Type Mismatch", "Comparison operators require operands of compatible types.", expr.line, expr.column);
                            return TypeCheckerError.TypeMismatch;
                        }
                    } else if (left_type != right_type) {
                        try self.fail("Type Mismatch", "Comparison operators require operands of the same type.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @backingInt(PrimitiveType.Bool);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "and") or std.mem.eql(u8, op, "or")) {
                    if (left_type != @backingInt(PrimitiveType.Bool) or right_type != @backingInt(PrimitiveType.Bool)) {
                        try self.fail("Type Mismatch", "`and` and `or` require boolean operands.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @backingInt(PrimitiveType.Bool);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "++")) { // string concatenation
                    if (left_type != @backingInt(PrimitiveType.String) or right_type != @backingInt(PrimitiveType.String)) {
                        try self.fail("Type Mismatch", "`++` can only concatenate strings.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @backingInt(PrimitiveType.String);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "..")) { // range expression
                    if (left_type != @backingInt(PrimitiveType.Int) or right_type != @backingInt(PrimitiveType.Int)) {
                        try self.fail("Type Mismatch", "Range operator `..` requires integer operands.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    const range_type = try self.registry.add_range_type(left_type, right_type);

                    expr.resolved_type = range_type;
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, ">>") or std.mem.eql(u8, op, "<<") or std.mem.eql(u8, op, "|") or std.mem.eql(u8, op, "&") or std.mem.eql(u8, op, "^")) {
                    if (left_type != @backingInt(PrimitiveType.Int) or right_type != @backingInt(PrimitiveType.Int)) {
                        try self.fail("Type Mismatch", "Bitwise operators require integer operands.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = @backingInt(PrimitiveType.Int);
                    return expr.resolved_type;
                } else if (std.mem.eql(u8, op, "orelse")) {
                    // `a orelse b`: if `a` is nil the result is `b`.
                    // LHS must be `?T`; the result is `T` unless `b` is itself
                    // optional, in which case chaining keeps `?T`.
                    const left_info = self.registry.get_type_info(left_type);
                    if (left_info != .optional) {
                        try self.fail("Invalid Operation", "`orelse` requires an optional (`?T`) on the left-hand side.", expr.line, expr.column);
                        return TypeCheckerError.InvalidOperation;
                    }
                    const inner = left_info.optional.inner;

                    if (right_type == @backingInt(PrimitiveType.Never)) {
                        expr.resolved_type = inner;
                        return expr.resolved_type;
                    }
                    if (try self.is_compatible(inner, right_type)) {
                        expr.resolved_type = inner;
                        return expr.resolved_type;
                    }
                    const right_info = self.registry.get_type_info(right_type);
                    if (right_info == .optional) {
                        if (try self.is_compatible(inner, right_info.optional.inner)) {
                            expr.resolved_type = right_type;
                            return expr.resolved_type;
                        }
                    }

                    try self.fail("Type Mismatch", "`orelse` fallback must match the optional's inner type.", expr.line, expr.column);
                    return TypeCheckerError.TypeMismatch;
                } else if (std.mem.eql(u8, op, "catch")) {
                    const left_info = self.registry.get_type_info(left_type);
                    if (left_info != .error_union) {
                        try self.fail("Type Mismatch", "`catch` must be used with an error union type: `E!T`.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    const ok_type = left_info.error_union.ok;
                    if (ok_type == @backingInt(PrimitiveType.Never)) {
                        // The success branch can never produce a value, so the
                        // fallback is the only value this expression can yield.
                        expr.resolved_type = right_type;
                        return expr.resolved_type;
                    }
                    if (!try self.is_compatible(ok_type, right_type)) {
                        try self.fail("Type Mismatch", "`catch` fallback must match the error union's success type.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                    expr.resolved_type = ok_type;
                    return expr.resolved_type;
                } else {
                    try self.fail("Invalid Operation", "Unsupported binary operator.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                }
            },
            .optional_unwrap_expr => |expr| {
                const expr_type_id = try self.check_expression(expr.expr);
                const inner_type_id = self.registry.unwrap_optional(expr_type_id) orelse {
                    try self.fail("Type Mismatch", "`.?` can only be used to unwrap an optional type.", expr.line, expr.column);
                    return TypeCheckerError.TypeMismatch;
                };
                expr.resolved_type = inner_type_id;
                return inner_type_id;
            },
            .call_expr => |expr| {
                if (expr.expr.* == .dot_expr) {
                    const dot = expr.expr.dot_expr;
                    const receiver_type = try self.check_expression(dot.expr);
                    const receiver_info = self.registry.get_type_info(receiver_type);
                    var receiver_is_type = false;
                    if (dot.expr.* == .identifier_expr) {
                        const binding = self.environment.lookup_binding(dot.expr.identifier_expr.name.lexeme) catch null;
                        receiver_is_type = if (binding) |b| b.is_type else false;
                    }

                    // Struct calls inject a receiver only when the declaration names `self`.
                    if (receiver_info == ._struct) {
                        for (receiver_info._struct.methods) |method| {
                            if (std.mem.eql(u8, method.name, dot.member.lexeme)) {
                                if (!method.is_pub and !self.can_access_private_members(receiver_type)) {
                                    try self.fail("Member is private", "Private methods can only be called from a method of their declaring struct.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
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

                                const has_receiver = switch (method.method_node.*) {
                                    .fn_decl => |d| d.params.len > 0 and std.mem.eql(u8, d.params[0].name.lexeme, "self"),
                                    .co_decl => |d| d.params.len > 0 and std.mem.eql(u8, d.params[0].name.lexeme, "self"),
                                    else => false,
                                };
                                if (receiver_is_type and has_receiver) {
                                    try self.fail("Instance method requires a value receiver.", "Call this method on a struct instance; only associated functions can be called through the type name.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                if (!receiver_is_type and !has_receiver) {
                                    try self.fail("Associated function requires the struct type.", "Call this function through the struct name, not an instance.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                const offset: usize = if (has_receiver) 1 else 0;
                                const expected_arg_count = args.len - offset;
                                if (expr.args.len != expected_arg_count) {
                                    try self.fail("Invalid argument count", "Method expects a different number of arguments.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidArgumentCount;
                                }

                                for (expr.args, 0..) |arg, index| {
                                    const arg_type = try self.check_expression(arg);
                                    if (!try self.is_compatible(args[index + offset], arg_type)) {
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

                    if (receiver_info == .coroutine and
                        (std.mem.eql(u8, dot.member.lexeme, "returned") or std.mem.eql(u8, dot.member.lexeme, "is_finished")))
                    {
                        if (expr.args.len != 0) {
                            try self.fail("Invalid argument count", "Coroutine member expects no arguments.", expr.line, expr.column);
                            return TypeCheckerError.InvalidArgumentCount;
                        }
                        if (std.mem.eql(u8, dot.member.lexeme, "is_finished")) {
                            expr.resolved_type = @backingInt(PrimitiveType.Bool);
                        } else {
                            expr.resolved_type = try self.coroutine_observation_type(receiver_info.coroutine.ret);
                        }
                        dot.resolved_type = expr.resolved_type;
                        return expr.resolved_type;
                    }

                    if (receiver_info == ._enum) {
                        if (!receiver_is_type) {
                            try self.fail("Variant access requires the type name", "Construct enum values through the enum type, such as `Shape.Circle(value)`.", expr.line, expr.column);
                            return TypeCheckerError.InvalidMemberAccess;
                        }
                        for (receiver_info._enum.variants) |variant| {
                            if (!std.mem.eql(u8, dot.member.lexeme, variant.name)) {
                                continue;
                            }
                            if (variant.type) |variant_type| {
                                dot.resolved_type = receiver_type;
                                if (expr.args.len != 1) {
                                    try self.fail("Invalid argument count", "An enum payload variant takes exactly one value.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidArgumentCount;
                                }
                                const provided_type = try self.check_expression(expr.args[0]);
                                if (!try self.is_compatible(variant_type, provided_type)) {
                                    try self.fail("Type Mismatch", "Enum payload value does not match the variant's declared payload type.", expr.line, expr.column);
                                    return TypeCheckerError.TypeMismatch;
                                }
                                expr.resolved_type = receiver_type;
                                return receiver_type;
                            } else {
                                try self.fail("Invalid Access", "Attempting to access a non-payload variant of an enum.", expr.line, expr.column);
                                return TypeCheckerError.InvalidMemberAccess;
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
                            if (!try self.is_compatible(info.args[index], arg_type)) {
                                try self.fail("Type Mismatch", "Argument type does not match the function parameter type.", expr.line, expr.column);
                                return TypeCheckerError.TypeMismatch;
                            }
                        }
                        expr.resolved_type = info.ret;
                    },
                    .native_function => |info| {
                        if (expr.args.len != info.args.len) {
                            try self.fail("Invalid argument count", "Function expects a different number of arguments.", expr.line, expr.column);
                            return TypeCheckerError.InvalidArgumentCount;
                        }
                        for (expr.args, 0..) |arg, index| {
                            const arg_type = try self.check_expression(arg);
                            if (!try self.is_compatible(info.args[index], arg_type)) {
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
                            if (!try self.is_compatible(info.args[index], arg_type)) {
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
                        if (index_type != @backingInt(PrimitiveType.Int)) {
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
                                if (index_type != @backingInt(PrimitiveType.Int)) {
                                    try self.fail("Type Mismatch", "String index must be an integer.", expr.line, expr.column);
                                    return TypeCheckerError.TypeMismatch;
                                }
                                expr.resolved_type = @backingInt(PrimitiveType.String);
                                return @backingInt(PrimitiveType.String);
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

                // Variant access and instance-member access are distinguished by the
                // receiver *symbol*. only a symbol that *is* a type may name its variants.
                var receiver_is_type_symbol = false;
                if (expr.expr.* == .identifier_expr) {
                    const recv_info = self.environment.lookup_binding(expr.expr.identifier_expr.name.lexeme) catch {
                        return TypeCheckerError.UndefinedSymbol;
                    };
                    receiver_is_type_symbol = recv_info.is_type;
                }

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
                        if (receiver_is_type_symbol) {
                            for (_struct.methods) |method| {
                                if (std.mem.eql(u8, method.name, expr.member.lexeme)) {
                                    const takes_receiver = switch (method.method_node.*) {
                                        .fn_decl => |d| d.params.len > 0 and std.mem.eql(u8, d.params[0].name.lexeme, "self"),
                                        .co_decl => |d| d.params.len > 0 and std.mem.eql(u8, d.params[0].name.lexeme, "self"),
                                        else => false,
                                    };
                                    if (!takes_receiver) {
                                        expr.resolved_type = method.type;
                                        return method.type;
                                    }
                                }
                            }
                            try self.fail("Type name has no associated function with this name.", null, expr.line, expr.column);
                            return TypeCheckerError.InvalidMemberAccess;
                        }
                        for (_struct.fields) |field| {
                            if (std.mem.eql(u8, field.name, expr.member.lexeme)) {
                                if (!field.is_pub and !self.can_access_private_members(obj_type)) {
                                    try self.fail("Member is private", "Private fields can only be accessed from a method of their declaring struct.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                expr.resolved_type = field.type;
                                return field.type;
                            }
                        }
                        for (_struct.methods) |method| {
                            if (std.mem.eql(u8, method.name, expr.member.lexeme)) {
                                const method_type = self.registry.get_type_info(method.type);
                                if (method_type != .function and method_type != .coroutine) {
                                    try self.fail("Invalid Member Access", "Member is not a callable method.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                if (!method.is_pub and !self.can_access_private_members(obj_type)) {
                                    try self.fail("Member is private", "Private methods can only be accessed from a method of their declaring struct.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                expr.resolved_type = method.type;
                                return method.type;
                            }
                        }
                        try self.fail("Invalid Member Access", "Struct has no member with this name.", expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                    .coroutine => {
                        // Coroutine state flags are properties; returned() and is_finished() are methods.
                        if (std.mem.eql(u8, expr.member.lexeme, "suspended") or std.mem.eql(u8, expr.member.lexeme, "finished") or std.mem.eql(u8, expr.member.lexeme, "running") or std.mem.eql(u8, expr.member.lexeme, "started")) {
                            expr.resolved_type = @backingInt(PrimitiveType.Bool);
                            return @backingInt(PrimitiveType.Bool);
                        } else {
                            try self.fail("Invalid Member Access", "Use `returned()` or `is_finished()` to inspect coroutine completion.", expr.line, expr.column);
                            return TypeCheckerError.InvalidMemberAccess;
                        }
                    },
                    ._error => |existing_error| {
                        if (!receiver_is_type_symbol) {
                            try self.fail("Variant access requires the type name", "Error variants are constants; write `ErrorType.<variant>`, not `value.<variant>`.", expr.line, expr.column);
                            return TypeCheckerError.InvalidMemberAccess;
                        }
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
                        if (!receiver_is_type_symbol) {
                            try self.fail("Variant access requires the type name", "Enum variants are constants; write `EnumType.<variant>`, not `value.<variant>`.", expr.line, expr.column);
                            return TypeCheckerError.InvalidMemberAccess;
                        }
                        for (existing_enum.variants) |variant| {
                            if (std.mem.eql(u8, variant.name, expr.member.lexeme)) {
                                if (variant.type) |var_type| {
                                    _ = var_type;
                                    try self.fail("Payload variant requires a value", "Call this variant with its payload, for example `Enum.Variant(value)`.", expr.line, expr.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                expr.resolved_type = obj_type;
                                return obj_type;
                            }
                        }
                        try self.fail("Enum has no variant with this name.", null, expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
                    else => {
                        try self.fail("Invalid Member Access", "Type does not support member access.", expr.line, expr.column);
                        return TypeCheckerError.InvalidMemberAccess;
                    },
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
                        try self.fail("Type Mismatch", "All array elements must be the same type.", expr.line, expr.column);
                        return TypeCheckerError.TypeMismatch;
                    }
                }
                // if this array has no initial values it is Array[Never]
                // Array[Never] is compatible with anything
                if (current_id == null) {
                    current_id = @backingInt(PrimitiveType.Never);
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
                        @backingInt(PrimitiveType.Never),
                        @backingInt(PrimitiveType.Never),
                    );
                    expr.resolved_type = table_type;
                } else {
                    table_type = try self.registry.add_table_type(key_type.?, value_type.?);
                    expr.resolved_type = table_type;
                }

                return table_type;
            },
            .anon_struct_instance => |expr| {
                var fields: std.ArrayList(TypeRegistry.StructField) = .empty;
                for (expr.fields) |provided| {
                    for (fields.items) |existing| {
                        if (std.mem.eql(u8, existing.name, provided.name.lexeme)) {
                            try self.fail("Duplicate struct field", "Anonymous struct values cannot provide the same field more than once.", provided.name.line, provided.name.column);
                            return TypeCheckerError.DuplicateSymbol;
                        }
                    }
                    try fields.append(self.allocator, .{
                        .name = provided.name.lexeme,
                        .type = try self.check_expression(provided.value),
                        .is_pub = true,
                        .default_value = null,
                    });
                }
                const methods = try self.allocator.alloc(TypeRegistry.StructMethod, 0);
                const struct_type = try self.registry.add_struct_type("<anonymous>", try fields.toOwnedSlice(self.allocator), methods, "");
                expr.resolved_type = struct_type;
                return struct_type;
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

                // `new` names the fields it initializes, so private fields may be
                // initialized only from a method of the struct being constructed.
                if (!self.can_access_private_members(struct_typeid)) {
                    for (expr.fields) |provided| {
                        for (struct_fields) |struct_field| {
                            if (std.mem.eql(u8, struct_field.name, provided.name.lexeme)) {
                                if (!struct_field.is_pub) {
                                    try self.fail("Member is private", "Private fields can only be initialized from a method of their declaring struct.", provided.name.line, provided.name.column);
                                    return TypeCheckerError.InvalidMemberAccess;
                                }
                                break;
                            }
                        }
                    }
                }

                for (struct_fields) |struct_field| {
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
                var give_context: GiveContext = .{};
                const previous_give = self.current_give;
                self.current_give = &give_context;
                defer self.current_give = previous_give;
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
                var all_non_fallthrough = expr.cases.len > 0;
                for (expr.cases) |case| {
                    // default pattern is catch-all - skip type compatibility
                    if (case.pattern.* != .default_pat) {
                        if (case.payload_binding) |capture| {
                            if (case.pattern.* != .dot_expr) {
                                try self.fail("Invalid payload pattern", "Bind a payload on an enum variant arm, for example `Shape.Circle => bind (radius) { ... }`.", case.line, case.column);
                                return TypeCheckerError.InvalidOperation;
                            }
                            const dot = case.pattern.dot_expr;
                            const receiver_type = try self.check_expression(dot.expr);
                            const receiver_binding = if (dot.expr.* == .identifier_expr)
                                (self.environment.lookup_binding(dot.expr.identifier_expr.name.lexeme) catch null)
                            else
                                null;
                            if (receiver_type != expr_typeid or receiver_binding == null or !receiver_binding.?.is_type) {
                                try self.fail("Invalid enum pattern", "Payload patterns must name a variant of the matched enum type.", case.line, case.column);
                                return TypeCheckerError.TypeMismatch;
                            }
                            const enum_info = self.registry.get_type_info(expr_typeid);
                            if (enum_info != ._enum) return TypeCheckerError.TypeMismatch;
                            var found_variant = false;
                            for (enum_info._enum.variants, 0..) |variant, tag| {
                                if (!std.mem.eql(u8, variant.name, dot.member.lexeme)) continue;
                                const payload_type = variant.type orelse {
                                    try self.fail("Unit variant cannot bind a payload", "This enum variant has no payload to bind.", case.line, case.column);
                                    return TypeCheckerError.TypeMismatch;
                                };
                                capture.resolved_type = payload_type;
                                case.payload_type = payload_type;
                                case.enum_tag = @intCast(tag);
                                dot.resolved_type = expr_typeid;
                                found_variant = true;
                                break;
                            }
                            if (!found_variant) {
                                try self.fail("Enum has no variant with this name", null, dot.line, dot.column);
                                return TypeCheckerError.InvalidMemberAccess;
                            }
                        } else {
                            if (case.pattern.* == .call_expr and case.pattern.call_expr.expr.* == .dot_expr) {
                                const call_dot = case.pattern.call_expr.expr.dot_expr;
                                const receiver_type = try self.check_expression(call_dot.expr);
                                if (self.registry.get_type_info(receiver_type) == ._enum) {
                                    try self.fail("Payload match arm requires bind", "Write `Enum.Variant => bind (value) { ... }` to bind the payload.", case.line, case.column);
                                    return TypeCheckerError.InvalidOperation;
                                }
                            }
                            const case_typeid = try self.check_expression(case.pattern);
                            if (!try self.is_compatible(expr_typeid, case_typeid)) {
                                try self.fail("Type Mismatch", "Match case pattern does not match the matched expression type.", expr.line, expr.column);
                                return TypeCheckerError.TypeMismatch;
                            }
                            if (case.pattern.* == .dot_expr and case.pattern.dot_expr.expr.* == .identifier_expr and self.registry.get_type_info(expr_typeid) == ._enum) {
                                const dot = case.pattern.dot_expr;
                                const enum_info = self.registry.get_type_info(expr_typeid)._enum;
                                for (enum_info.variants, 0..) |variant, tag| {
                                    if (std.mem.eql(u8, variant.name, dot.member.lexeme)) {
                                        case.enum_tag = @intCast(tag);
                                        break;
                                    }
                                }
                            }
                        }
                    }
                    var case_term: StatementTermination = undefined;
                    if (case.payload_binding) |capture| {
                        var arm_env = Environment.init(self.allocator, self.environment);
                        defer arm_env.deinit();
                        try arm_env.define_binding(capture.name.lexeme, capture.resolved_type, .{ .capture = capture }, true);
                        const previous_env = self.environment;
                        self.environment = &arm_env;
                        defer self.environment = previous_env;
                        case_term = try self.check(case.stmt);
                    } else {
                        case_term = try self.check(case.stmt);
                    }
                    all_non_fallthrough = all_non_fallthrough and !case_term.falls_through;
                    if (!case_term.return_ and !case_term.panics) {
                        all_return = false;
                    }
                }
                if (give_context.saw_give and !all_non_fallthrough) {
                    try self.fail("Incomplete match expression", "Every match arm must `give` a value or diverge when any arm uses `give`.", expr.line, expr.column);
                    return TypeCheckerError.InvalidOperation;
                }
                if (out_term) |t| {
                    t.* = if (all_return) .{ .return_ = true, .panics = false, .break_ = false, .continue_ = false, .yield_ = false, .give_ = false, .falls_through = false } else .{};
                }
                if (give_context.saw_give) {
                    const result_type = give_context.expected_type orelse @backingInt(PrimitiveType.Never);
                    expr.resolved_type = result_type;
                    return result_type;
                } else {
                    // there was not a give type, so we return nil
                    expr.resolved_type = @backingInt(PrimitiveType.Nil);
                    return @backingInt(PrimitiveType.Nil);
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
                const prev_give_context = self.current_give;
                self.expected_return_type = ret_typeid;
                self.current_give = null;
                defer self.expected_return_type = prev_ret;
                defer self.current_give = prev_give_context;

                const prev_in_func = self.in_function;
                const prev_in_defer = self.in_defer;
                self.in_function = true;
                self.in_defer = false;
                defer self.in_function = prev_in_func;
                defer self.in_defer = prev_in_defer;

                const body_term = try self.check(expr.body);
                const needs_return = ret_typeid != @backingInt(PrimitiveType.Nil) and ret_typeid != @backingInt(PrimitiveType.Never);
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
                const prev_give_context = self.current_give;
                self.expected_return_type = ret_typeid;
                self.current_give = null;
                defer self.expected_return_type = prev_ret;
                defer self.current_give = prev_give_context;

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

                const prev_in_co = self.in_coroutine;
                const prev_in_defer = self.in_defer;
                self.in_coroutine = true;
                self.in_defer = false;
                defer self.in_coroutine = prev_in_co;
                defer self.in_defer = prev_in_defer;

                const body_term = try self.check(expr.body);
                const needs_return = ret_typeid != @backingInt(PrimitiveType.Nil) and ret_typeid != @backingInt(PrimitiveType.Never);
                const needs_yield = yield_typeid != @backingInt(PrimitiveType.Nil);
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
                lit.resolved_type = @backingInt(PrimitiveType.Int);
                return lit.resolved_type;
            },
            .float_lit => |lit| {
                lit.resolved_type = @backingInt(PrimitiveType.Float);
                return lit.resolved_type;
            },
            .str_lit => |lit| {
                lit.resolved_type = @backingInt(PrimitiveType.String);
                return lit.resolved_type;
            },
            .bool_lit => |lit| {
                lit.resolved_type = @backingInt(PrimitiveType.Bool);
                return lit.resolved_type;
            },
            .nil_lit => |lit| {
                lit.resolved_type = @backingInt(PrimitiveType.Nil);
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
        if (id == @backingInt(PrimitiveType.Never)) return false;
        const info = self.registry.get_type_info(id);
        return switch (info) {
            .primitive => true,
            .array, .table, .range, .tuple, .function, .coroutine, ._struct, ._type => true,
            else => false,
        };
    }

    fn isNeverTypeId(self: *TypeChecker, id: AST.TypeId) bool {
        _ = self;
        return id == @backingInt(PrimitiveType.Never);
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

        // Bool and Nil are finite - check exhaustive without default
        if (matched_type == @backingInt(PrimitiveType.Bool)) {
            if (has_default) return;
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
        if (matched_type == @backingInt(PrimitiveType.Nil)) {
            if (has_default) return;
            var has_nil = false;
            for (expr.cases) |case| {
                if (case.pattern.* == .nil_lit) has_nil = true;
            }
            if (has_nil) return;
            try self.fail("Non-exhaustive match", "Nil match must cover `nil` or have `default`.", expr.line, expr.column);
            return TypeCheckerError.NonExhaustiveMatch;
        }

        _ = self.registry.get_type_info(matched_type);

        // Pure enum/error - check variant coverage
        // Collect all enum/error variants from type
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
                        for (e.variants) |v| try out.append(s.allocator, v.name);
                    },
                    ._error => |e| {
                        has.* = true;
                        for (e.variants) |v| try out.append(s.allocator, v);
                    },
                    else => {},
                }
            }
        }.run;

        try collect(self, matched_type, &expected_variants, &has_enum_error);

        if (!has_enum_error) {
            if (has_default) return;
            // Should have been caught by primitive check, but be safe
            try self.fail("Non-exhaustive match", "Match requires `default` for this type.", expr.line, expr.column);
            return TypeCheckerError.NonExhaustiveMatch;
        }

        // Collect covered variants. Only variant patterns contribute: the receiver must
        // be a symbol that *is* a type (type-name access like `Weekdays.MONDAY`), and
        // the member must actually be a variant of the matched type. A value receiver
        // like `day.MONDAY` never counts as coverage (and is rejected in pattern checking).
        var covered = std.ArrayList([]const u8).empty;
        defer covered.deinit(self.allocator);
        for (expr.cases) |case| {
            if (case.pattern.* == .default_pat) continue;
            if (case.pattern.* != .dot_expr) continue;
            const pattern_dot = case.pattern.dot_expr;
            if (pattern_dot.expr.* != .identifier_expr) continue;
            const recv_info = self.environment.lookup_binding(pattern_dot.expr.identifier_expr.name.lexeme) catch continue;
            if (!recv_info.is_type or recv_info.type_id != matched_type) continue;
            for (expected_variants.items) |variant| {
                if (std.mem.eql(u8, variant, pattern_dot.member.lexeme)) {
                    for (covered.items) |already_covered| {
                        if (std.mem.eql(u8, already_covered, variant)) {
                            try self.fail("Duplicate match variant", "Each enum variant may appear in only one match arm.", case.line, case.column);
                            return TypeCheckerError.DuplicateSymbol;
                        }
                    }
                    try covered.append(self.allocator, pattern_dot.member.lexeme);
                    break;
                }
            }
        }

        if (has_default) return;

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

    /// Returns whether a value of type `provided_type` can be used where
    /// `expected_type` is required.
    ///
    /// `expected_type` is the destination/declared type.
    /// `provided_type` is the actual type of the value being checked.
    fn coroutine_observation_type(self: *TypeChecker, payload_type: AST.TypeId) TypeCheckerError!AST.TypeId {
        if (payload_type == @backingInt(PrimitiveType.Nil) or self.registry.unwrap_optional(payload_type) != null) {
            return payload_type;
        }
        return self.registry.add_optional_type(payload_type);
    }

    fn merge_give_types(self: *TypeChecker, current: AST.TypeId, provided: AST.TypeId) TypeCheckerError!?AST.TypeId {
        const never = @backingInt(PrimitiveType.Never);
        const nil = @backingInt(PrimitiveType.Nil);
        if (provided == never) return current;
        if (current == never) return provided;
        if (current == provided) return current;
        if (current == nil) return try self.coroutine_observation_type(provided);
        if (provided == nil) return try self.coroutine_observation_type(current);
        if (try self.is_compatible(current, provided)) return current;
        if (self.registry.unwrap_optional(provided)) |provided_inner| {
            if (try self.is_compatible(provided_inner, current)) return provided;
        }
        return null;
    }

    fn is_compatible(self: *TypeChecker, expected_type: AST.TypeId, provided_type: AST.TypeId) TypeCheckerError!bool {
        if (expected_type == provided_type) return true;

        const expected_info = self.registry.get_type_info(expected_type);
        const provided_info = self.registry.get_type_info(provided_type);

        if (expected_info == .error_union) {
            const expected_err = expected_info.error_union.err;
            const expected_ok = expected_info.error_union.ok;

            if (provided_type == @backingInt(PrimitiveType.Never)) return true;

            // Another error union:
            // the success sides must be compatible and,
            // the expected error set must cover the provided error set.
            if (provided_info == .error_union) {
                if (expected_err) |expected_error| {
                    const provided_error = provided_info.error_union.err orelse
                        // `!T` means "any error", so it cannot narrow into `E!T`.
                        return false;
                    if (expected_error != provided_error) return false;
                }
                // a union like `E!Never` can only ever carry an error.
                //  There is no success value that could mismatch `expected_ok`, and the error sets matched above.
                if (provided_info.error_union.ok == @backingInt(PrimitiveType.Never)) return true;
                return try self.is_compatible(expected_ok, provided_info.error_union.ok);
            }

            // A bare error value fills the error slot.
            if (provided_info == ._error) {
                if (expected_err) |expected_error| return expected_error == provided_type;
                return true;
            }

            // success promotion: `T` -> `E!T`.
            return try self.is_compatible(expected_ok, provided_type);
        }

        if (expected_info == .optional) {
            const inner = expected_info.optional.inner;

            // nil and Never (diverging) widen into any optional.
            if (provided_type == @backingInt(PrimitiveType.Nil)) return true;
            if (provided_type == @backingInt(PrimitiveType.Never)) return true;

            // T -> ?T (implicit widening)
            if (try self.is_compatible(inner, provided_type)) return true;

            // ?S -> ?T when S is itself usable as T.
            if (provided_info == .optional) {
                return try self.is_compatible(inner, provided_info.optional.inner);
            }

            return false;
        }

        // Optionals never implicitly unwrap: ?T -> T is rejected.
        if (provided_info == .optional) return false;

        //  Array[Never] matches Array[T] for any T
        if (expected_info == .array and provided_info == .array) {
            if (provided_info.array == @backingInt(PrimitiveType.Never)) {
                return true;
            }
            return expected_info.array == provided_info.array;
        }

        // Table[Never, Never] matches Table[K, V] for any K, V
        if (expected_info == .table and provided_info == .table) {
            const key_compat = (provided_info.table.key == @backingInt(PrimitiveType.Never)) or (expected_info.table.key == provided_info.table.key);
            const val_compat = (provided_info.table.value == @backingInt(PrimitiveType.Never)) or (expected_info.table.value == provided_info.table.value);
            return key_compat and val_compat;
        }
        return false;
    }

    fn fail(self: *TypeChecker, message: []const u8, hint: ?[]const u8, line: usize, column: usize) !void {
        try self.diagnostics.add_diagnostic(.{ .file_path = self.module.filepath, .column = column, .line = line, .stage = .TypeChecker, .severity = .Error, .message = message, .hint = hint });
    }
};
