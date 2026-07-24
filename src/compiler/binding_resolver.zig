const std = @import("std");
const AST = @import("ast.zig");
const TypeRegistry = @import("type_registry.zig");
const PrimitiveType = TypeRegistry.PrimitiveType;
const Diagnostics = @import("../diagnostics/diagnostics.zig");
const DiagnosticReporter = Diagnostics.DiagnosticsReporter;
const Module = @import("workspace.zig").Module;
const Workspace = @import("workspace.zig").Workspace;

pub const BindingResolverError = error{
    MissingDeclRef,
    MissingBinding,
    TooManyLocals,
    TooManyGlobals,
    TooManyUpvalues,
} || std.mem.Allocator.Error || TypeRegistry.TypeRegistryError;

pub const BindingKind = enum {
    global,
    imported_global,
    local,
    param,
    upvalue,
    method,
    comptime_type,
};

pub const BindingInfo = struct {
    kind: BindingKind,
    slot: u16,
    type_id: AST.TypeId,
    decl: AST.DeclRef,
    name: []const u8,
    module_path: ?[]const u8 = null,
};

pub const UpvalueInfo = struct {
    index: u16,
    captures_parent_local: bool,
    parent_slot: u16,
    decl: AST.DeclRef,
    type_id: AST.TypeId,
};

pub const FunctionInfo = struct {
    param_count: u16,
    max_local_count: u16,
    upvalues: []UpvalueInfo,
};

pub const MemberInfo = union(enum) {
    field: struct { index: u16, type_id: AST.TypeId },
    method: struct { index: u16, type_id: AST.TypeId },
    tuple_index: struct { index: u16, type_id: AST.TypeId },
    static_field: struct { index: u16, type_id: AST.TypeId },
    static_method: struct { index: u16, type_id: AST.TypeId },
    enum_variant: struct { index: u16, type_id: AST.TypeId },
    error_variant: struct { index: u16, type_id: AST.TypeId },
    struct_init: struct { type_id: AST.TypeId, field_indexes: []u16 },
};

pub const BindingResolution = struct {
    allocator: std.mem.Allocator,
    declaration_bindings: std.AutoHashMap(AST.DeclRef, BindingInfo),
    identifier_bindings: std.AutoHashMap(*AST.ASTNode, BindingInfo),
    function_infos: std.AutoHashMap(*AST.ASTNode, FunctionInfo),
    scope_pop_counts: std.AutoHashMap(*AST.ASTNode, u16),
    member_infos: std.AutoHashMap(*AST.ASTNode, MemberInfo),

    pub fn init(allocator: std.mem.Allocator) BindingResolution {
        return .{
            .allocator = allocator,
            .declaration_bindings = std.AutoHashMap(AST.DeclRef, BindingInfo).init(allocator),
            .identifier_bindings = std.AutoHashMap(*AST.ASTNode, BindingInfo).init(allocator),
            .function_infos = std.AutoHashMap(*AST.ASTNode, FunctionInfo).init(allocator),
            .scope_pop_counts = std.AutoHashMap(*AST.ASTNode, u16).init(allocator),
            .member_infos = std.AutoHashMap(*AST.ASTNode, MemberInfo).init(allocator),
        };
    }

    pub fn deinit(self: *BindingResolution) void {
        var fn_it = self.function_infos.valueIterator();
        while (fn_it.next()) |info| {
            self.allocator.free(info.upvalues);
        }

        var member_it = self.member_infos.valueIterator();
        while (member_it.next()) |info| {
            switch (info.*) {
                .struct_init => |struct_init| self.allocator.free(struct_init.field_indexes),
                else => {},
            }
        }

        self.declaration_bindings.deinit();
        self.identifier_bindings.deinit();
        self.function_infos.deinit();
        self.scope_pop_counts.deinit();
        self.member_infos.deinit();
    }
};

const FunctionContext = struct {
    function_node: *AST.ASTNode,
    param_count: u16,
    local_count: u16,
    max_local_count: u16,
    upvalues: std.ArrayList(UpvalueInfo),
    upvalue_slots: std.AutoHashMap(AST.DeclRef, u16),

    fn init(allocator: std.mem.Allocator, function_node: *AST.ASTNode, param_count: u16) FunctionContext {
        return .{
            .function_node = function_node,
            .param_count = param_count,
            .local_count = param_count,
            .max_local_count = param_count,
            .upvalues = .empty,
            .upvalue_slots = std.AutoHashMap(AST.DeclRef, u16).init(allocator),
        };
    }

    fn deinit(self: *FunctionContext, allocator: std.mem.Allocator) void {
        self.upvalues.deinit(allocator);
        self.upvalue_slots.deinit();
    }
};

