// Keep the test module root at src/ so test files can import sibling
// compiler, runtime, and CLI modules while the aggregator lives in tests/.
test {
    _ = @import("tests/root.zig");
}
