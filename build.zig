const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const version_option: []const u8 = b.option([]const u8, "version", "TAPE version string.") orelse "dev";
    const compiler_thread_count_option: u32 = b.option(u32, "compiler_thread_count", "Number of compiler threads to use.") orelse 4;
    const stress_gc_option: bool = b.option(bool, "stress_gc", "Run the garbage collector after every allocation") orelse false;
    const log_gc_option: bool = b.option(bool, "log_gc", "Log the garbage collector's actions") orelse false;
    const report_leaks: bool = b.option(bool, "report_leacks", "Report the number of leaks at the end of execution") orelse true;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version_option);
    options.addOption(u32, "compiler_thread_count", compiler_thread_count_option);
    options.addOption(bool, "stress_gc", stress_gc_option);
    options.addOption(bool, "log_gc", log_gc_option);
    options.addOption(bool, "report_leaks", report_leaks);

    const options_module = options.createModule();

    const mod = b.addModule("TAPE", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "TAPE_build_options", .module = options_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = "TAPE",
        .use_llvm = true,
        .use_lld = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "TAPE", .module = mod },
                .{ .name = "TAPE_build_options", .module = options_module },
            },
        }),
    });

    b.installArtifact(exe);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const exe_test_step = b.step("test-exe", "Run exe module tests");
    exe_test_step.dependOn(&run_exe_tests.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "TAPE_build_options", .module = options_module }},
    });
    const tests = b.addTest(.{ .root_module = test_module });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
