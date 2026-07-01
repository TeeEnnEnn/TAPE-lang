//! By convention, root.zig is the root source file when making a package.

// Compiler
pub const ast = @import("compiler/ast.zig");
pub const scanner = @import("compiler/scanner.zig");
pub const parser = @import("compiler/parser.zig");
pub const type_registry = @import("compiler/type_registry.zig");
pub const environment = @import("compiler/environment.zig");
pub const type_checker = @import("compiler/type_checker.zig");
pub const workspace = @import("compiler/workspace.zig");

// Helpers
pub const diagnostics = @import("helpers/diagnostics.zig");

// CLI
pub const cli = @import("cli/cli.zig");
pub const cli_helpers = @import("cli/helpers.zig");

// VM
pub const entities = @import("vm/entities.zig");
pub const chunk = @import("vm/chunk.zig");

// Memory
pub const basic_allocator = @import("memory/basic_allocator.zig");

test {
    _ = @import("compiler/scanner.zig");
    _ = @import("compiler/parser.zig");
    _ = @import("compiler/type_registry.zig");
    _ = @import("compiler/environment.zig");
    _ = @import("compiler/type_checker.zig");
    _ = @import("compiler/workspace.zig");

    _ = @import("compiler/tests/test_scanner.zig");
    _ = @import("compiler/tests/test_parser.zig");
    _ = @import("compiler/tests/test_type_registry.zig");
    _ = @import("compiler/tests/test_environement.zig");
    _ = @import("compiler/tests/test_type_checker.zig");

    _ = @import("vm/entities.zig");
    _ = @import("vm/chunk.zig");

    _ = @import("vm/tests/test_chunk.zig");
    _ = @import("vm/tests/test_entities.zig");

    _ = @import("helpers/diagnostics.zig");

    _ = @import("cli/cli.zig");
    _ = @import("cli/helpers.zig");
    _ = @import("cli/test_helpers.zig");

    _ = @import("memory/basic_allocator.zig");
    _ = @import("memory/tests/test_basic_allocator.zig");
}
