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
}
