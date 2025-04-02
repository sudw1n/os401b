const std = @import("std");

const Feature = std.Target.x86.Feature;

pub fn build(b: *std.Build) void {
    const build_options = b.addOptions();
    const memory = b.option(u64, "memory", "Memory to be allocated for the kernel in MiB (default: 128 MiB)") orelse 128;
    const page_size = b.option(u64, "page_size", "Page size for the kernel in bytes (default: 4096)") orelse 4096;
    build_options.addOption(u64, "memory", memory);
    build_options.addOption(u64, "page_size", page_size);
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
    const limine = b.dependency("limine_zig", .{
        // The API revision of the Limine Boot Protocol to use, if not provided
        // it defaults to 0. Newer revisions may change the behavior of the bootloader.
        .api_revision = 3,
        // Whether to allow using deprecated features of the Limine Boot Protocol.
        // If set to false, the build will fail if deprecated features are used.
        .allow_deprecated = false,
        // Whether to expose pointers in the API. When set to true, any field
        // that is a pointer will be exposed as a raw address instead.
        .no_pointers = false,
    });

    const os401b = b.addModule("os401b", .{
        .root_source_file = b.path("src/os401b.zig"),
        .target = target,
        .optimize = optimize,
    });
    os401b.addImport("limine", limine.module("limine"));
    os401b.addOptions("build_options", build_options);

    const kernel = b.addExecutable(.{
        .name = "kernel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = code_model,
    });

    kernel.want_lto = false;
    kernel.setLinkerScript(linker_script_path);
    kernel.root_module.addImport("os401b", os401b);
    b.installArtifact(kernel);
}
