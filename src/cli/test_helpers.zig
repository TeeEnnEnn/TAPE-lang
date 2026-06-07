const std = @import("std");
const ManifestConfig = @import("helpers.zig").ManifestConfig;

test "can parse manifest content" {
    const manifest_content =
        \\{
        \\    "name": "WonderfulPackage2000",
        \\    "package_version": "0.0.1",
        \\    "entrypoint": "src/main.tape",
        \\    "tape_version": "dev",
        \\    "packages": [
        \\        {
        \\            "name": "foo",
        \\            "version": "1.0.0"
        \\        },
        \\        {
        \\            "name": "bar",
        \\            "version": "2.0.0"
        \\        },
        \\        {
        \\            "name": "baz",
        \\            "version": "3.0.0"
        \\        }
        \\    ]
        \\}
    ;

    const allocator = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(ManifestConfig, allocator, manifest_content, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const manifest = parsed.value;

    try std.testing.expectEqualStrings("WonderfulPackage2000", manifest.name);
    try std.testing.expectEqualStrings("src/main.tape", manifest.entrypoint);
    try std.testing.expectEqualStrings("dev", manifest.tape_version);
    try std.testing.expectEqualStrings("0.0.1", manifest.package_version);
    try std.testing.expectEqual(@as(usize, 3), manifest.packages.len);
    try std.testing.expectEqualStrings("foo", manifest.packages[0].name);
    try std.testing.expectEqualStrings("1.0.0", manifest.packages[0].version);
    try std.testing.expectEqualStrings("bar", manifest.packages[1].name);
    try std.testing.expectEqualStrings("2.0.0", manifest.packages[1].version);
    try std.testing.expectEqualStrings("baz", manifest.packages[2].name);
    try std.testing.expectEqualStrings("3.0.0", manifest.packages[2].version);
}
