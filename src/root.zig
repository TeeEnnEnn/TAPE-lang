//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

pub const ast = @import("compiler/ast.zig");
pub const scanner = @import("compiler/scanner.zig");
pub const parser = @import("compiler/parser.zig");
pub const type_registry = @import("compiler/type_registry.zig");
pub const environment = @import("compiler/environment.zig");


test {
    _ = @import("compiler/scanner.zig");
    _ = @import("compiler/parser.zig");
    _ = @import("compiler/type_registry.zig");
    _ = @import("compiler/environment.zig");
    _ = @import("compiler/tests/test_scanner.zig");
    _ = @import("compiler/tests/test_parser.zig");
    _ = @import("compiler/tests/test_type_registry.zig");
    _ = @import("compiler/tests/test_environement.zig");
    _ = @import("compiler/tests/test_type_checker.zig");
}
