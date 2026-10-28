const std = @import("std");
const AST = @import("../../compiler/ast.zig");
const BindingKind = @import("../../compiler/binding_resolver.zig").BindingKind;
const BindingResolver = @import("../../compiler/binding_resolver.zig").BindingResolver;
const Environment = @import("../../compiler/environment.zig").Environment;
const Module = @import("../../compiler/workspace.zig").Module;
const Parser = @import("../../compiler/parser.zig").Parser;
const TypeChecker = @import("../../compiler/type_checker.zig").TypeChecker;
const TypeRegistry = @import("../../compiler/type_registry.zig").TypeRegistry;
const Workspace = @import("../../compiler/workspace.zig").Workspace;

test "Binding Resolver - registers implicit self param for methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source = "struct Point3D { x: Int, y: Int, z: Int, fn print() -> Nil { self.x; self.y; self.z; } }";

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
