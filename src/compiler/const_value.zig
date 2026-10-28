const std = @import("std");
const AST = @import("ast.zig");

/// A compile-time literal value.
///
/// Module-level `const` declarations must initialize with one of these so
/// the binding resolver can inline them at every use instead of emitting a
/// runtime global slot.
pub const ConstValue = union(enum) {
    int: i64,
    float: f64,
    bool: bool,
    nil: void,
    string: []const u8,

    /// Reads a literal (optionally with a leading `-` or `~`). This is not folding.
    pub fn from_literal(node: *AST.ASTNode) ?ConstValue {
        return switch (node.*) {
            .int_lit => |l| .{ .int = l.value },
            .float_lit => |l| .{ .float = l.value },
            .bool_lit => |l| .{ .bool = l.value },
            .str_lit => |l| .{ .string = l.value },
            .nil_lit => ConstValue{ .nil = {} },
            .unary_expr => |u| {
                const op = u.operator.lexeme;
                switch (u.expr.*) {
                    .int_lit => |l| {
                        if (std.mem.eql(u8, op, "-")) return .{ .int = -l.value };
                        if (std.mem.eql(u8, op, "~")) return .{ .int = ~l.value };
                    },
                    .float_lit => |l| {
                        if (std.mem.eql(u8, op, "-")) return .{ .float = -l.value };
                    },
                    else => {},
                }
                return null;
            },
            else => null,
        };
    }
};
