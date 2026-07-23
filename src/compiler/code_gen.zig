//! Code generation for the TAPE compiler.
//! Because the contents of the chunk are vulnerable to garbage collection, all allocations should be guarded with stack push/pops
//! NOTE: This file is mostly AI Generated. I will remove this comment when I am comfortable to take ownership of this file's contents

const std = @import("std");
const Entities = @import("../runtime/entities.zig");
const BindingResolver = @import("binding_resolver.zig");
const Runtime = @import("../runtime/vm.zig");
const AST = @import("ast.zig");
const TypeRegistry = @import("type_registry.zig");
const Chunk = @import("../runtime/chunk.zig").Chunk;
const Opcode = @import("../runtime/chunk.zig").Opcode;

pub const CodeGeneratorError = error{ MissingBinding, UnsupportedNode, UnsupportedOperator, UnsupportedOperandType, LoopSizeTooLarge } || std.mem.Allocator.Error;

pub const FunctionCompiler = struct {
    allocator: std.mem.Allocator,
    /// The function we are emitting code into
    function: *Entities.ObjectFunction,
    /// The enclosing function
    enclosing: ?*FunctionCompiler,

    pub fn init(allocator: std.mem.Allocator, function: *Entities.ObjectFunction, enclosing: ?*FunctionCompiler) !*FunctionCompiler {
        const compiler = try allocator.create(FunctionCompiler);
        compiler.* = .{
            .allocator = allocator,
            .function = function,
            .enclosing = enclosing,
        };
        return compiler;
    }

    pub fn chunk(self: *FunctionCompiler) *Chunk {
        return &self.function.chunk;
    }
};