pub const BindingResolver = struct {
    allocator: std.mem.Allocator,
    registry: *TypeRegistry.TypeRegistry,
    diagnostics: *DiagnosticReporter,
    module: *Module,
    workspace: *Workspace,
    result: BindingResolution,
    functions: std.ArrayList(FunctionContext),
    local_owners: std.AutoHashMap(AST.DeclRef, *AST.ASTNode),
    next_global_slot: u16 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *TypeRegistry.TypeRegistry,
        diagnostics: *DiagnosticReporter,
        module: *Module,
        workspace: *Workspace,
    ) BindingResolver {
        return .{
            .allocator = allocator,
            .registry = registry,
            .diagnostics = diagnostics,
            .module = module,
            .workspace = workspace,
            .result = BindingResolution.init(allocator),
            .functions = .empty,
            .local_owners = std.AutoHashMap(AST.DeclRef, *AST.ASTNode).init(allocator),
        };
    }

    pub fn deinit(self: *BindingResolver) void {
        for (self.functions.items) |*ctx| {
            ctx.deinit(self.allocator);
        }
        self.functions.deinit(self.allocator);
        self.local_owners.deinit();
        self.result.deinit();
    }

    pub fn resolve(allocator: std.mem.Allocator, registry: *TypeRegistry.TypeRegistry, diagnostics: *DiagnosticReporter, module: *Module, workspace: *Workspace, root: *AST.ASTNode) !BindingResolution {
        var resolver = BindingResolver.init(allocator, registry, diagnostics, module, workspace);
        errdefer resolver.deinit();

        try resolver.resolveProgram(root);

        const result = resolver.result;
        resolver.result = BindingResolution.init(allocator);
        resolver.deinit();
        return result;
    }

    fn resolveProgram(self: *BindingResolver, node: *AST.ASTNode) BindingResolverError!void {
        if (node.* != .program) return self.fail(node, "Binding resolver expected a program root.", "This is an internal error. Please make a bug report.", BindingResolverError.MissingBinding);

        try self.pre_hoist_declarations(node);
        try self.begin_function(node, 0);
        for (node.program.declarations) |decl| {
            try self.resolveNode(decl, true);
        }
        try self.end_function();
    }

    fn pre_hoist_declarations(self: *BindingResolver, node: *AST.ASTNode) BindingResolverError!void {
        for (node.program.declarations) |decl_node| {
            switch (decl_node.*) {
                .use_decl => |decl| {
                    for (decl.items, 0..) |item, index| {
                        const ref: AST.DeclRef = .{ .import = .{ .use_decl = decl_node, .index = @as(u32, @intCast(index)) } };
                        const name = (item.alias orelse item.name).lexeme;
                        const type_id = try self.import_typeid(decl, item);
                        const kind = self.importBindingKind(type_id, item.name.lexeme);
                        try self.putDeclBinding(ref, .{
                            .kind = kind,
                            .slot = try self.next_global(),
                            .type_id = type_id,
                            .decl = ref,
                            .name = name,
                            .module_path = decl.resolved_module_path,
                        });
                    }
                },
                .fn_decl => |decl| try self.registerGlobalNode(decl_node, decl.name.lexeme, try self.functionTypeId(decl_node)),
                .co_decl => |decl| try self.registerGlobalNode(decl_node, decl.name.lexeme, try self.coroutineTypeId(decl_node)),
                .struct_decl => |decl| try self.registerComptimeNode(decl_node, decl.name.lexeme, try self.named_typeid(decl.name.lexeme, decl_node)),
                .type_decl => |decl| try self.registerComptimeNode(decl_node, decl.name.lexeme, try self.named_typeid(decl.name.lexeme, decl_node)),
                .enum_decl => |decl| try self.registerComptimeNode(decl_node, decl.name.lexeme, try self.named_typeid(decl.name.lexeme, decl_node)),
                .error_decl => |decl| try self.registerComptimeNode(decl_node, decl.name.lexeme, try self.named_typeid(decl.name.lexeme, decl_node)),
                else => {},
            }
        }
    }

    fn resolveNode(self: *BindingResolver, node: *AST.ASTNode, direct_program_decl: bool) BindingResolverError!void {
        switch (node.*) {
            .program => try self.resolveProgram(node),
            .use_decl, .type_decl, .enum_decl, .error_decl => {},
            .struct_decl => |decl| try self.resolveStructDecl(node, decl),
            .var_decl => |decl| try self.resolveVarDecl(node, decl, direct_program_decl),
            .fn_decl => |decl| try self.resolveFnDecl(node, decl, direct_program_decl, false),
            .co_decl => |decl| try self.resolveCoDecl(node, decl, direct_program_decl, false),
            .block_stmt => try self.resolveBlock(node),
            .return_stmt => |stmt| if (stmt.expr) |expr| try self.resolveNode(expr, false),
            .yield_stmt => |stmt| if (stmt.expr) |expr| try self.resolveNode(expr, false),
            .give_stmt => |stmt| try self.resolveNode(stmt.expr, false),
            .break_stmt, .continue_stmt => {},
            .while_stmt => |stmt| {
                try self.resolveNode(stmt.condition, false);
                try self.resolveNode(stmt.body, false);
            },
            .for_stmt => |stmt| try self.resolveForStmt(node, stmt),
            .if_stmt => |stmt| {
                try self.resolveNode(stmt.condition, false);
                try self.resolveNode(stmt.then_branch, false);
                if (stmt.else_branch) |branch| try self.resolveNode(branch, false);
            },
            .panic_stmt => |stmt| try self.resolveNode(stmt.expr, false),
            .expr_stmt => |stmt| try self.resolveNode(stmt.expr, false),
            .assign_expr => |expr| {
                try self.resolveNode(expr.left, false);
                try self.resolveNode(expr.right, false);
            },
            .identifier_expr => try self.resolveIdentifier(node),
            .unary_expr => |expr| try self.resolveNode(expr.expr, false),
            .binary_expr => |expr| {
                try self.resolveNode(expr.left, false);
                try self.resolveNode(expr.right, false);
            },
            .call_expr => |expr| {
                try self.resolveNode(expr.expr, false);
                for (expr.args) |arg| try self.resolveNode(arg, false);
            },
            .index_expr => |expr| {
                try self.resolveNode(expr.expr, false);
                try self.resolveNode(expr.index, false);
            },
            .array_expr => |expr| for (expr.elements) |element| try self.resolveNode(element, false),
            .dot_expr => |expr| {
                try self.resolveNode(expr.expr, false);
                try self.resolve_dot_expression(node, expr);
            },
            .static_member_expr => |expr| {
                try self.resolveNode(expr.expr, false);
                try self.resolve_static_member_expression(node, expr);
            },
            .try_expr => |expr| try self.resolveNode(expr.expr, false),
            .resume_expr => |expr| try self.resolveNode(expr.expr, false),
            .group_expr => |expr| try self.resolveNode(expr.expr, false),
            .tuple_expr => |expr| for (expr.exprs) |child| try self.resolveNode(child, false),
            .table_expr => |expr| {
                for (expr.keys) |key| try self.resolveNode(key, false);
                for (expr.values) |value| try self.resolveNode(value, false);
            },
            .new_expr => |expr| try self.resolveNewExpr(node, expr),
            .match_expr => |expr| {
                try self.resolveNode(expr.expr, false);
                for (expr.cases) |case| {
                    try self.resolveNode(case.pattern, false);
                    try self.resolveNode(case.stmt, false);
                }
            },
            .anon_fn_expr => |expr| try self.resolveAnonFnExpr(node, expr),
            .anon_co_expr => |expr| try self.resolveAnonCoExpr(node, expr),
            .int_lit, .float_lit, .str_lit, .bool_lit, .nil_lit, .default_pat => {},
            .nil_type, .int_type, .float_type, .string_type, .bool_type, .array_type, .table_type, .range_type, .never_type, .tuple_type, .identifier_type, .fn_type, .co_type, .union_type => {},
        }
    }

    fn resolveStructDecl(self: *BindingResolver, node: *AST.ASTNode, decl: *AST.StructDecl) BindingResolverError!void {
        for (decl.fields) |field| {
            if (field.default_value) |value| try self.resolveNode(value, false);
        }

        _ = self.result.declaration_bindings.get(.{ .node = node }) orelse return self.fail(node, "Missing struct binding.", null, BindingResolverError.MissingBinding);
        for (decl.methods, 0..) |method, index| {
            const ref: AST.DeclRef = .{ .node = method.method };
            try self.putDeclBinding(ref, .{
                .kind = .method,
                .slot = @intCast(index),
                .type_id = try self.callableTypeId(method.method),
                .decl = ref,
                .name = method.name.lexeme,
                .module_path = self.module.filepath,
            });
        }
        for (decl.methods) |method| {
            switch (method.method.*) {
                .fn_decl => |fn_decl| try self.resolveFnDecl(method.method, fn_decl, false, true),
                .co_decl => |co_decl| try self.resolveCoDecl(method.method, co_decl, false, true),
                else => try self.fail(method.method, "Struct method is not callable.", null, BindingResolverError.MissingBinding),
            }
        }
    }

    fn resolveVarDecl(self: *BindingResolver, node: *AST.ASTNode, decl: *AST.VarDecl, direct_program_decl: bool) !void {
        try self.resolveNode(decl.initializer, false);
        const type_id = if (decl.type_annotation) |annotated| try self.registry.resolve(annotated) else resolved_type_of(decl.initializer);
        const ref: AST.DeclRef = .{ .node = node };
        if (direct_program_decl) {
            try self.putDeclBinding(ref, .{
                .kind = .global,
                .slot = try self.next_global(),
                .type_id = type_id,
                .decl = ref,
                .name = decl.name.lexeme,
                .module_path = self.module.filepath,
            });
        } else {
            try self.registerLocal(ref, decl.name.lexeme, type_id);
        }
    }

    fn resolveFnDecl(self: *BindingResolver, node: *AST.ASTNode, decl: *AST.FnDecl, direct_program_decl: bool, is_method: bool) !void {
        if (!direct_program_decl and !is_method and !self.result.declaration_bindings.contains(.{ .node = node })) {
            try self.registerLocal(.{ .node = node }, decl.name.lexeme, try self.functionTypeId(node));
        }

        const type_id = try self.callableTypeId(node);
        const type_info = self.registry.get_type_info(type_id);
        const param_count: u16 = @intCast(type_info.function.args.len);
        try self.begin_function(node, param_count);
        try self.registerCallableParams(node, decl.params, type_info.function.args);
        try self.resolveNode(decl.body, false);
        try self.end_function();
    }

    fn resolveCoDecl(self: *BindingResolver, node: *AST.ASTNode, decl: *AST.CoDecl, direct_program_decl: bool, is_method: bool) !void {
        if (!direct_program_decl and !is_method and !self.result.declaration_bindings.contains(.{ .node = node })) {
            try self.registerLocal(.{ .node = node }, decl.name.lexeme, try self.coroutineTypeId(node));
        }

        const type_id = try self.callableTypeId(node);
        const type_info = self.registry.get_type_info(type_id);
        const param_count: u16 = @intCast(type_info.coroutine.args.len);
        try self.begin_function(node, param_count);
        try self.registerCallableParams(node, decl.params, type_info.coroutine.args);
        try self.resolveNode(decl.body, false);
        try self.end_function();
    }

    fn resolveAnonFnExpr(self: *BindingResolver, node: *AST.ASTNode, expr: *AST.AnonFnExpr) !void {
        const type_info = self.registry.get_type_info(expr.resolved_type);
        const param_count: u16 = @intCast(type_info.function.args.len);
        try self.begin_function(node, param_count);
        try self.registerCallableParams(node, expr.params, type_info.function.args);
        try self.resolveNode(expr.body, false);
        try self.end_function();
    }

    fn resolveAnonCoExpr(self: *BindingResolver, node: *AST.ASTNode, expr: *AST.AnonCoExpr) !void {
        const type_info = self.registry.get_type_info(expr.resolved_type);
        const param_count: u16 = @intCast(type_info.coroutine.args.len);
        try self.begin_function(node, param_count);
        try self.registerCallableParams(node, expr.params, type_info.coroutine.args);
        try self.resolveNode(expr.body, false);
        try self.end_function();
    }

    fn resolveBlock(self: *BindingResolver, node: *AST.ASTNode) !void {
        const floor = self.current_function().local_count;
        for (node.block_stmt.stmts) |stmt| try self.resolveNode(stmt, false);
        const current = self.current_function();
        const pop_count = current.local_count - floor;
        try self.result.scope_pop_counts.put(node, pop_count);
        current.local_count = floor;
    }

    fn resolveForStmt(self: *BindingResolver, node: *AST.ASTNode, stmt: *AST.ForStmt) !void {
        try self.resolveNode(stmt.iterator_expr, false);
        const floor = self.current_function().local_count;
        try self.registerLocal(.{ .node = node }, stmt.iterator_name.lexeme, @intFromEnum(PrimitiveType.Int));
        try self.resolveNode(stmt.body, false);
        const current = self.current_function();
        const pop_count = current.local_count - floor;
        try self.result.scope_pop_counts.put(node, pop_count);
        current.local_count = floor;
    }

    fn resolveIdentifier(self: *BindingResolver, node: *AST.ASTNode) !void {
        const expr = node.identifier_expr;
        const ref = expr.resolved_decl orelse {
            try self.diagnostics.add_diagnostic(.{
                .file_path = self.module.filepath,
                .line = expr.line,
                .column = expr.column,
                .stage = .CodeGenerator,
                .severity = .Error,
                .message = "Identifier is missing declaration identity.",
                .hint = "Run type checking before binding resolution.",
            });
            return BindingResolverError.MissingDeclRef;
        };

        const binding = self.result.declaration_bindings.get(ref) orelse {
            try self.diagnostics.add_diagnostic(.{
                .file_path = self.module.filepath,
                .line = expr.line,
                .column = expr.column,
                .stage = .CodeGenerator,
                .severity = .Error,
                .message = "Identifier declaration has no runtime binding.",
                .hint = "The resolver and type checker disagree about this symbol.",
            });
            return BindingResolverError.MissingBinding;
        };

        if (self.local_owners.get(ref)) |owner| {
            if (owner != self.current_function().function_node) {
                const slot = try self.capture(ref, binding.type_id, owner);
                var use_binding = binding;
                use_binding.kind = .upvalue;
                use_binding.slot = slot;
                try self.result.identifier_bindings.put(node, use_binding);
                return;
            }
        }

        try self.result.identifier_bindings.put(node, binding);
    }

    fn resolve_dot_expression(self: *BindingResolver, node: *AST.ASTNode, expr: *AST.DotExpr) !void {
        const obj_type = resolved_type_of(expr.expr);
        switch (self.registry.get_type_info(obj_type)) {
            .tuple => |items| {
                const index = std.fmt.parseInt(u16, expr.member.lexeme, 10) catch return;
                if (index < items.len) {
                    try self.result.member_infos.put(node, .{ .tuple_index = .{ .index = index, .type_id = items[index] } });
                    return;
                }
            },
            ._struct => |info| {
                for (info.fields, 0..) |field, index| {
                    if (!field.is_static and std.mem.eql(u8, field.name, expr.member.lexeme)) {
                        try self.result.member_infos.put(node, .{ .field = .{ .index = @intCast(index), .type_id = field.type } });
                        return;
                    }
                }
                for (info.methods, 0..) |method, index| {
                    if (!method.is_static and std.mem.eql(u8, method.name, expr.member.lexeme)) {
                        try self.result.member_infos.put(node, .{ .method = .{ .index = @intCast(index), .type_id = method.type } });
                        return;
                    }
                }
            },
            else => {},
        }
    }

    fn resolve_static_member_expression(self: *BindingResolver, node: *AST.ASTNode, expr: *AST.StaticMemberExpr) !void {
        const obj_type = resolved_type_of(expr.expr);
        switch (self.registry.get_type_info(obj_type)) {
            ._struct => |info| {
                for (info.fields, 0..) |field, index| {
                    if (field.is_static and std.mem.eql(u8, field.name, expr.member.lexeme)) {
                        try self.result.member_infos.put(node, .{ .static_field = .{ .index = @intCast(index), .type_id = field.type } });
                        return;
                    }
                }
                for (info.methods, 0..) |method, index| {
                    if (method.is_static and std.mem.eql(u8, method.name, expr.member.lexeme)) {
                        try self.result.member_infos.put(node, .{ .static_method = .{ .index = @intCast(index), .type_id = method.type } });
                        return;
                    }
                }
            },
            ._enum => |info| {
                for (info.variants, 0..) |variant, index| {
                    if (std.mem.eql(u8, variant, expr.member.lexeme)) {
                        try self.result.member_infos.put(node, .{ .enum_variant = .{ .index = @intCast(index), .type_id = obj_type } });
                        return;
                    }
                }
            },
            ._error => |info| {
                for (info.variants, 0..) |variant, index| {
                    if (std.mem.eql(u8, variant, expr.member.lexeme)) {
                        try self.result.member_infos.put(node, .{ .error_variant = .{ .index = @intCast(index), .type_id = obj_type } });
                        return;
                    }
                }
            },
            else => {},
        }
    }

    fn resolveNewExpr(self: *BindingResolver, node: *AST.ASTNode, expr: *AST.NewExpr) !void {
        for (expr.fields) |field| try self.resolveNode(field.value, false);
        const type_id = expr.resolved_type;
        const info = self.registry.get_type_info(type_id);
        if (info != ._struct) return;

        const field_indexes = try self.allocator.alloc(u16, expr.fields.len);
        errdefer self.allocator.free(field_indexes);
        for (expr.fields, 0..) |provided, out_index| {
            field_indexes[out_index] = 0;
            for (info._struct.fields, 0..) |field, field_index| {
                if (std.mem.eql(u8, field.name, provided.name.lexeme)) {
                    field_indexes[out_index] = @intCast(field_index);
                    break;
                }
            }
        }

        try self.result.member_infos.put(node, .{ .struct_init = .{ .type_id = type_id, .field_indexes = field_indexes } });
    }

    fn registerCallableParams(self: *BindingResolver, func: *AST.ASTNode, params: []*AST.TypedNamedField, arg_types: []AST.TypeId) !void {
        const offset: usize = if (arg_types.len == params.len + 1) 1 else 0;
        if (offset == 1) {
            const ref: AST.DeclRef = .{ .param = .{ .func = func, .index = 0 } };
            try self.registerParam(ref, "self", arg_types[0]);
        }

        for (params, arg_types[offset..], 0..) |param, type_id, index| {
            const slot: u32 = @intCast(index + offset);
            const ref: AST.DeclRef = .{ .param = .{ .func = func, .index = slot } };
            try self.registerParam(ref, param.name.lexeme, type_id);
        }
    }

    fn registerParam(self: *BindingResolver, ref: AST.DeclRef, name: []const u8, type_id: AST.TypeId) !void {
        const slot: u16 = @intCast(ref.param.index);
        const function_node = self.current_function().function_node;
        try self.local_owners.put(ref, function_node);
        try self.putDeclBinding(ref, .{
            .kind = .param,
            .slot = slot,
            .type_id = type_id,
            .decl = ref,
            .name = name,
            .module_path = self.module.filepath,
        });
    }

    fn registerLocal(self: *BindingResolver, ref: AST.DeclRef, name: []const u8, type_id: AST.TypeId) !void {
        const current = self.current_function();
        const slot = current.local_count;
        if (slot == std.math.maxInt(u16)) return self.fail(null, "Too many local bindings in function.", null, BindingResolverError.TooManyLocals);
        current.local_count += 1;
        current.max_local_count = @max(current.max_local_count, current.local_count);

        try self.local_owners.put(ref, current.function_node);
        try self.putDeclBinding(ref, .{
            .kind = .local,
            .slot = slot,
            .type_id = type_id,
            .decl = ref,
            .name = name,
            .module_path = self.module.filepath,
        });
    }

    fn registerGlobalNode(self: *BindingResolver, node: *AST.ASTNode, name: []const u8, type_id: AST.TypeId) !void {
        const ref: AST.DeclRef = .{ .node = node };
        try self.putDeclBinding(ref, .{
            .kind = .global,
            .slot = try self.next_global(),
            .type_id = type_id,
            .decl = ref,
            .name = name,
            .module_path = self.module.filepath,
        });
    }

    fn registerComptimeNode(self: *BindingResolver, node: *AST.ASTNode, name: []const u8, type_id: AST.TypeId) !void {
        const ref: AST.DeclRef = .{ .node = node };
        try self.putDeclBinding(ref, .{
            .kind = .comptime_type,
            .slot = 0,
            .type_id = type_id,
            .decl = ref,
            .name = name,
            .module_path = self.module.filepath,
        });
    }

    fn putDeclBinding(self: *BindingResolver, ref: AST.DeclRef, info: BindingInfo) !void {
        if (!self.result.declaration_bindings.contains(ref)) {
            try self.result.declaration_bindings.put(ref, info);
        }
    }

    fn begin_function(self: *BindingResolver, node: *AST.ASTNode, param_count: u16) !void {
        try self.functions.append(self.allocator, FunctionContext.init(self.allocator, node, param_count));
    }

    fn end_function(self: *BindingResolver) !void {
        var function_context = self.functions.pop().?;
        const upvalues = try function_context.upvalues.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(upvalues);
        function_context.upvalue_slots.deinit();
        try self.result.function_infos.put(function_context.function_node, .{
            .param_count = function_context.param_count,
            .max_local_count = function_context.max_local_count,
            .upvalues = upvalues,
        });
    }

    fn capture(self: *BindingResolver, ref: AST.DeclRef, type_id: AST.TypeId, owner: *AST.ASTNode) !u16 {
        var owner_index: ?usize = null;
        var current_index: usize = self.functions.items.len - 1;
        for (self.functions.items, 0..) |ctx, index| {
            if (ctx.function_node == owner) owner_index = index;
        }
        const start = owner_index orelse return BindingResolverError.MissingBinding;
        while (current_index > start) : (current_index -= 1) {
            _ = try self.ensureUpvalue(current_index, ref, type_id, start);
        }
        return self.functions.items[self.functions.items.len - 1].upvalue_slots.get(ref).?;
    }

    fn ensureUpvalue(self: *BindingResolver, context_index: usize, ref: AST.DeclRef, type_id: AST.TypeId, owner_index: usize) !u16 {
        var function_context = &self.functions.items[context_index];
        if (function_context.upvalue_slots.get(ref)) |slot| return slot;

        const captures_parent_local = context_index == owner_index + 1;
        const parent_slot = if (captures_parent_local)
            (self.result.declaration_bindings.get(ref) orelse return BindingResolverError.MissingBinding).slot
        else
            try self.ensureUpvalue(context_index - 1, ref, type_id, owner_index);

        if (function_context.upvalues.items.len > std.math.maxInt(u16)) return BindingResolverError.TooManyUpvalues;
        const slot: u16 = @intCast(function_context.upvalues.items.len);
        try function_context.upvalues.append(self.allocator, .{
            .index = slot,
            .captures_parent_local = captures_parent_local,
            .parent_slot = parent_slot,
            .decl = ref,
            .type_id = type_id,
        });
        try function_context.upvalue_slots.put(ref, slot);
        return slot;
    }

    fn current_function(self: *BindingResolver) *FunctionContext {
        return &self.functions.items[self.functions.items.len - 1];
    }

    fn next_global(self: *BindingResolver) !u16 {
        const slot = self.next_global_slot;
        if (slot == std.math.maxInt(u16)) return BindingResolverError.TooManyGlobals;
        self.next_global_slot += 1;
        return slot;
    }

    fn callableTypeId(self: *BindingResolver, node: *AST.ASTNode) !AST.TypeId {
        if (self.result.declaration_bindings.get(.{ .node = node })) |binding| return binding.type_id;
        return switch (node.*) {
            .fn_decl => self.functionTypeId(node),
            .co_decl => self.coroutineTypeId(node),
            else => BindingResolverError.MissingBinding,
        };
    }

    fn functionTypeId(self: *BindingResolver, node: *AST.ASTNode) !AST.TypeId {
        const decl = node.fn_decl;
        var param_types: std.ArrayList(AST.TypeId) = .empty;
        defer param_types.deinit(self.allocator);
        for (decl.params) |param| try param_types.append(self.allocator, try self.registry.resolve(param.type_annotation));
        return self.registry.add_function_type(try param_types.toOwnedSlice(self.allocator), try self.registry.resolve(decl.return_type_annotation));
    }

    fn coroutineTypeId(self: *BindingResolver, node: *AST.ASTNode) !AST.TypeId {
        const decl = node.co_decl;
        var param_types: std.ArrayList(AST.TypeId) = .empty;
        defer param_types.deinit(self.allocator);
        for (decl.params) |param| try param_types.append(self.allocator, try self.registry.resolve(param.type_annotation));
        return self.registry.add_coroutine_type(try param_types.toOwnedSlice(self.allocator), try self.registry.resolve(decl.return_type_annotation), try self.registry.resolve(decl.yield_type_annotation));
    }

    fn import_typeid(self: *BindingResolver, decl: *AST.UseDecl, item: AST.ImportItem) !AST.TypeId {
        const imported_module = self.workspace.modules.get(decl.resolved_module_path) orelse return BindingResolverError.MissingBinding;
        return imported_module.exports.get(item.name.lexeme) orelse BindingResolverError.MissingBinding;
    }

    fn named_typeid(self: *BindingResolver, name: []const u8, node: *AST.ASTNode) !AST.TypeId {
        if (self.registry.get_named_type(name, self.module.filepath)) |type_id| {
            return type_id;
        }
        try self.fail(node, "Named type has no registry entry.", null, BindingResolverError.MissingBinding);
        return BindingResolverError.MissingBinding;
    }

    fn importBindingKind(self: *BindingResolver, type_id: AST.TypeId, import_name: []const u8) BindingKind {
        const info = self.registry.get_type_info(type_id);
        return switch (info) {
            ._struct => |named| if (std.mem.eql(u8, named.name, import_name)) .comptime_type else .imported_global,
            ._enum => |named| if (std.mem.eql(u8, named.name, import_name)) .comptime_type else .imported_global,
            ._error => |named| if (std.mem.eql(u8, named.name, import_name)) .comptime_type else .imported_global,
            ._type => |named| if (std.mem.eql(u8, named.name, import_name)) .comptime_type else .imported_global,
            else => .imported_global,
        };
    }

    fn fail(self: *BindingResolver, node: ?*AST.ASTNode, message: []const u8, hint: ?[]const u8, err: BindingResolverError) BindingResolverError!void {
        const pos: NodePosition = if (node) |n| node_position(n) else .{ .line = 0, .column = 0 };
        self.diagnostics.add_diagnostic(.{
            .file_path = self.module.filepath,
            .line = pos.line,
            .column = pos.column,
            .stage = .CodeGenerator,
            .severity = .Error,
            .message = message,
            .hint = hint,
        }) catch {};
        return err;
    }
};

