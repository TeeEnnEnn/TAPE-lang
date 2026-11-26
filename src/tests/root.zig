// Import each test module so Zig includes its test declarations in this test
// artifact. Keep this list aligned with the test files under src/tests.

// TODO: Comptime something something, so i don't forget to update this
test {
    _ = @import("cli/test_helpers.zig");
    _ = @import("compiler/test_binding_resolver.zig");
    _ = @import("compiler/test_code_gen.zig");
    _ = @import("compiler/test_environment.zig");
    _ = @import("compiler/test_parser.zig");
    _ = @import("compiler/test_scanner.zig");
    _ = @import("compiler/test_type_checker.zig");
    _ = @import("compiler/test_type_registry.zig");
    _ = @import("runtime/test_chunk.zig");
    _ = @import("runtime/test_entities.zig");
    _ = @import("runtime/test_optional_unwrap.zig");
}
