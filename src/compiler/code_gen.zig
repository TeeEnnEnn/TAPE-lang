//! Code generation for the TAPE compiler.
//! Because the contents of the chunk are vulnerable to garbage collection, all allocations should be guarded with stack push/pops

const std = @import("std");

const DiagnosticReporter = @import("../diagnostics/diagnostics.zig").DiagnosticsReporter;
const Chunk = @import("../runtime/chunk.zig").Chunk;
const Opcode = @import("../runtime/chunk.zig").Opcode;
const Entities = @import("../runtime/entities.zig");
const Isolate = @import("../runtime/isolate.zig").Isolate;
const VM = @import("../runtime/vm.zig").VM;
const AST = @import("ast.zig");
const BindingResolver = @import("binding_resolver.zig");
const Module = @import("workspace.zig").Module;
const TypeRegistry = @import("type_registry.zig");
const TypeRegistryImpl = TypeRegistry.TypeRegistry;
const Natives = @import("../natives/natives.zig").Natives;
const ConstValue = @import("const_value.zig").ConstValue;

const INTERNAL_ERROR_MESSAGE = "This is an internal error. Please write a bug report.";

pub const CodeGeneratorError = error{ MissingBinding, UnsupportedNode, UnsupportedOperator, UnsupportedOperandType, LoopSizeTooLarge, InvalidPosition } || std.mem.Allocator.Error || error{
    Utf8InvalidStartByte,
    TruncatedInput,
    Utf8ExpectedContinuation,
    Utf8OverlongEncoding,
    Utf8EncodesSurrogateHalf,
    Utf8CodepointTooLarge,
};

pub const LoopContext = struct {
    allocator: std.mem.Allocator,
    /// All `break` jumps that need to be patched at loop exit
    break_jumps: std.ArrayList(usize),
    /// All `continue` jumps that need to be patched (for `for` loops — forward jumps to FOR_NEXT)
    continue_jumps: std.ArrayList(usize),
    /// Local variable count at the loop's outer boundary - for cleanup
    scope_local_floor: u16,
    defer_scope_floor: u16,
    /// where to jump for `continue` statement (null => forward jump to be patched, used by `for` loops)
    continue_target: ?u32,
    /// parent loop
    enclosing: ?*LoopContext,

    pub fn init(allocator: std.mem.Allocator, scope_floor: u16, defer_floor: u16, continue_target: ?u32, enclosing: ?*LoopContext) LoopContext {
        return .{
            .allocator = allocator,
            .break_jumps = .empty,
            .continue_jumps = .empty,
            .scope_local_floor = scope_floor,
            .defer_scope_floor = defer_floor,
            .continue_target = continue_target,
            .enclosing = enclosing,
        };
    }
    pub fn deinit(self: *LoopContext) void {
        self.break_jumps.deinit(self.allocator);
        self.continue_jumps.deinit(self.allocator);
    }
};

pub const FunctionCompiler = struct {
    allocator: std.mem.Allocator,
    /// The function we are emitting code into
    function: *Entities.ObjectFunction,
    /// The enclosing function
    enclosing: ?*FunctionCompiler,
    current_locals_count: u16 = 0,
    defer_scope_depth: u16 = 0,

    pub fn init(allocator: std.mem.Allocator, function: *Entities.ObjectFunction, enclosing: ?*FunctionCompiler, initial_locals: u16) !*FunctionCompiler {
        const compiler = try allocator.create(FunctionCompiler);
        compiler.* = .{
            .allocator = allocator,
            .function = function,
            .enclosing = enclosing,
            .current_locals_count = initial_locals,
        };
        return compiler;
    }

    pub fn deinit(self: *FunctionCompiler) void {
        self.allocator.destroy(self);
    }

    pub fn chunk(self: *FunctionCompiler) *Chunk {
        return &self.function.chunk;
    }
};

pub const GiveContext = struct {
    allocator: std.mem.Allocator,
    end_jumps: std.ArrayList(usize),
    local_floor: u16,
    defer_scope_floor: u16,

    fn init(allocator: std.mem.Allocator, local_floor: u16, defer_scope_floor: u16) GiveContext {
        return .{ .allocator = allocator, .end_jumps = .empty, .local_floor = local_floor, .defer_scope_floor = defer_scope_floor };
    }

    fn deinit(self: *GiveContext) void {
        self.end_jumps.deinit(self.allocator);
    }
};

