const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const nd2_mod = b.addModule("nd2", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const example_mod = b.createModule(.{
        .root_source_file = b.path("examples/read_summary.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "nd2", .module = nd2_mod },
        },
    });
    const example_exe = b.addExecutable(.{
        .name = "read_summary",
        .root_module = example_mod,
    });
    b.installArtifact(example_exe);

    const run_example = b.addRunArtifact(example_exe);
    const run_step = b.step("run", "Run the read_summary example");
    run_step.dependOn(&run_example.step);

    const unit_tests = b.addTest(.{
        .root_module = nd2_mod,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run nd2 unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
