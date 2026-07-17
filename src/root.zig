//! Root source file of the TAPE-lang package

// Compiler
pub const ast = @import("compiler/ast.zig");
pub const ast_debug = @import("compiler/ast_debug.zig");
pub const binding_resolver = @import("compiler/binding_resolver.zig");
pub const code_gen = @import("compiler/code_gen.zig");
pub const code_gen_debug = @import("compiler/code_gen_debug.zig");
pub const environment = @import("compiler/environment.zig");
pub const parser = @import("compiler/parser.zig");
pub const scanner = @import("compiler/scanner.zig");
pub const type_checker = @import("compiler/type_checker.zig");
pub const type_registry = @import("compiler/type_registry.zig");
pub const workspace = @import("compiler/workspace.zig");

// Diagnostics
pub const diagnostics = @import("diagnostics/diagnostics.zig");

// CLI
pub const cli = @import("cli/cli.zig");

// Runtime
pub const entities = @import("runtime/entities.zig");
pub const chunk = @import("runtime/chunk.zig");
pub const vm = @import("runtime/vm.zig");

// Memory
pub const basic_garbage_collector = @import("memory/basic_garbage_collector.zig");
pub const managed_allocator = @import("memory/managed_allocator.zig");
pub const slab_allocator = @import("memory/slab_allocator.zig");

test {
    // cli
    _ = @import("_tests/cli/test_helpers.zig");
    // compiler
    _ = @import("_tests/compiler/test_binidng_resolver.zig");
    _ = @import("_tests/compiler/test_environement.zig");
    _ = @import("_tests/compiler/test_parser.zig");
    _ = @import("_tests/compiler/test_scanner.zig");
    _ = @import("_tests/compiler/test_type_checker.zig");
    _ = @import("_tests/compiler/test_type_registry.zig");
    // memory
    // runtime
    _ = @import("_tests/runtime/test_chunk.zig");
    _ = @import("_tests/runtime/test_entities.zig");
}