pub const CodeGenerator = struct {
    /// base allocator - not for runtime managed entities
    allocator: std.mem.Allocator,
    /// The isolate to allocate runtime managed entities
    isolate: *Runtime.Isolate,
    /// The binding resolution for the module currently being compiled
    binding_resolution: *const BindingResolver.BindingResolution,
    /// AST node current being compiled
    node: *AST.ASTNode,
    /// The top of the function compiler stack
    current: *FunctionCompiler,

    pub fn init(allocator: std.mem.Allocator, isolate: *Runtime.Isolate, binding_resolution: *const BindingResolver.BindingResolution, node: *AST.ASTNode) !CodeGenerator {
        return .{
            .allocator = allocator,
            .isolate = isolate,
            .binding_resolution = binding_resolution,
            .node = node,
            .current = try FunctionCompiler.init(allocator, try Entities.new_function_object(isolate), null),
        };
    }

    pub fn generate(self: *CodeGenerator) ?*Entities.ObjectFunction {
        self.generate_node(self.node) catch {
            // TODO: add diagnostic
            return null;
        };
        return self.current.function;
    }

    /// Extracts the resolved type from an AST node
    /// Only covers expression nodes
    pub fn resolve_typeof(node: *AST.ASTNode) AST.TypeId {
        return switch (node.*) {
            .int_lit => |n| n.resolved_type,
            .float_lit => |n| n.resolved_type,
            .str_lit => |n| n.resolved_type,
            .bool_lit => |n| n.resolved_type,
            .nil_lit => |n| n.resolved_type,
            .binary_expr => |n| n.resolved_type,
            .unary_expr => |n| n.resolved_type,
            .identifier_expr => |n| n.resolved_type,
            .assign_expr => |n| n.resolved_type,
            .cast_expr => |n| n.resolved_type,
            .call_expr => |n| n.resolved_type,
            .index_expr => |n| n.resolved_type,
            .dot_expr => |n| n.resolved_type,
            .static_member_expr => |n| n.resolved_type,
            .group_expr => |n| n.resolved_type,
            .tuple_expr => |n| n.resolved_type,
            .table_expr => |n| n.resolved_type,
            .array_expr => |n| n.resolved_type,
            .new_expr => |n| n.resolved_type,
            .match_expr => |n| n.resolved_type,
            .anon_fn_expr => |n| n.resolved_type,
            .anon_co_expr => |n| n.resolved_type,
            .shape_expr => |n| n.resolved_type,
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
            .expr_stmt => |stmt| {
                try self.generate_expression(stmt.expr);
                try self.current.chunk().write_opcode(.OP_POP, stmt.line);
            },

            .block_stmt => |stmt| {
                for (stmt.stmts) |blk_stmt| {
                    try self.generate_node(blk_stmt);
                }

                const pop_count = self.binding_resolution.scope_pop_counts.get(node) orelse return CodeGeneratorError.MissingBinding;
                try self.current.chunk().write_opcode(.OP_POP_N, stmt.line);
                try self.current.chunk().write_u16(pop_count, stmt.line);
            },

            .if_stmt => |stmt| {
                try self.generate_expression(stmt.condition);
                const then_jump = try self.emit_jump(.OP_JUMP_IF_FALSE, stmt.line);
                try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                try self.generate_node(stmt.then_branch);
                if (stmt.else_branch) |else_branch| {
                    const else_jump = try self.emit_jump(.OP_JUMP, stmt.line);
                    try self.patch_jump(then_jump);
                    try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                    try self.generate_node(else_branch);
                    try self.patch_jump(else_jump);
                    return;
                }
                const end_jump = try self.emit_jump(.OP_JUMP, stmt.line);
                try self.patch_jump(then_jump);
                try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                try self.patch_jump(end_jump);
            },

            .while_stmt => |stmt| {
                const loop_start = self.current.chunk().code.items.len;
                try self.generate_expression(stmt.condition);
                const exit_jump = try self.emit_jump(.OP_JUMP_IF_FALSE, stmt.line);
                try self.current.chunk().write_opcode(.OP_POP, stmt.line);
                try self.generate_node(stmt.body);
                try self.emit_loop(@intCast(loop_start), stmt.line);
                try self.patch_jump(exit_jump);
                try self.current.chunk().write_opcode(.OP_POP, stmt.line);
            },
            // TODO: complete
            else => return CodeGeneratorError.UnsupportedNode,
        }
    }

    fn generate_var_decl(self: *CodeGenerator, node: *AST.ASTNode, decl: *AST.VarDecl) CodeGeneratorError!void {
        try self.generate_expression(decl.initializer);

        const ref: AST.DeclRef = .{ .node = node };
        const binding = self.binding_resolution.decl_bindings.get(ref) orelse return CodeGeneratorError.MissingBinding;

        switch (binding.kind) {
            .local => {
                // The initializer is already sitting on the stack in the correct
                // slot position — a local's storage IS the stack slot. Nothing
                // further to emit. (Unexercised until function bodies compile.)
            },
            .global => {
                try self.current.chunk().write_opcode(.OP_STORE_GLOBAL, decl.line);
                try self.current.chunk().write_u16(binding.slot, decl.line);
                try self.current.chunk().write_opcode(.OP_POP, decl.line);
            },
            else => return CodeGeneratorError.UnsupportedNode,
        }
    }

    fn emit_loop(self: *CodeGenerator, loop_start: u32, line: usize) CodeGeneratorError!void {
        try self.current.chunk().write_opcode(.OP_LOOP, line);
        const offset = self.current.chunk().code.items.len - loop_start + 2; // +2 accounts for size of OP_LOOP
        if (offset > std.math.maxInt(u16)) {
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
            return CodeGeneratorError.LoopSizeTooLarge;
        }
        self.current.chunk().code.items[offset] = @intCast(jump >> 8);
        self.current.chunk().code.items[offset + 1] = @intCast(jump & 0xff);
    }

    fn generate_expression(self: *CodeGenerator, node: *AST.ASTNode) CodeGeneratorError!void {
        switch (node.*) {
            .int_lit => |lit| try self.current.chunk().emit_constant(.{ .int = lit.value }, lit.line),
            .float_lit => |lit| try self.current.chunk().emit_constant(.{ .float = lit.value }, lit.line),
            .bool_lit => |lit| try self.current.chunk().write_opcode(if (lit.value) .OP_TRUE else .OP_FALSE, lit.line),
            .nil_lit => |lit| try self.current.chunk().write_opcode(.OP_NIL, lit.line),
            .group_expr => |expr| try self.generate_expression(expr.expr),
            .unary_expr => |expr| try self.generate_unary_expression(expr),
            .binary_expr => |expr| try self.generate_binary_expr(expr),
            .resume_expr => |expr| try self.generate_resume_expression(expr),
            .identifier_expr => |expr| try self.generate_identifier_expr(node, expr),
            .assign_expr => |expr| try self.generate_assignment_expression(node, expr),
            else => return CodeGeneratorError.UnsupportedNode,
        }
    }

    fn generate_assignment_expression(self: *CodeGenerator, node: *AST.ASTNode, expr: *AST.AssignExpr) CodeGeneratorError!void {
        _ = self;
        _ = node;
        _ = expr;
    }

    fn generate_identifier_expr(self: *CodeGenerator, node: *AST.ASTNode, expr: *AST.IdentifierExpr) CodeGeneratorError!void {
        const binding = self.binding_resolution.ident_bindings.get(node) orelse return CodeGeneratorError.MissingBinding;
        switch (binding.kind) {
            .global => {
                try self.current.chunk().write_opcode(.OP_LOAD_GLOBAL, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            .local, .param => {
                try self.current.chunk().write_opcode(.OP_LOAD_LOCAL, expr.line);
                try self.current.chunk().write_u16(binding.slot, expr.line);
            },
            else => return CodeGeneratorError.UnsupportedNode, // method, comptime_type, imported_global
        }
    }

    fn generate_resume_expression(self: *CodeGenerator, node: *AST.ResumeExpr) CodeGeneratorError!void {
        _ = self;
        _ = node;
        return CodeGeneratorError.UnsupportedNode;
    }

    fn generate_unary_expression(self: *CodeGenerator, expr: *AST.UnaryExpr) CodeGeneratorError!void {
        try self.generate_expression(expr.expr);
        var opcode: ?Opcode = null;

        switch (expr.resolved_type) {
            @intFromEnum(TypeRegistry.PrimitiveType.Bool) => {
                if (std.mem.eql(u8, expr.operator.lexeme, "not")) {
                    opcode = .OP_LOGICAL_NOT;
                }
            },
            @intFromEnum(TypeRegistry.PrimitiveType.Int) => {
                if (std.mem.eql(u8, expr.operator.lexeme, "-")) {
                    opcode = .OP_NEGATE_INT;
                } else if (std.mem.eql(u8, expr.operator.lexeme, "~")) {
                    opcode = .OP_BITWISE_NOT;
                }
            },
            @intFromEnum(TypeRegistry.PrimitiveType.Float) => {
                if (std.mem.eql(u8, expr.operator.lexeme, "-")) {
                    opcode = .OP_NEGATE_FLOAT;
                }
            },
            else => unreachable,
        }

        if (opcode) |code| try self.current.chunk().write_opcode(code, expr.line) else return CodeGeneratorError.UnsupportedOperandType;
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

    fn generate_binary_expr(self: *CodeGenerator, expr: *AST.BinaryExpr) CodeGeneratorError!void {
        const op = expr.operator.lexeme;

        try self.generate_expression(expr.left);

        if (std.mem.eql(u8, op, "and")) {
            return try self.and_(expr.line, expr.right);
        } else if (std.mem.eql(u8, op, "or")) {
            return try self.or_(expr.line, expr.right);
        } else if (std.mem.eql(u8, op, "orelse")) {
            return try self.orelse_(expr.line, expr.right);
        }
        try self.generate_expression(expr.right);

        const left_kind = resolve_typeof(expr.left);
        const right_kind = resolve_typeof(expr.right);

        const opcode = try CodeGenerator.select_opcode(op, left_kind, right_kind);
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

        if (left == @intFromEnum(TypeRegistry.PrimitiveType.Int) and right == @intFromEnum(TypeRegistry.PrimitiveType.Int)) {
            if (std.mem.eql(u8, op, "<<")) return .OP_LEFT_SHIFT;
            if (std.mem.eql(u8, op, ">>")) return .OP_RIGHT_SHIFT;
            if (std.mem.eql(u8, op, "|")) return .OP_BITWISE_OR;
            if (std.mem.eql(u8, op, "&")) return .OP_BITWISE_AND;
            if (std.mem.eql(u8, op, "^")) return .OP_BITWISE_XOR;
        }

        return CodeGeneratorError.UnsupportedOperator;
    }

    fn arith(left: TypeRegistry.TypeId, right: TypeRegistry.TypeId, int_op: Opcode, float_op: Opcode, int_float_op: Opcode, float_int_op: Opcode) Opcode {
        return switch (left) {
            @intFromEnum(TypeRegistry.PrimitiveType.Int) => switch (right) {
                @intFromEnum(TypeRegistry.PrimitiveType.Int) => int_op,
                @intFromEnum(TypeRegistry.PrimitiveType.Float) => int_float_op,
                else => unreachable,
            },
            @intFromEnum(TypeRegistry.PrimitiveType.Float) => switch (right) {
                @intFromEnum(TypeRegistry.PrimitiveType.Int) => float_int_op,
                @intFromEnum(TypeRegistry.PrimitiveType.Float) => float_op,
                else => unreachable,
            },
            else => unreachable,
        };
    }
};