pub const CodeGenerator = struct {
    /// base allocator - not for runtime managed entities
    allocator: std.mem.Allocator,
    /// The isolate to allocate runtime managed entities
    isolate: *Isolate,
    /// The binding resolution for the module currently being compiled
    binding_resolution: *const BindingResolver.BindingResolution,
    /// Shared type registry from type checking.
    registry: *TypeRegistry.TypeRegistry,
    /// AST node current being compiled
    node: *AST.ASTNode,
    /// The top of the function compiler stack
    current: *FunctionCompiler,
    /// Diagnostics reporter for error reporting
    diagnostics: *DiagnosticReporter,
    /// The module being compiled
    module: *Module,
    ///The stack of currently executing loop
    current_loop: ?*LoopContext = null,
    current_give: ?*GiveContext = null,

    pub fn init(
        allocator: std.mem.Allocator,
        isolate: *Isolate,
        binding_resolution: *const BindingResolver.BindingResolution,
        registry: *TypeRegistry.TypeRegistry,
        node: *AST.ASTNode,
        diagnostics: *DiagnosticReporter,
        module: *Module,
    ) !CodeGenerator {
        return .{
            .allocator = allocator,
            .isolate = isolate,
            .binding_resolution = binding_resolution,
            .registry = registry,
            .node = node,
            .current = try FunctionCompiler.init(allocator, try Entities.new_function_object(isolate, module.filepath), null, 0),
            .diagnostics = diagnostics,
            .module = module,
        };
    }

    pub fn deinit(self: *CodeGenerator) void {
        self.current.deinit();
        if (self.current_give) |give| {
            give.deinit();
        }
        if (self.current_loop) |loop| {
            loop.deinit();
        }
    }

    pub fn generate(self: *CodeGenerator) ?*Entities.ObjectFunction {
        self.generate_node(self.node) catch {
            return null;
        };
        return self.current.function;
    }

    fn fail(self: *CodeGenerator, message: []const u8, hint: ?[]const u8, line: usize, column: usize) void {
        self.diagnostics.add_diagnostic(.{
            .file_path = self.module.filepath,
            .line = line,
            .column = column,
            .stage = .CodeGenerator,
            .severity = .Error,
            .message = message,
            .hint = hint,
        }) catch {};
    }

    /// Extracts the resolved type from an AST node
    /// Only covers expression nodes
    pub fn resolve_typeof(node: *AST.ASTNode) AST.TypeId {
        return switch (node.*) {
            .block_stmt => |n| n.resolved_type,
            .if_stmt => |n| n.resolved_type,
            .int_lit => |n| n.resolved_type,
            .float_lit => |n| n.resolved_type,
            .str_lit => |n| n.resolved_type,
            .bool_lit => |n| n.resolved_type,
            .nil_lit => |n| n.resolved_type,
            .binary_expr => |n| n.resolved_type,
            .unary_expr => |n| n.resolved_type,
            .identifier_expr => |n| n.resolved_type,
            .assign_expr => |n| n.resolved_type,
            .call_expr => |n| n.resolved_type,
            .index_expr => |n| n.resolved_type,
            .dot_expr => |n| n.resolved_type,
            .optional_unwrap_expr => |n| n.resolved_type,
            .group_expr => |n| n.resolved_type,
            .tuple_expr => |n| n.resolved_type,
            .table_expr => |n| n.resolved_type,
            .array_expr => |n| n.resolved_type,
            .new_expr => |n| n.resolved_type,
            .match_expr => |n| n.resolved_type,
            .anon_struct_instance => |n| n.resolved_type,
            .anon_fn_expr => |n| n.resolved_type,
            .anon_co_expr => |n| n.resolved_type,
            .try_expr => |n| n.resolved_type,
            .resume_expr => |n| n.resolved_type,
            else => unreachable, // caller only invokes this on expression nodes
        };
    }

    fn generate_node(self: *CodeGenerator, node: *AST.ASTNode) CodeGeneratorError!void {
        switch (node.*) {
            .program => |program| {
                for (program.declarations) |decl| {
                    try self.generate_node(decl);
                }
                // implicit top level return
                try self.current.chunk().write_opcode(.OP_NIL, 0);
                try self.current.chunk().write_opcode(.OP_RETURN, 0);
            },
            .var_decl => |decl| {
                try self.generate_var_decl(node, decl);
            },
            .fn_decl => |decl| {
                try self.generate_callable_decl(node, @ptrCast(decl), AST.FnDecl);
            },
            .native_fn_decl => {
                // nothing to do - fully comptime
            },
            .co_decl => |decl| {
                try self.generate_callable_decl(node, @ptrCast(decl), AST.CoDecl);
            },
            .struct_decl => |decl| {
                try self.generate_struct_decl(node, decl);
            },
            .use_decl => {
                // Imports need no codegen: each import item already carries the
                // exporter's resolved binding (slot or inlined constant value).
            },
            .enum_decl => {
                // nothing to do - fully comptime
            },
            .error_decl => {
                // nothing to do - fully comptime
            },
            .type_decl => {
                // nothing to do - fully comptime
            },
            .native_type_decl => {
                // nothing to do - fully comptime
            },
            .expr_stmt => |stmt| {
                try self.generate_expression(stmt.expr);
                try self.current.chunk().write_opcode(.OP_POP, stmt.line);
            },

            .block_stmt => |stmt| {
                var give_context: GiveContext = undefined;
                const previous_give = self.current_give;
                if (stmt.is_expr) {
                    give_context = GiveContext.init(self.allocator, self.current.current_locals_count, self.current.defer_scope_depth);
                    self.current_give = &give_context;
                }
                defer self.current_give = previous_give;
                defer if (stmt.is_expr) give_context.deinit();

                try self.current.chunk().write_opcode(.OP_DEFER_SCOPE, stmt.line);
                self.current.defer_scope_depth += 1;
                for (stmt.stmts) |blk_stmt| {
                    try self.generate_node(blk_stmt);
                }

                try self.emit_defer_run(0, stmt.line);
                self.current.defer_scope_depth -= 1;

                const pop_count = self.binding_resolution.scope_pop_counts.get(node) orelse {
                    self.fail("Block scope has no pop count in binding resolution.", null, stmt.line, stmt.column);
                    return CodeGeneratorError.MissingBinding;
                };

                if (pop_count > 0) {
                    try self.current.chunk().write_opcode(.OP_POP_N, stmt.line);
                    try self.current.chunk().write_u16(pop_count, stmt.line);
                    self.current.current_locals_count -= pop_count;
                }
                if (stmt.is_expr) for (give_context.end_jumps.items) |jump| try self.patch_jump(jump);
            },

            .if_stmt => |stmt| {
                var give_context: GiveContext = undefined;
                const previous_give = self.current_give;
                if (stmt.is_expr) {
                    give_context = GiveContext.init(self.allocator, self.current.current_locals_count, self.current.defer_scope_depth);
                    self.current_give = &give_context;
                }
                defer self.current_give = previous_give;
                defer if (stmt.is_expr) give_context.deinit();

                try self.generate_expression(stmt.condition);

                if (stmt.capture) |_| {
                    const nil_jump = try self.emit_jump(.OP_JUMP_IF_NIL, stmt.line);
                    const pop_count = self.binding_resolution.scope_pop_counts.get(node) orelse {
                        self.fail("Capture scope has no pop count in binding resolution.", null, stmt.line, stmt.column);
                        return CodeGeneratorError.MissingBinding;
                    };

                    // The condition value is already sitting in the capture's stack slot.
                    self.current.current_locals_count += 1;
                    try self.current.chunk().write_opcode(.OP_DEFER_SCOPE, stmt.line);
                    self.current.defer_scope_depth += 1;
                    try self.generate_node(stmt.then_branch);
                    try self.emit_defer_run(0, stmt.line);
                    self.current.defer_scope_depth -= 1;
                    self.current.current_locals_count -= 1;
                    try self.emit_local_cleanup(stmt.then_branch, pop_count, stmt.line);

                    const end_jump = try self.emit_jump(.OP_JUMP, stmt.line);

                    try self.patch_jump(nil_jump);
                    try self.current.chunk().write_opcode(.OP_POP, stmt.line); // drop nil

                    if (stmt.else_branch) |else_branch| try self.generate_node(else_branch);
                    try self.patch_jump(end_jump);
                } else {
                    const then_jump = try self.emit_jump(.OP_JUMP_IF_FALSE, stmt.line);
                    try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                    try self.generate_node(stmt.then_branch);
                    if (stmt.else_branch) |else_branch| {
                        const else_jump = try self.emit_jump(.OP_JUMP, stmt.line);
                        try self.patch_jump(then_jump);
                        try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                        try self.generate_node(else_branch);
                        try self.patch_jump(else_jump);
                    } else {
                        const end_jump = try self.emit_jump(.OP_JUMP, stmt.line);
                        try self.patch_jump(then_jump);
                        try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                        try self.patch_jump(end_jump);
                    }
                }
                if (stmt.is_expr) for (give_context.end_jumps.items) |jump| try self.patch_jump(jump);
            },

            .while_stmt => |stmt| {
                const loop_start = self.current.chunk().code.items.len;

                var loop_context = LoopContext.init(self.allocator, self.current.current_locals_count, self.current.defer_scope_depth, @intCast(loop_start), self.current_loop);
                defer loop_context.deinit();
                const prev_loop = self.current_loop;
                self.current_loop = &loop_context;
                defer self.current_loop = prev_loop;
                try self.generate_expression(stmt.condition);
                if (stmt.capture) |_| {
                    const exit_jump = try self.emit_jump(.OP_JUMP_IF_NIL, stmt.line);
                    const pop_count = self.binding_resolution.scope_pop_counts.get(node) orelse {
                        self.fail("Capture scope has no pop count in binding resolution.", null, stmt.line, stmt.column);
                        return CodeGeneratorError.MissingBinding;
                    };

                    self.current.current_locals_count += 1; // for the captured value
                    try self.current.chunk().write_opcode(.OP_DEFER_SCOPE, stmt.line);
                    self.current.defer_scope_depth += 1;
                    try self.generate_node(stmt.body);
                    try self.emit_defer_run(0, stmt.line);
                    self.current.defer_scope_depth -= 1;
                    self.current.current_locals_count -= 1;
                    try self.emit_local_cleanup(stmt.body, pop_count, stmt.line);

                    try self.emit_loop(@intCast(loop_start), stmt.line);
                    try self.patch_jump(exit_jump);
                    try self.current.chunk().write_opcode(.OP_POP, stmt.line); // drop nil
                } else {
                    const exit_jump = try self.emit_jump(.OP_JUMP_IF_FALSE, stmt.line);
                    try self.current.chunk().write_opcode(.OP_POP, stmt.line);

                    try self.generate_node(stmt.body);
                    try self.emit_loop(@intCast(loop_start), stmt.line);
                    try self.patch_jump(exit_jump);
                    try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                }
                // patching all break statements
                for (loop_context.break_jumps.items) |break_jump| {
                    try self.patch_jump(break_jump);
                }
            },

            .return_stmt => |stmt| {
                if (stmt.expr) |expr| {
                    try self.generate_expression(expr);
                } else {
                    try self.current.chunk().write_opcode(.OP_NIL, stmt.line);
                }
                try self.emit_defer_runs(self.current.defer_scope_depth, 2, stmt.line);
                try self.current.chunk().write_opcode(.OP_RETURN, stmt.line);
            },

            .for_stmt => |stmt| {
                const binding = self.binding_resolution.declaration_bindings.get(.{ .node = node }) orelse {
                    self.fail("Missing binding for `for` loop iterator.", null, stmt.iterator_name.line, stmt.iterator_name.column);
                    return CodeGeneratorError.MissingBinding;
                };
                const i_slot = binding.slot;

                try self.generate_expression(stmt.iterator_expr);
                self.current.current_locals_count += 1;

                // Reserve local slot for iterator variable
                try self.current.chunk().write_opcode(.OP_NIL, stmt.iterator_name.line);
                self.current.current_locals_count += 1;

                // OP_FOR_PREP with placeholder for exit jump
                try self.current.chunk().write_opcode(.OP_FOR_PREP, stmt.iterator_name.line);
                try self.current.chunk().write_u16(i_slot, stmt.iterator_name.line);
                const exit_jump = try self.emit_jump_placeholder(stmt.iterator_name.line);

                // set up loop context
                const body_start: u32 = @intCast(self.current.chunk().code.items.len);
                var loop_context = LoopContext.init(self.allocator, self.current.current_locals_count, self.current.defer_scope_depth, null, self.current_loop);
                defer loop_context.deinit();

                const prev_loop = self.current_loop;
                self.current_loop = &loop_context;
                defer self.current_loop = prev_loop;

                try self.generate_node(stmt.body);

                const for_next_target: u32 = @intCast(self.current.chunk().code.items.len);

                try self.current.chunk().write_opcode(.OP_FOR_NEXT, stmt.iterator_name.line);
                try self.current.chunk().write_u16(i_slot, stmt.iterator_name.line);
                const loop_offset = self.current.chunk().code.items.len - body_start + 2;
                if (loop_offset > std.math.maxInt(u16)) {
                    self.fail("Loop size exceeds maximum supported offset.", null, stmt.iterator_name.line, stmt.iterator_name.column);
                    return CodeGeneratorError.LoopSizeTooLarge;
                }
                try self.current.chunk().write_u16(@intCast(loop_offset), stmt.iterator_name.line);

                //  patch exit jump if range is empty
                try self.patch_jump(exit_jump);

                // patch continue jumps
                for (loop_context.continue_jumps.items) |cont_jump| {
                    try self.patch_jump_to(cont_jump, for_next_target);
                }

                // patch break jumps
                for (loop_context.break_jumps.items) |break_jump| {
                    try self.patch_jump(break_jump);
                }

                // pop range and iterator variable expressions
                const pop_count = self.binding_resolution.scope_pop_counts.get(node) orelse {
                    self.fail("For-loop scope has no pop count in binding resolution.", null, stmt.iterator_name.line, stmt.iterator_name.column);
                    return CodeGeneratorError.MissingBinding;
                };
                if (pop_count > 0) {
                    try self.current.chunk().write_opcode(.OP_POP_N, stmt.iterator_name.line);
                    try self.current.chunk().write_u16(pop_count, stmt.iterator_name.line);
                    self.current.current_locals_count -= pop_count;
                }
            },

            .give_stmt => |stmt| {
                try self.generate_expression(stmt.expr);
                const give_context = self.current_give orelse return CodeGeneratorError.InvalidPosition;
                const locals_to_pop = self.current.current_locals_count - give_context.local_floor;
                try self.emit_defer_runs(self.current.defer_scope_depth - give_context.defer_scope_floor, 3, stmt.line);
                try self.current.chunk().write_opcode(.OP_GIVE_POP, stmt.line);
                try self.current.chunk().write_u16(locals_to_pop, stmt.line);
                const end_jump = try self.emit_jump(.OP_JUMP, stmt.line);
                try give_context.end_jumps.append(self.allocator, end_jump);
            },

            .defer_stmt => |stmt| try self.generate_defer_statement(stmt),

            .break_stmt => |stmt| {
                const loop_context = self.current_loop orelse {
                    self.fail("`break` statement outside of loop", null, stmt.line, stmt.column);
                    return CodeGeneratorError.UnsupportedNode;
                };

                const locals_to_pop = self.current.current_locals_count - loop_context.scope_local_floor;
                try self.emit_defer_runs(self.current.defer_scope_depth - loop_context.defer_scope_floor, 0, stmt.line);
                if (locals_to_pop > 0) {
                    try self.current.chunk().write_opcode(.OP_POP_N, stmt.line);
                    try self.current.chunk().write_u16(locals_to_pop, stmt.line);
                }

                const jump = try self.emit_jump(.OP_JUMP, stmt.line);
                try loop_context.break_jumps.append(loop_context.allocator, jump);
            },

            .continue_stmt => |stmt| {
                const loop_context = self.current_loop orelse {
                    self.fail("`continue` statement outside of loop", null, stmt.line, stmt.column);
                    return CodeGeneratorError.InvalidPosition;
                };

                const locals_to_pop = self.current.current_locals_count - loop_context.scope_local_floor;
                try self.emit_defer_runs(self.current.defer_scope_depth - loop_context.defer_scope_floor, 0, stmt.line);
                if (locals_to_pop > 0) {
                    try self.current.chunk().write_opcode(.OP_POP_N, stmt.line);
                    try self.current.chunk().write_u16(locals_to_pop, stmt.line);
                }
                if (loop_context.continue_target) |target| { // if this is a while loop
                    try self.emit_loop(target, stmt.line);
                } else { // this is a for loop
                    const jump = try self.emit_jump(.OP_JUMP, stmt.line);
                    try loop_context.continue_jumps.append(loop_context.allocator, jump);
                }
            },
            .panic_stmt => |stmt| {
                try self.generate_expression(stmt.expr);
                try self.current.chunk().write_opcode(.OP_PANIC, stmt.line);
            },

            else => {
                self.fail("Unsupported node type in code generation.", "This node type is not yet implemented for bytecode emission.", 0, 0);
                return CodeGeneratorError.UnsupportedNode;
            },
        }
    }

    fn generate_struct_decl(self: *CodeGenerator, node: *AST.ASTNode, decl: *AST.StructDecl) CodeGeneratorError!void {
        // struct node carries no runtime information
        _ = node;
        for (decl.methods) |method| {
            switch (method.method.*) {
                .fn_decl => try self.generate_callable_decl(method.method, @ptrCast(method.method.fn_decl), AST.FnDecl),
                .co_decl => try self.generate_callable_decl(method.method, @ptrCast(method.method.co_decl), AST.CoDecl),
                else => return CodeGeneratorError.UnsupportedNode,
            }
        }
    }

    fn generate_callable_decl(self: *CodeGenerator, node: *AST.ASTNode, decl: *AST.ASTNode, decl_type: anytype) CodeGeneratorError!void {
        const callable_decl: *decl_type = @ptrCast(decl);

        const binding = self.binding_resolution.function_infos.get(node) orelse {
            self.fail("Function declaration has no binding in binding resolution." ++ INTERNAL_ERROR_MESSAGE, null, callable_decl.line, callable_decl.column);
            return CodeGeneratorError.MissingBinding;
        };

        const function_object = try Entities.new_function_object(self.isolate, self.module.filepath);
        // Start nested function with its own parameter count:
        const new_function = try FunctionCompiler.init(self.allocator, function_object, self.current, binding.param_count);
        defer new_function.deinit();
        const enclosing = self.current;
        const enclosing_give = self.current_give;
        self.current = new_function;
        self.current_give = null;
        defer self.current_give = enclosing_give;

        // Generate body for the inner function
        try self.current.chunk().write_opcode(.OP_DEFER_SCOPE, callable_decl.line);
        self.current.defer_scope_depth += 1;
        try self.generate_node(callable_decl.body);

        try self.emit_defer_run(0, callable_decl.line);
        self.current.defer_scope_depth -= 1;
        try self.current.chunk().write_opcode(.OP_NIL, callable_decl.line);
        try self.current.chunk().write_opcode(.OP_RETURN, callable_decl.line);

        function_object.arity = binding.param_count;
        function_object.name = try Entities.copy_string(self.isolate, callable_decl.name.lexeme);
        function_object.upvalue_count = binding.upvalues.len;

        // Restore enclosing function compiler!
        self.current = enclosing;

        const ref: AST.DeclRef = .{ .node = node };
        const decl_binding = self.binding_resolution.declaration_bindings.get(ref) orelse {
            self.fail("Function declaration has no runtime binding in binding resolution." ++ INTERNAL_ERROR_MESSAGE, null, callable_decl.line, callable_decl.column);
            return CodeGeneratorError.MissingBinding;
        };

        switch (decl_binding.kind) {
            .function_constant => {
                const closure_object = try Entities.new_closure_object(self.isolate, function_object);
                self.isolate.function_constants[decl_binding.slot] = .{ .object = &closure_object.header };
            },
            .local => {
                // Nested function: emit a closure instruction into the enclosing chunk
                const const_index = try self.current.chunk().write_constant(.{ .object = &function_object.header });
                try self.current.chunk().write_opcode(.OP_CLOSURE, callable_decl.line);
                try self.current.chunk().write_u16(const_index, callable_decl.line);
                for (binding.upvalues) |upvalue| {
                    try self.current.chunk().write_u8(if (upvalue.captures_parent_local) 1 else 0, callable_decl.line);
                    try self.current.chunk().write_u16(upvalue.parent_slot, callable_decl.line);
                }
                try self.current.chunk().write_opcode(.OP_STORE_LOCAL, callable_decl.line);
                try self.current.chunk().write_u16(decl_binding.slot, callable_decl.line);

                // Increment enclosing function's local count!
                self.current.current_locals_count += 1;
            },
            else => return CodeGeneratorError.UnsupportedNode,
        }
    }

    fn emit_const_value(self: *CodeGenerator, value: ConstValue, line: usize) CodeGeneratorError!void {
        switch (value) {
            .int => |v| try self.current.chunk().emit_constant(.{ .int = v }, line),
            .float => |v| try self.current.chunk().emit_constant(.{ .float = v }, line),
            .bool => |v| try self.current.chunk().write_opcode(if (v) .OP_TRUE else .OP_FALSE, line),
            .nil => try self.current.chunk().write_opcode(.OP_NIL, line),
            .string => |s| {
                const obj = try Entities.copy_string(self.isolate, s);
                try self.current.chunk().emit_constant(.{ .object = @ptrCast(obj) }, line);
            },
        }
    }

    fn generate_var_decl(self: *CodeGenerator, node: *AST.ASTNode, decl: *AST.VarDecl) CodeGeneratorError!void {
        const ref: AST.DeclRef = .{ .node = node };
        const binding = self.binding_resolution.declaration_bindings.get(ref) orelse {
            self.fail("Variable declaration has no binding in binding resolution." ++ INTERNAL_ERROR_MESSAGE, null, decl.line, decl.column);
            return CodeGeneratorError.MissingBinding;
        };

        // inlined at each use, so the declaration emits nothing
        if (binding.kind == .constant) return;

        try self.generate_expression(decl.initializer);

        switch (binding.kind) {
            .local => {
                // The initializer is already sitting on the stack in the correct
                // slot position
                self.current.current_locals_count += 1;
            },
            .global => {
                try self.current.chunk().write_opcode(.OP_STORE_GLOBAL, decl.line);
                try self.current.chunk().write_u16(binding.slot, decl.line);
                try self.current.chunk().write_opcode(.OP_POP, decl.line);
            },
            else => {
                self.fail("Unsupported variable binding kind for code generation.", null, decl.line, decl.column);
                return CodeGeneratorError.UnsupportedNode;
            },
        }
    }

    fn emit_loop(self: *CodeGenerator, loop_start: u32, line: usize) CodeGeneratorError!void {
        try self.current.chunk().write_opcode(.OP_LOOP, line);
        const offset = self.current.chunk().code.items.len - loop_start + 2; // +2 accounts for size of OP_LOOP
        if (offset > std.math.maxInt(u16)) {
            self.fail("Loop size exceeds maximum supported offset.", "Try reducing the size of the loop body.", line, 0);
            return CodeGeneratorError.LoopSizeTooLarge;
        }
        try self.current.chunk().write_u8(@as(u8, @truncate(offset >> 8)), line);
        try self.current.chunk().write_u8(@as(u8, @truncate(offset)), line);
    }

    /// Emits a jump instruction and placeholdres for the offset
    ///
    /// instruction - the opcode for the jump instruction
    /// returns the index of the jump instruction in the bytecode
    fn emit_jump(self: *CodeGenerator, instruction: Opcode, line: usize) CodeGeneratorError!usize {
        try self.current.chunk().write_opcode(instruction, line);
        try self.current.chunk().write_u8(0xff, line); // placeholder - will be replaced
        try self.current.chunk().write_u8(0xff, line); // placeholder - will be replaced
        return self.current.chunk().code.items.len - 2;
    }

    /// Patches a jump instruction with the calculated offset
    ///
    /// offset is the index of the jump instruction in the bytecode that needs to be patched
    fn patch_jump(self: *CodeGenerator, offset: usize) CodeGeneratorError!void {
        const jump = self.current.chunk().code.items.len - offset - 2;
        if (jump > std.math.maxInt(u16)) {
            self.fail("Jump offset exceeds maximum supported size.", null, 0, 0);
            return CodeGeneratorError.LoopSizeTooLarge;
        }
        self.current.chunk().code.items[offset] = @intCast(jump >> 8);
        self.current.chunk().code.items[offset + 1] = @intCast(jump & 0xff);
    }

    /// Patches a jump instruction to an explicit target offset
    ///
    /// offset is the index of the jump's operand bytes;
    /// target is the bytecode offset to jump to.
    fn patch_jump_to(self: *CodeGenerator, offset: usize, target: u32) CodeGeneratorError!void {
        // `offset` points at the 2-byte operand of the jump. The IP after reading the offset
        // is `offset + 2`, so the forward offset is `target - (offset + 2)`.
        if (target < offset + 2) {
            self.fail("Invalid forward jump target.", null, 0, 0);
            return CodeGeneratorError.LoopSizeTooLarge;
        }
        const jump: usize = @intCast(target - @as(u32, @intCast(offset + 2)));
        if (jump > std.math.maxInt(u16)) {
            self.fail("Jump offset exceeds maximum supported size.", null, 0, 0);
            return CodeGeneratorError.LoopSizeTooLarge;
        }
        self.current.chunk().code.items[offset] = @intCast(jump >> 8);
        self.current.chunk().code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn generate_expression(self: *CodeGenerator, node: *AST.ASTNode) CodeGeneratorError!void {
        switch (node.*) {
            .block_stmt, .if_stmt => try self.generate_node(node),
            .int_lit => |lit| {
                try self.current.chunk().emit_constant(.{ .int = lit.value }, lit.line);
            },
            .float_lit => |lit| try self.current.chunk().emit_constant(.{ .float = lit.value }, lit.line),
            .bool_lit => |lit| try self.current.chunk().write_opcode(if (lit.value) .OP_TRUE else .OP_FALSE, lit.line),
            .nil_lit => |lit| try self.current.chunk().write_opcode(.OP_NIL, lit.line),
            .str_lit => |lit| {
                const string_object = try Entities.copy_string(self.isolate, lit.value);
                try self.current.chunk().emit_constant(.{ .object = @ptrCast(string_object) }, lit.line);
            },
            .array_expr => |arr| {
                for (arr.elements) |element| {
                    try self.generate_expression(element);
                }
                try self.current.chunk().write_opcode(.OP_ARRAY, arr.line);
                try self.current.chunk().write_u16(@intCast(arr.elements.len), arr.line);
            },
            .tuple_expr => |tup| {
                for (tup.exprs) |element| {
                    try self.generate_expression(element);
                }
                try self.current.chunk().write_opcode(.OP_TUPLE, tup.line);
                try self.current.chunk().write_u16(@intCast(tup.exprs.len), tup.line);
            },
            .table_expr => |expr| {
                for (expr.keys) |key| {
                    try self.generate_expression(key);
                }
                for (expr.values) |value| {
                    try self.generate_expression(value);
                }
                try self.current.chunk().write_opcode(.OP_TABLE, expr.line);
                try self.current.chunk().write_u16(@intCast(expr.keys.len), expr.line);
            },
            .group_expr => |expr| try self.generate_expression(expr.expr),
            .unary_expr => |expr| try self.generate_unary_expression(expr),
            .binary_expr => |expr| try self.generate_binary_expr(expr),
            .resume_expr => |expr| try self.generate_resume_expression(expr),
            .yield_expr => |expr| {
                try self.generate_expression(expr.expr);
                // Pops the yielded value; the next `resume co with V` pushes the
                // yield expression's value back onto the coroutine's stack.
                try self.current.chunk().write_opcode(.OP_YIELD, expr.line);
            },
            .identifier_expr => |expr| try self.generate_identifier_expr(node, expr),
            .assign_expr => |expr| try self.generate_assignment_expression(expr),
            .call_expr => |expr| {
                if (expr.expr.* == .dot_expr) {
                    if (self.binding_resolution.member_infos.get(expr.expr)) |member| {
                        if (member == .enum_variant and member.enum_variant.payload_type != null) {
                            if (expr.args.len != 1) return CodeGeneratorError.UnsupportedNode;
                            try self.generate_expression(expr.args[0]);
                            try self.current.chunk().write_opcode(.OP_NEW_ENUM, expr.line);
                            try self.current.chunk().write_u32(member.enum_variant.type_id, expr.line);
                            try self.current.chunk().write_u32(@intCast(member.enum_variant.index), expr.line);
                            try self.current.chunk().write_u16(1, expr.line);
                            return;
                        }
                    }
                }
                if (expr.expr.* == .dot_expr) {
                    const dot = expr.expr.dot_expr;
                    if (self.registry.get_type_info(resolve_typeof(dot.expr)) == .coroutine and
                        (std.mem.eql(u8, dot.member.lexeme, "returned") or std.mem.eql(u8, dot.member.lexeme, "is_finished")))
                    {
                        const native_name = if (std.mem.eql(u8, dot.member.lexeme, "returned")) "coroutine_returned" else "coroutine_is_finished";
                        const native_slot = Natives.find(native_name) orelse return CodeGeneratorError.MissingBinding;
                        try self.generate_expression(dot.expr);
                        try self.current.chunk().write_opcode(.OP_CALL_NATIVE, expr.line);
                        try self.current.chunk().write_u16(1, expr.line);
                        try self.current.chunk().write_u16(native_slot, expr.line);
                        return;
                    }
                }
                // instance method call
                if (expr.expr.* == .dot_expr) {
                    if (self.binding_resolution.member_infos.get(expr.expr)) |member_info| {
                        if (member_info == .method) {
                            const method_slot = member_info.method.index;
                            const takes_receiver = member_info.method.takes_receiver;
                            const dot = expr.expr.dot_expr;

                            if (member_info.method.is_native) {
                                if (takes_receiver) try self.generate_expression(dot.expr);
                                for (expr.args) |arg| try self.generate_expression(arg);
                                try self.current.chunk().write_opcode(.OP_CALL_NATIVE, expr.line);
                                const arg_count = expr.args.len + @as(usize, if (takes_receiver) 1 else 0);
                                try self.current.chunk().write_u16(@intCast(arg_count), expr.line);
                                try self.current.chunk().write_u16(method_slot, expr.line);
                                return;
                            }

                            try self.current.chunk().write_opcode(.OP_LOAD_FUNCTION_CONSTANT, expr.line);
                            try self.current.chunk().write_u16(method_slot, expr.line);

                            if (takes_receiver) try self.generate_expression(dot.expr);

                            for (expr.args) |arg| {
                                try self.generate_expression(arg);
                            }

                            const indexed_type = resolve_typeof(expr.expr);
                            const opcode: Opcode = switch (self.registry.get_type_info(indexed_type)) {
                                .function => .OP_CALL,
                                .coroutine => .OP_COROUTINE,
                                else => return CodeGeneratorError.UnsupportedOperandType,
                            };

                            // Include the receiver only for instance methods.
                            try self.current.chunk().write_opcode(opcode, expr.line);
                            try self.current.chunk().write_u16(@intCast(expr.args.len + @as(usize, if (takes_receiver) 1 else 0)), expr.line);
                            return;
                        }
                    }
                }

                const indexed_type = resolve_typeof(expr.expr);
                const type_info = self.registry.get_type_info(indexed_type);

                const native_binding = if (expr.expr.* == .identifier_expr)
                    self.binding_resolution.identifier_bindings.get(expr.expr)
                else
                    null;

                if (native_binding != null and native_binding.?.kind == .native) {
                    for (expr.args) |arg| {
                        try self.generate_expression(arg);
                    }
                    try self.current.chunk().write_opcode(.OP_CALL_NATIVE, expr.line);
                    try self.current.chunk().write_u16(@intCast(expr.args.len), expr.line);
                    try self.current.chunk().write_u16(native_binding.?.slot, expr.line);
                } else {
                    // Regular function call

                    try self.generate_expression(expr.expr); // the closure
                    for (expr.args) |arg| {
                        try self.generate_expression(arg);
                    }

                    const opcode: Opcode = switch (type_info) {
                        .function => .OP_CALL,
                        .coroutine => .OP_COROUTINE,
                        else => return CodeGeneratorError.UnsupportedOperandType,
                    };

                    try self.current.chunk().write_opcode(opcode, expr.line);
                    try self.current.chunk().write_u16(@intCast(expr.args.len), expr.line);
                }
            },
            .index_expr => |expr| {
                try self.generate_expression(expr.expr);
                try self.generate_expression(expr.index);

                const indexed_type = resolve_typeof(expr.expr);
                const opcode: Opcode = if (self.registry.array_element(indexed_type) != null)
                    .OP_INDEX_ARRAY
                else if (self.registry.table_pair(indexed_type) != null)
                    .OP_INDEX_TABLE
                else if (TypeRegistryImpl.is_string(indexed_type))
                    .OP_INDEX_STRING
                else
                    return CodeGeneratorError.UnsupportedOperandType;
                try self.current.chunk().write_opcode(opcode, expr.line);
            },
            .dot_expr => |expr| {
                const member_info = self.binding_resolution.member_infos.get(node) orelse return CodeGeneratorError.MissingBinding;
                switch (member_info) {
                    .tuple_index => |tuple_index| {
                        try self.generate_expression(expr.expr);
                        try self.current.chunk().write_opcode(.OP_INDEX_TUPLE, expr.line);
                        try self.current.chunk().write_u16(tuple_index.index, expr.line);
                    },
                    .field => |field_index| {
                        try self.generate_expression(expr.expr);
                        try self.current.chunk().write_opcode(.OP_GET_FIELD, expr.line);
                        try self.current.chunk().write_u16(field_index.index, expr.line);
                    },
                    .enum_variant => |variant| {
                        if (variant.has_payloads) {
                            try self.current.chunk().write_opcode(.OP_NEW_ENUM, expr.line);
                            try self.current.chunk().write_u32(variant.type_id, expr.line);
                            try self.current.chunk().write_u32(@intCast(variant.index), expr.line);
                            try self.current.chunk().write_u16(0, expr.line);
                        } else {
                            try self.current.chunk().emit_constant(.{ .enum_ = .{ .type_id = variant.type_id, .index = @intCast(variant.index) } }, expr.line);
                        }
                    },
                    .error_variant => |variant| {
                        try self.current.chunk().emit_constant(.{ .error_ = .{ .type_id = variant.type_id, .index = @intCast(variant.index) } }, expr.line);
                    },
                    else => return CodeGeneratorError.UnsupportedNode,
                }
            },
            .optional_unwrap_expr => |expr| {
                try self.generate_expression(expr.expr);
                try self.current.chunk().write_opcode(.OP_OPTIONAL_UNWRAP, expr.line);
            },

            .new_expr => |expr| {
                const member_info = self.binding_resolution.member_infos.get(node) orelse return CodeGeneratorError.MissingBinding;
                const struct_init = member_info.struct_init;
                const type_info = self.registry.get_type_info(struct_init.type_id)._struct;

                for (type_info.fields) |field| {
                    var provided_expr: ?*AST.ASTNode = null;
                    for (expr.fields) |f| {
                        if (std.mem.eql(u8, f.name.lexeme, field.name)) {
                            provided_expr = f.value;
                            break;
                        }
                    }

                    if (provided_expr) |val| {
                        try self.generate_expression(val);
                    } else if (field.default_value) |def| {
                        try self.generate_expression(def);
                    }
                }

                var instance_field_count: u16 = 0;
                for (type_info.fields) |f| {
                    _ = f;
                    instance_field_count += 1;
                }

                try self.current.chunk().write_opcode(.OP_STRUCT, expr.line);
                try self.current.chunk().write_u32(struct_init.type_id, expr.line);
                try self.current.chunk().write_u16(instance_field_count, expr.line);
            },

            .anon_struct_instance => |expr| {
                const member = self.binding_resolution.member_infos.get(node) orelse return CodeGeneratorError.MissingBinding;
                const struct_init = member.struct_init;
                const type_info = self.registry.get_type_info(struct_init.type_id)._struct;
                for (type_info.fields) |field| {
                    for (expr.fields) |provided| {
                        if (std.mem.eql(u8, field.name, provided.name.lexeme)) {
                            try self.generate_expression(provided.value);
                            break;
                        }
                    }
                }
                try self.current.chunk().write_opcode(.OP_STRUCT, expr.line);
                try self.current.chunk().write_u32(struct_init.type_id, expr.line);
                try self.current.chunk().write_u16(@intCast(type_info.fields.len), expr.line);
            },

            .match_expr => |expr| {
                var give_context = GiveContext.init(self.allocator, self.current.current_locals_count, self.current.defer_scope_depth);
                const previous_give = self.current_give;
                self.current_give = &give_context;
                defer self.current_give = previous_give;
                defer give_context.deinit();
                try self.generate_expression(expr.expr);
                const hidden_binding = self.binding_resolution.declaration_bindings.get(.{ .node = node }) orelse return CodeGeneratorError.MissingBinding;
                self.current.current_locals_count += 1;

                var end_jumps: std.ArrayList(usize) = .empty;
                defer end_jumps.deinit(self.allocator);
                var has_default = false;
                const matched_info = self.registry.get_type_info(resolve_typeof(expr.expr));
                const is_enum = matched_info == ._enum;
                const enum_has_payloads = if (is_enum) matched_info._enum.has_payloads else false;

                for (expr.cases) |case| {
                    if (case.pattern.* == .default_pat) {
                        has_default = true;
                        try self.generate_node(case.stmt);
                        const arm_pop = self.binding_resolution.match_case_pop_counts.get(case) orelse return CodeGeneratorError.MissingBinding;
                        if (arm_pop > 0) {
                            try self.current.chunk().write_opcode(.OP_POP_N, case.line);
                            try self.current.chunk().write_u16(arm_pop, case.line);
                            self.current.current_locals_count -= arm_pop;
                        }
                        try self.current.chunk().write_opcode(.OP_POP_N, case.line);
                        try self.current.chunk().write_u16(1, case.line);
                        self.current.current_locals_count -= 1;
                        try self.current.chunk().write_opcode(.OP_NIL, case.line);
                        const jump_to_end = try self.emit_jump(.OP_JUMP, case.line);
                        try end_jumps.append(self.allocator, jump_to_end);
                        self.current.current_locals_count += 1;
                        continue;
                    }

                    try self.current.chunk().write_opcode(.OP_LOAD_LOCAL, case.line);
                    try self.current.chunk().write_u16(hidden_binding.slot, case.line);
                    if (is_enum and case.enum_tag != null) {
                        try self.current.chunk().write_opcode(if (enum_has_payloads) .OP_ENUM_TAG else .OP_ENUM_UNIT_TAG, case.line);
                        try self.current.chunk().emit_constant(.{ .int = case.enum_tag.? }, case.line);
                    } else {
                        try self.generate_expression(case.pattern);
                    }
                    try self.current.chunk().write_opcode(.OP_EQUAL, case.line);
                    const mismatch_jump = try self.emit_jump(.OP_JUMP_IF_FALSE, case.line);
                    try self.current.chunk().write_opcode(.OP_POP, case.line);
                    if (case.payload_binding) |capture| {
                        try self.current.chunk().write_opcode(.OP_LOAD_LOCAL, case.line);
                        try self.current.chunk().write_u16(hidden_binding.slot, case.line);
                        try self.current.chunk().write_opcode(.OP_ENUM_FIELD, case.line);
                        try self.current.chunk().write_u16(0, case.line);
                        const capture_binding = self.binding_resolution.declaration_bindings.get(.{ .capture = capture }) orelse return CodeGeneratorError.MissingBinding;
                        if (capture_binding.slot != self.current.current_locals_count) return CodeGeneratorError.MissingBinding;
                        self.current.current_locals_count += 1;
                    }
                    try self.generate_node(case.stmt);
                    const arm_pop = self.binding_resolution.match_case_pop_counts.get(case) orelse return CodeGeneratorError.MissingBinding;
                    if (arm_pop > 0) {
                        try self.current.chunk().write_opcode(.OP_POP_N, case.line);
                        try self.current.chunk().write_u16(arm_pop, case.line);
                        self.current.current_locals_count -= arm_pop;
                    }
                    try self.current.chunk().write_opcode(.OP_POP_N, case.line);
                    try self.current.chunk().write_u16(1, case.line);
                    self.current.current_locals_count -= 1;
                    try self.current.chunk().write_opcode(.OP_NIL, case.line);
                    const jump_to_end = try self.emit_jump(.OP_JUMP, case.line);
                    try end_jumps.append(self.allocator, jump_to_end);
                    try self.patch_jump(mismatch_jump);
                    try self.current.chunk().write_opcode(.OP_POP, case.line);
                    self.current.current_locals_count += 1;
                }

                if (!has_default) {
                    try self.current.chunk().write_opcode(.OP_POP_N, expr.line);
                    try self.current.chunk().write_u16(1, expr.line);
                    self.current.current_locals_count -= 1;
                    try self.current.chunk().write_opcode(.OP_NIL, expr.line);
                }

                for (end_jumps.items) |end_jump| {
                    try self.patch_jump(end_jump);
                }
                for (give_context.end_jumps.items) |jump| try self.patch_jump(jump);
                self.current.current_locals_count = hidden_binding.slot;
            },

            .try_expr => |expr| {
                try self.generate_expression(expr.expr);

                const err_jump = try self.emit_jump(.OP_JUMP_IF_ERROR, expr.line);
                const success_jump = try self.emit_jump(.OP_JUMP, expr.line);

                // early return
                try self.patch_jump(err_jump);
                try self.emit_defer_runs(self.current.defer_scope_depth, 1, expr.line);
                try self.current.chunk().write_opcode(.OP_RETURN, expr.line);

                // non error success case
                try self.patch_jump(success_jump);
            },

            .anon_fn_expr => |expr| {
                try self.generate_anonymous_callable(node, expr.params, expr.body, expr.line);
            },

            .anon_co_expr => |expr| {
                try self.generate_anonymous_callable(node, expr.params, expr.body, expr.line);
            },

            else => {
                self.fail("Unsupported expression type in code generation.", "This expression type is not yet implemented.", 0, 0);
                return CodeGeneratorError.UnsupportedNode;
            },
        }
    }

    fn generate_assignment_expression(self: *CodeGenerator, expr: *AST.AssignExpr) CodeGeneratorError!void {
        const op = expr.operator.lexeme;

        if (expr.left.* == .index_expr) {
            const index = expr.left.index_expr;
            const indexed_type = resolve_typeof(index.expr);
            const setter: Opcode = if (self.registry.array_element(indexed_type) != null)
                .OP_SET_INDEX_ARRAY
            else if (self.registry.table_pair(indexed_type) != null)
                .OP_SET_INDEX_TABLE
            else
                return CodeGeneratorError.UnsupportedNode;

            try self.generate_expression(index.expr);
            try self.generate_expression(index.index);

            if (std.mem.eql(u8, op, "=")) {
                try self.generate_expression(expr.right);
            } else {
                // Preserve the evaluated collection and index. Re-evaluating an
                // index target would duplicate user-visible side effects.
                try self.current.chunk().write_opcode(.OP_DUP_TWO, expr.line);
                const getter: Opcode = switch (setter) {
                    .OP_SET_INDEX_ARRAY => .OP_INDEX_ARRAY,
                    .OP_SET_INDEX_TABLE => .OP_INDEX_TABLE,
                    else => unreachable,
                };
                try self.current.chunk().write_opcode(getter, expr.line);
                try self.generate_expression(expr.right);
                const base_op = op[0 .. op.len - 1];
                const opcode = try CodeGenerator.select_opcode(base_op, resolve_typeof(expr.left), resolve_typeof(expr.right));
                try self.current.chunk().write_opcode(opcode, expr.line);
            }

            try self.current.chunk().write_opcode(setter, expr.line);
            return;
        }

        // assigning a struct member
        if (expr.left.* == .dot_expr) {
            const dot = expr.left.dot_expr;
            const member_info = self.binding_resolution.member_infos.get(expr.left) orelse return CodeGeneratorError.MissingBinding;
            if (member_info != .field) return CodeGeneratorError.UnsupportedNode;
            const field_index = member_info.field.index;

            if (std.mem.eql(u8, op, "=")) {
                try self.generate_expression(dot.expr); // target
                try self.generate_expression(expr.right); // value
            } else {
                // compound assignment
                // Push target struct instance
                try self.generate_expression(dot.expr);

                try self.current.chunk().write_opcode(.OP_DUP, expr.line); // Duplicate struct instance so one remains for storing
                try self.current.chunk().write_opcode(.OP_GET_FIELD, expr.line);
                try self.current.chunk().write_u16(field_index, expr.line);
                try self.generate_expression(expr.right);

                const base_op = op[0 .. op.len - 1];
                const left_kind = resolve_typeof(expr.left);
                const right_kind = resolve_typeof(expr.right);
                const opcode = try CodeGenerator.select_opcode(base_op, left_kind, right_kind);
                try self.current.chunk().write_opcode(opcode, expr.line);
            }

            try self.current.chunk().write_opcode(.OP_SET_FIELD, expr.line);
            try self.current.chunk().write_u16(field_index, expr.line);
            return;
        }

        // local / global / upvalue
        const identifier = switch (expr.left.*) {
            .identifier_expr => |ie| ie,
            else => return CodeGeneratorError.UnsupportedNode,
        };

        const binding = self.binding_resolution.identifier_bindings.get(expr.left) orelse return CodeGeneratorError.MissingBinding;

        if (std.mem.eql(u8, op, "=")) {
            try self.generate_expression(expr.right);
        } else {
            // compound assignment becomes: x = x <op> right
            try self.generate_identifier_expr(expr.left, identifier); // pushes current value
            try self.generate_expression(expr.right);

            const base_op = op[0 .. op.len - 1]; // "+=" -> "+" ...
            const left_kind = resolve_typeof(expr.left);
            const right_kind = resolve_typeof(expr.right);
            const opcode = try CodeGenerator.select_opcode(base_op, left_kind, right_kind);
            try self.current.chunk().write_opcode(opcode, expr.line);
        }

        switch (binding.kind) {
            .global => {
                try self.current.chunk().write_opcode(.OP_STORE_GLOBAL, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            .local, .param => {
                try self.current.chunk().write_opcode(.OP_STORE_LOCAL, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            .upvalue => {
                try self.current.chunk().write_opcode(.OP_STORE_UPVALUE, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            else => return CodeGeneratorError.UnsupportedNode,
        }
    }

    fn generate_identifier_expr(self: *CodeGenerator, node: *AST.ASTNode, expr: *AST.IdentifierExpr) CodeGeneratorError!void {
        const binding = self.binding_resolution.identifier_bindings.get(node) orelse {
            self.fail("Identifier expression has no binding in binding resolution.", null, expr.line, expr.column);
            return CodeGeneratorError.MissingBinding;
        };
        switch (binding.kind) {
            .constant => {
                const value = binding.const_value orelse {
                    self.fail("Constant binding has no value." ++ INTERNAL_ERROR_MESSAGE, null, expr.line, expr.column);
                    return CodeGeneratorError.MissingBinding;
                };
                try self.emit_const_value(value, expr.line);
            },
            .global => {
                try self.current.chunk().write_opcode(.OP_LOAD_GLOBAL, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            .local, .param => {
                try self.current.chunk().write_opcode(.OP_LOAD_LOCAL, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            .function_constant => {
                try self.current.chunk().write_opcode(.OP_LOAD_FUNCTION_CONSTANT, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            .upvalue => {
                try self.current.chunk().write_opcode(.OP_LOAD_UPVALUE, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },

            else => {
                self.fail("Unsupported identifier binding kind for code generation.", null, expr.line, expr.column);
                return CodeGeneratorError.UnsupportedNode;
            }, // method, comptime_type,
        }
    }

    fn generate_resume_expression(self: *CodeGenerator, expr: *AST.ResumeExpr) CodeGeneratorError!void {
        try self.generate_expression(expr.expr); // should be a call expression
        if (expr.arg) |arg| {
            try self.generate_expression(arg);
        } else {
            try self.current.chunk().write_opcode(.OP_NIL, expr.line);
        }
        try self.current.chunk().write_opcode(.OP_RESUME, expr.line);
    }

    fn generate_unary_expression(self: *CodeGenerator, expr: *AST.UnaryExpr) CodeGeneratorError!void {
        try self.generate_expression(expr.expr);
        var opcode: ?Opcode = null;

        switch (expr.resolved_type) {
            @backingInt(TypeRegistry.PrimitiveType.Bool) => {
                if (std.mem.eql(u8, expr.operator.lexeme, "not")) {
                    opcode = .OP_LOGICAL_NOT;
                }
            },
            @backingInt(TypeRegistry.PrimitiveType.Int) => {
                if (std.mem.eql(u8, expr.operator.lexeme, "-")) {
                    opcode = .OP_NEGATE_INT;
                } else if (std.mem.eql(u8, expr.operator.lexeme, "~")) {
                    opcode = .OP_BITWISE_NOT;
                }
            },
            @backingInt(TypeRegistry.PrimitiveType.Float) => {
                if (std.mem.eql(u8, expr.operator.lexeme, "-")) {
                    opcode = .OP_NEGATE_FLOAT;
                }
            },
            else => unreachable,
        }

        if (opcode) |code| try self.current.chunk().write_opcode(code, expr.line) else {
            self.fail("Unsupported operand type for unary operator.", null, expr.line, expr.column);
            return CodeGeneratorError.UnsupportedOperandType;
        }
    }

    fn and_(self: *CodeGenerator, line: usize, right: *AST.ASTNode) CodeGeneratorError!void {
        const end_jump = try self.emit_jump(.OP_JUMP_IF_FALSE, line);
        try self.current.chunk().write_opcode(.OP_POP, line);
        try self.generate_expression(right);
        try self.patch_jump(end_jump);
    }

    fn or_(self: *CodeGenerator, line: usize, right: *AST.ASTNode) CodeGeneratorError!void {
        const else_jump = try self.emit_jump(.OP_JUMP_IF_FALSE, line);
        const end_jump = try self.emit_jump(.OP_JUMP, line);

        try self.patch_jump(else_jump);
        try self.current.chunk().write_opcode(.OP_POP, line);
        try self.generate_expression(right);
        try self.patch_jump(end_jump);
    }

    fn orelse_(self: *CodeGenerator, line: usize, right: *AST.ASTNode) CodeGeneratorError!void {
        const else_jump = try self.emit_jump(.OP_JUMP_IF_NIL, line);
        const end_jump = try self.emit_jump(.OP_JUMP, line);

        try self.patch_jump(else_jump);
        try self.current.chunk().write_opcode(.OP_POP, line);
        try self.generate_expression(right);
        try self.patch_jump(end_jump);
    }

    fn catch_(self: *CodeGenerator, line: usize, right: *AST.ASTNode) CodeGeneratorError!void {
        const else_jump = try self.emit_jump(.OP_JUMP_IF_ERROR, line);
        const end_jump = try self.emit_jump(.OP_JUMP, line);

        try self.patch_jump(else_jump);
        try self.current.chunk().write_opcode(.OP_POP, line);
        try self.generate_expression(right);
        try self.patch_jump(end_jump);
    }

    fn emit_defer_run(self: *CodeGenerator, mode: u8, line: usize) CodeGeneratorError!void {
        try self.current.chunk().write_opcode(.OP_DEFER_RUN, line);
        try self.current.chunk().write_u8(mode, line);
    }

    fn emit_defer_runs(self: *CodeGenerator, count: u16, mode: u8, line: usize) CodeGeneratorError!void {
        for (0..count) |_| try self.emit_defer_run(mode, line);
    }

    fn generate_defer_statement(self: *CodeGenerator, stmt: *AST.DeferStmt) CodeGeneratorError!void {
        try self.current.chunk().write_opcode(.OP_DEFER_PUSH, stmt.line);
        const target_operand = self.current.chunk().code.items.len;
        try self.current.chunk().write_u32(0, stmt.line);
        try self.current.chunk().write_u8(if (stmt.is_errdefer) 1 else 0, stmt.line);
        const skip_body = try self.emit_jump(.OP_JUMP, stmt.line);

        const target: u32 = @intCast(self.current.chunk().code.items.len);
        self.current.chunk().code.items[target_operand] = @truncate(target >> 24);
        self.current.chunk().code.items[target_operand + 1] = @truncate(target >> 16);
        self.current.chunk().code.items[target_operand + 2] = @truncate(target >> 8);
        self.current.chunk().code.items[target_operand + 3] = @truncate(target);
        try self.generate_node(stmt.body);
        try self.current.chunk().write_opcode(.OP_DEFER_END, stmt.line);
        try self.patch_jump(skip_body);
    }

    fn emit_jump_placeholder(self: *CodeGenerator, line: usize) CodeGeneratorError!usize {
        try self.current.chunk().write_u8(0xff, line);
        try self.current.chunk().write_u8(0xff, line);
        return self.current.chunk().code.items.len - 2;
    }

    fn generate_binary_expr(self: *CodeGenerator, expr: *AST.BinaryExpr) CodeGeneratorError!void {
        const op = expr.operator.lexeme;

        try self.generate_expression(expr.left);

        if (std.mem.eql(u8, op, "and")) {
            return try self.and_(expr.line, expr.right);
        } else if (std.mem.eql(u8, op, "or")) {
            return try self.or_(expr.line, expr.right);
        } else if (std.mem.eql(u8, op, "orelse")) {
            return try self.orelse_(expr.line, expr.right);
        } else if (std.mem.eql(u8, op, "catch")) {
            return try self.catch_(expr.line, expr.right);
        }

        try self.generate_expression(expr.right);

        const left_kind = resolve_typeof(expr.left);
        const right_kind = resolve_typeof(expr.right);

        const opcode = CodeGenerator.select_opcode(op, left_kind, right_kind) catch {
            self.fail("Unsupported operator in code generation.", null, expr.line, expr.column);
            return CodeGeneratorError.UnsupportedOperator;
        };
        try self.current.chunk().write_opcode(opcode, expr.line);
    }

    fn select_opcode(op: []const u8, left: TypeRegistry.TypeId, right: TypeRegistry.TypeId) CodeGeneratorError!Opcode {
        if (std.mem.eql(u8, op, "+")) return arith(left, right, .OP_ADD_INT, .OP_ADD_FLOAT, .OP_ADD_INT_FLOAT, .OP_ADD_FLOAT_INT);
        if (std.mem.eql(u8, op, "-")) return arith(left, right, .OP_SUB_INT, .OP_SUB_FLOAT, .OP_SUB_INT_FLOAT, .OP_SUB_FLOAT_INT);
        if (std.mem.eql(u8, op, "*")) return arith(left, right, .OP_MUL_INT, .OP_MUL_FLOAT, .OP_MUL_INT_FLOAT, .OP_MUL_FLOAT_INT);
        if (std.mem.eql(u8, op, "/")) return arith(left, right, .OP_DIV_INT, .OP_DIV_FLOAT, .OP_DIV_INT_FLOAT, .OP_DIV_FLOAT_INT);
        if (std.mem.eql(u8, op, "**")) return arith(left, right, .OP_EXPONENT_INT, .OP_EXPONENT_FLOAT, .OP_EXPONENT_INT_FLOAT, .OP_EXPONENT_FLOAT_INT);
        if (std.mem.eql(u8, op, "%")) return arith(left, right, .OP_MOD_INT, .OP_MOD_FLOAT, .OP_MOD_INT_FLOAT, .OP_MOD_FLOAT_INT);

        if (std.mem.eql(u8, op, "==")) return .OP_EQUAL;
        if (std.mem.eql(u8, op, "!=")) return .OP_NOT_EQUAL;

        if (std.mem.eql(u8, op, ">")) return arith(left, right, .OP_GREATER_INT, .OP_GREATER_FLOAT, .OP_GREATER_INT_FLOAT, .OP_GREATER_FLOAT_INT);
        if (std.mem.eql(u8, op, "<")) return arith(left, right, .OP_LESS_INT, .OP_LESS_FLOAT, .OP_LESS_INT_FLOAT, .OP_LESS_FLOAT_INT);
        if (std.mem.eql(u8, op, ">=")) return arith(left, right, .OP_GREATER_EQUAL_INT, .OP_GREATER_EQUAL_FLOAT, .OP_GREATER_EQUAL_INT_FLOAT, .OP_GREATER_EQUAL_FLOAT_INT);
        if (std.mem.eql(u8, op, "<=")) return arith(left, right, .OP_LESS_EQUAL_INT, .OP_LESS_EQUAL_FLOAT, .OP_LESS_EQUAL_INT_FLOAT, .OP_LESS_EQUAL_FLOAT_INT);

        if (left == @backingInt(TypeRegistry.PrimitiveType.Int) and right == @backingInt(TypeRegistry.PrimitiveType.Int)) {
            if (std.mem.eql(u8, op, "<<")) return .OP_LEFT_SHIFT;
            if (std.mem.eql(u8, op, ">>")) return .OP_RIGHT_SHIFT;
            if (std.mem.eql(u8, op, "|")) return .OP_BITWISE_OR;
            if (std.mem.eql(u8, op, "&")) return .OP_BITWISE_AND;
            if (std.mem.eql(u8, op, "^")) return .OP_BITWISE_XOR;
        }

        if (TypeRegistryImpl.is_string(left) and TypeRegistryImpl.is_string(right)) {
            if (std.mem.eql(u8, op, "++")) return .OP_STRING_CONCAT;
        }

        if (left == @backingInt(TypeRegistry.PrimitiveType.Int) and right == @backingInt(TypeRegistry.PrimitiveType.Int)) {
            if (std.mem.eql(u8, op, "..")) return .OP_RANGE;
        }

        return CodeGeneratorError.UnsupportedOperator;
    }

    fn arith(
        left: TypeRegistry.TypeId,
        right: TypeRegistry.TypeId,
        int_op: Opcode,
        float_op: Opcode,
        int_float_op: Opcode,
        float_int_op: Opcode,
    ) Opcode {
        return switch (left) {
            @backingInt(TypeRegistry.PrimitiveType.Int) => switch (right) {
                @backingInt(TypeRegistry.PrimitiveType.Int) => int_op,
                @backingInt(TypeRegistry.PrimitiveType.Float) => int_float_op,
                else => unreachable,
            },
            @backingInt(TypeRegistry.PrimitiveType.Float) => switch (right) {
                @backingInt(TypeRegistry.PrimitiveType.Int) => float_int_op,
                @backingInt(TypeRegistry.PrimitiveType.Float) => float_op,
                else => unreachable,
            },
            else => unreachable,
        };
    }

    fn generate_anonymous_callable(
        self: *CodeGenerator,
        node: *AST.ASTNode,
        params: []*AST.TypedNamedField,
        body: *AST.ASTNode,
        line: usize,
    ) CodeGeneratorError!void {
        const binding = self.binding_resolution.function_infos.get(node) orelse {
            self.fail("Anonymous function has no binding info.", null, line, 0);
            return CodeGeneratorError.MissingBinding;
        };

        const function_object = try Entities.new_function_object(self.isolate, self.module.filepath);
        const new_function = try FunctionCompiler.init(self.allocator, function_object, self.current, binding.param_count);
        defer new_function.deinit();
        const enclosing = self.current;
        const enclosing_give = self.current_give;
        self.current = new_function;
        self.current_give = null;
        defer self.current_give = enclosing_give;

        try self.current.chunk().write_opcode(.OP_DEFER_SCOPE, line);
        self.current.defer_scope_depth += 1;
        try self.generate_node(body);

        // implicit return
        try self.emit_defer_run(0, line);
        self.current.defer_scope_depth -= 1;
        try self.current.chunk().write_opcode(.OP_NIL, line);
        try self.current.chunk().write_opcode(.OP_RETURN, line);

        function_object.arity = @intCast(params.len);
        function_object.name = null; // no name for anonymous function
        function_object.upvalue_count = binding.upvalues.len;

        // Restore enclosing function
        self.current = enclosing;

        // emit closure as the expression result
        const const_index = try self.current.chunk().write_constant(.{ .object = &function_object.header });
        try self.current.chunk().write_opcode(.OP_CLOSURE, line);
        try self.current.chunk().write_u16(const_index, line);

        for (binding.upvalues) |upvalue| {
            try self.current.chunk().write_u8(if (upvalue.captures_parent_local) 1 else 0, line);
            try self.current.chunk().write_u16(upvalue.parent_slot, line);
        }
    }

    fn emit_local_cleanup(self: *CodeGenerator, body: *AST.ASTNode, count: u16, line: usize) CodeGeneratorError!void {
        _ = body;
        try self.current.chunk().write_opcode(.OP_POP_N, line);
        try self.current.chunk().write_u16(count, line);
    }
};
