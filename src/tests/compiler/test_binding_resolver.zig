const std = @import("std");
const AST = @import("../../compiler/ast.zig");
const BindingKind = @import("../../compiler/binding_resolver.zig").BindingKind;
const BindingResolver = @import("../../compiler/binding_resolver.zig").BindingResolver;
const Environment = @import("../../compiler/environment.zig").Environment;
const Module = @import("../../compiler/workspace.zig").Module;
const Parser = @import("../../compiler/parser.zig").Parser;
const TypeChecker = @import("../../compiler/type_checker.zig").TypeChecker;
const PrimitiveType = @import("../../compiler/type_registry.zig").PrimitiveType;
const TypeRegistry = @import("../../compiler/type_registry.zig").TypeRegistry;
const Workspace = @import("../../compiler/workspace.zig").Workspace;

test "Binding Resolver - registers explicit self param for methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "struct Point3D { x: Int, y: Int, z: Int, fn print(self) -> Nil { self.x; self.y; self.z; } }";

    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test", source, allocator, true);
    defer {
        mod.deinit();
        allocator.destroy(mod);
    }

    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    mod.ast = try parser.parse();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    var env = Environment.init(allocator, null);
    defer env.deinit();

    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(mod.ast);

    mod.binding_resolution = try BindingResolver.resolve(allocator, &registry, &workspace.diagnostics, mod, &workspace, mod.ast);

    try std.testing.expect(!workspace.diagnostics.has_errors);

    const struct_node = mod.ast.program.declarations[0];
    try std.testing.expect(struct_node.* == .struct_decl);
    const method_node = struct_node.struct_decl.methods[0].method;
    try std.testing.expect(method_node.* == .fn_decl);

    const self_ref: AST.DeclRef = .{ .param = .{ .func = method_node, .index = 0 } };
    const self_binding = mod.binding_resolution.declaration_bindings.get(self_ref) orelse return error.MissingSelfBinding;
    try std.testing.expectEqual(BindingKind.param, self_binding.kind);
    try std.testing.expectEqualStrings("self", self_binding.name);

    const method_info = mod.binding_resolution.function_infos.get(method_node) orelse return error.MissingFunctionInfo;
    try std.testing.expectEqual(@as(u16, 1), method_info.param_count);

    const dot_node = method_node.fn_decl.body.block_stmt.stmts[0].expr_stmt.expr;
    try std.testing.expect(dot_node.* == .dot_expr);
    const member_info = mod.binding_resolution.member_infos.get(dot_node) orelse return error.MissingMemberInfo;
    try std.testing.expect(member_info == .field);
}

test "Binding Resolver - capture occupies the condition slot and is scoped to the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source =
        \\fn f(m: ?Int) -> Int {
        \\    var out = 0;
        \\    if (m) bind (v) {
        \\        var inner = v + 1;
        \\        out = inner;
        \\    }
        \\    var after = 10;
        \\    return out + after;
        \\}
    ;

    const io = std.testing.io;
    var group = std.Io.Group.init;
    var workspace = Workspace.init(allocator, io);
    defer workspace.deinit();

    const mod = try Module.init("test", source, allocator, true);
    defer {
        mod.deinit();
        allocator.destroy(mod);
    }

    var parser = try Parser.init(allocator, &workspace, mod, io, &group);
    mod.ast = try parser.parse();

    var registry = try TypeRegistry.init(allocator);
    defer registry.deinit();

    var env = Environment.init(allocator, null);
    defer env.deinit();

    var checker = TypeChecker.init(allocator, &registry, &env, &workspace.diagnostics, mod, &workspace);
    _ = try checker.check(mod.ast);

    mod.binding_resolution = try BindingResolver.resolve(allocator, &registry, &workspace.diagnostics, mod, &workspace, mod.ast);

    try std.testing.expect(!workspace.diagnostics.has_errors);

    const fn_node = mod.ast.program.declarations[0];
    const body = fn_node.fn_decl.body;
    const out_decl = body.block_stmt.stmts[0];
    const if_node = body.block_stmt.stmts[1];
    const after_decl = body.block_stmt.stmts[2];

    const cap = if_node.if_stmt.capture.?;
    const cap_binding = mod.binding_resolution.declaration_bindings.get(.{ .capture = cap }) orelse return error.MissingCaptureBinding;
    const out_binding = mod.binding_resolution.declaration_bindings.get(.{ .node = out_decl }) orelse return error.MissingOutBinding;
    const after_binding = mod.binding_resolution.declaration_bindings.get(.{ .node = after_decl }) orelse return error.MissingAfterBinding;

    const inner_decl = if_node.if_stmt.then_branch.block_stmt.stmts[0];
    const inner_binding = mod.binding_resolution.declaration_bindings.get(.{ .node = inner_decl }) orelse return error.MissingInnerBinding;

    try std.testing.expectEqual(BindingKind.local, cap_binding.kind);
    try std.testing.expectEqual(@backingInt(PrimitiveType.Int), cap_binding.type_id);

    // The capture sits directly above the locals that existed before the `if`...
    try std.testing.expectEqual(out_binding.slot + 1, cap_binding.slot);
    // ...body locals sit above the capture...
    try std.testing.expectEqual(cap_binding.slot + 1, inner_binding.slot);
    // ...and the capture's slot is released afterwards (reused by `after`).
    try std.testing.expectEqual(cap_binding.slot, after_binding.slot);

    try std.testing.expectEqual(@as(u16, 1), mod.binding_resolution.scope_pop_counts.get(if_node).?);
}
