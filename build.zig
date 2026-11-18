const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{
            .explicit = &std.Target.aarch64.cpu.cortex_a57,
        },
        .cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align}),
    });
    const optimize = b.standardOptimizeOption(.{});

    const kernel = b.addExecutable(.{
        .name = "openkern",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/boot.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    kernel.setLinkerScript(b.path("linker.ld"));

    b.installArtifact(kernel);

    const run_qemu = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt",
        "-cpu",
        "cortex-a57",
        "-m",
        "1G",
        "-nographic",
        "-kernel",
    });
    run_qemu.addArtifactArg(kernel);
    run_qemu.stdio = .inherit;

    const run_step = b.step("run", "Run the kernel in QEMU");
    run_step.dependOn(&run_qemu.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
