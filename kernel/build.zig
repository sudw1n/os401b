const std = @import("std");

const Feature = std.Target.x86.Feature;

pub fn build(b: *std.Build) void {
    var target_query: std.Target.Query = .{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
    };
    const code_model: std.builtin.CodeModel = .kernel;
    const linker_script_path: std.Build.LazyPath = b.path("linker.ld");

    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.mmx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.sse2));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx));
    target_query.cpu_features_sub.addFeature(@intFromEnum(Feature.avx2));
    target_query.cpu_features_add.addFeature(@intFromEnum(Feature.soft_float));

    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const limine = b.dependency("limine", .{});

    const os401b = b.addModule("os401b", .{
        .root_source_file = b.path("src/os401b.zig"),
        .target = target,
        .optimize = optimize,
    });
    os401b.addImport("limine", limine.module("limine"));

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });

    kernel.want_lto = false;
    kernel.setLinkerScriptPath(linker_script_path);
    kernel.root_module.addImport("os401b", os401b);
    b.installArtifact(kernel);
}