fn resolved_type_of(node: *AST.ASTNode) AST.TypeId {
    return switch (node.*) {
        .assign_expr => |v| v.resolved_type,
        .identifier_expr => |v| v.resolved_type,
        .unary_expr => |v| v.resolved_type,
        .binary_expr => |v| v.resolved_type,
        .call_expr => |v| v.resolved_type,
        .index_expr => |v| v.resolved_type,
        .array_expr => |v| v.resolved_type,
        .dot_expr => |v| v.resolved_type,
        .static_member_expr => |v| v.resolved_type,
        .try_expr => |v| v.resolved_type,
        .resume_expr => |v| v.resolved_type,
        .group_expr => |v| v.resolved_type,
        .tuple_expr => |v| v.resolved_type,
        .table_expr => |v| v.resolved_type,
        .new_expr => |v| v.resolved_type,
        .match_expr => |v| v.resolved_type,
        .anon_fn_expr => |v| v.resolved_type,
        .anon_co_expr => |v| v.resolved_type,
        .int_lit => |v| v.resolved_type,
        .float_lit => |v| v.resolved_type,
        .str_lit => |v| v.resolved_type,
        .bool_lit => |v| v.resolved_type,
        .nil_lit => |v| v.resolved_type,
        else => 0,
    };
}

const NodePosition = struct { line: usize, column: usize };

