const GhosttyLibRenderer = @This();

const std = @import("std");
const RunStep = std.Build.Step.Run;
const SharedDeps = @import("SharedDeps.zig");
const LibtoolStep = @import("LibtoolStep.zig");

step: *std.Build.Step,
output: std.Build.LazyPath,

pub fn initStatic(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyLibRenderer {
    const lib = b.addLibrary(.{
        .name = "ghostty-renderer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib_renderer.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
        }),
        .use_llvm = true,
    });
    lib.linkLibC();

    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    lib.root_module.pic = true;

    if (deps.config.target.result.os.tag == .windows) {
        lib.bundle_ubsan_rt = false;
    }

    var lib_list = try deps.add(lib);
    try lib_list.append(b.allocator, lib.getEmittedBin());

    if (!deps.config.target.result.os.tag.isDarwin()) return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
    };

    const libtool = LibtoolStep.create(b, .{
        .name = "ghostty-renderer",
        .out_name = "libghostty-renderer.a",
        .sources = lib_list.items,
    });
    libtool.step.dependOn(&lib.step);

    return .{
        .step = libtool.step,
        .output = libtool.output,
    };
}

pub fn install(self: *const GhosttyLibRenderer) void {
    const b = self.step.owner;
    const lib_install = b.addInstallLibFile(
        self.output,
        "libghostty-renderer.a",
    );
    b.getInstallStep().dependOn(&lib_install.step);

    const header_install = b.addInstallHeaderFile(
        b.path("include/ghostty/renderer.h"),
        "ghostty/renderer.h",
    );
    b.getInstallStep().dependOn(&header_install.step);
}
