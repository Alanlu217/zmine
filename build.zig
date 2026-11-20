const std = @import("std");

const ch_content =
    \\#include "sokol_app.h"
    \\#include "sokol_gfx.h"
    \\#include "sokol_glue.h"
    \\#include "sokol_log.h"
    \\
;

const impl_content =
    \\#define SOKOL_IMPL
    \\#define SOKOL_NO_ENTRY
    \\#include "sokol_app.h"
    \\#include "sokol_gfx.h"
    \\#include "sokol_glue.h"
    \\#include "sokol_log.h"
    \\
;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // sokol headers, fetched via build.zig.zon
    const sokol = b.dependency("sokol", .{});
    const sokol_inc = sokol.path(".");

    // generated sources
    const gen = b.addWriteFiles();
    const c_h = gen.add("c.h", ch_content);
    const impl_c = gen.add("sokol_impl.c", impl_content);

    // c.h -> "c" Zig module
    const translate_c = b.addTranslateC(.{
        .root_source_file = c_h,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(sokol_inc);

    // sokol implementation -> static library
    const lib_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addIncludePath(sokol_inc);

    switch (target.result.os.tag) {
        .linux => {
            lib_mod.addCSourceFile(.{ .file = impl_c, .flags = &.{"-DSOKOL_GLCORE"} });
            for ([_][]const u8{ "X11", "Xi", "Xcursor", "GL", "dl", "m", "pthread" }) |l|
                lib_mod.linkSystemLibrary(l, .{});
        },
        .windows => {
            lib_mod.addCSourceFile(.{ .file = impl_c, .flags = &.{"-DSOKOL_GLCORE"} });
            for ([_][]const u8{ "kernel32", "user32", "gdi32", "shell32" }) |l|
                lib_mod.linkSystemLibrary(l, .{});
        },
        .macos => {
            lib_mod.addCSourceFile(.{
                .file = impl_c,
                .flags = &.{"-DSOKOL_METAL"},
                .language = .objective_c,
            });
            for ([_][]const u8{ "Cocoa", "QuartzCore", "Metal", "MetalKit" }) |f|
                lib_mod.linkFramework(f, .{});
        },
        else => @panic("unsupported target"),
    }

    const lib = b.addLibrary(.{
        .name = "sokol",
        .linkage = .static,
        .root_module = lib_mod,
    });

    // main module + "c" module, linked against the static lib
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = translate_c.createModule() },
        },
    });
    exe_mod.linkLibrary(lib);

    const exe = b.addExecutable(.{ .name = "demo", .root_module = exe_mod });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Run the demo").dependOn(&run.step);
}