fn node_position(node: *AST.ASTNode) NodePosition {
    return switch (node.*) {
        .var_decl => |v| .{ .line = v.line, .column = v.column },
        .fn_decl => |v| .{ .line = v.line, .column = v.column },
        .type_decl => |v| .{ .line = v.line, .column = v.column },
        .struct_decl => |v| .{ .line = v.line, .column = v.column },
        .enum_decl => |v| .{ .line = v.line, .column = v.column },
        .error_decl => |v| .{ .line = v.line, .column = v.column },
        .co_decl => |v| .{ .line = v.line, .column = v.column },
        .use_decl => |v| .{ .line = v.line, .column = v.column },
        .block_stmt => |v| .{ .line = v.line, .column = v.column },
        .return_stmt => |v| .{ .line = v.line, .column = v.column },
        .yield_stmt => |v| .{ .line = v.line, .column = v.column },
        .give_stmt => |v| .{ .line = v.line, .column = v.column },
        .break_stmt => |v| .{ .line = v.line, .column = v.column },
        .continue_stmt => |v| .{ .line = v.line, .column = v.column },
        .while_stmt => |v| .{ .line = v.line, .column = v.column },
        .for_stmt => |v| .{ .line = v.line, .column = v.column },
        .if_stmt => |v| .{ .line = v.line, .column = v.column },
        .panic_stmt => |v| .{ .line = v.line, .column = v.column },
        .expr_stmt => |v| .{ .line = v.line, .column = v.column },
        .assign_expr => |v| .{ .line = v.line, .column = v.column },
        .identifier_expr => |v| .{ .line = v.line, .column = v.column },
        .unary_expr => |v| .{ .line = v.line, .column = v.column },
        .binary_expr => |v| .{ .line = v.line, .column = v.column },
        .call_expr => |v| .{ .line = v.line, .column = v.column },
        .index_expr => |v| .{ .line = v.line, .column = v.column },
        .array_expr => |v| .{ .line = v.line, .column = v.column },
        .dot_expr => |v| .{ .line = v.line, .column = v.column },
        .static_member_expr => |v| .{ .line = v.line, .column = v.column },
        .try_expr => |v| .{ .line = v.line, .column = v.column },
        .resume_expr => |v| .{ .line = v.line, .column = v.column },
        .group_expr => |v| .{ .line = v.line, .column = v.column },
        .tuple_expr => |v| .{ .line = v.line, .column = v.column },
        .table_expr => |v| .{ .line = v.line, .column = v.column },
        .new_expr => |v| .{ .line = v.line, .column = v.column },
        .match_expr => |v| .{ .line = v.line, .column = v.column },
        .anon_fn_expr => |v| .{ .line = v.line, .column = v.column },
        .anon_co_expr => |v| .{ .line = v.line, .column = v.column },
        .int_lit => |v| .{ .line = v.line, .column = v.column },
        .float_lit => |v| .{ .line = v.line, .column = v.column },
        .str_lit => |v| .{ .line = v.line, .column = v.column },
        .bool_lit => |v| .{ .line = v.line, .column = v.column },
        .nil_lit => |v| .{ .line = v.line, .column = v.column },
        else => .{ .line = 0, .column = 0 },
    };
}
