const std = @import("std");

/// The name of the app file, "app-manager.app": no spaces, the reader does not start apps of its
/// menu whose path has one. The title on screen and in the menu is translated.
const app_name = "app-manager";

const version = @import("build.zig.zon").version;

/// PocketBook's hardware families run the same firmware but differ in how their system
/// libraries pass floating point values, and a binary only loads on the matching kind.
const Platform = enum {
    /// Allwinner B288/B300 readers (Era, Verse, Vivlio Light HD Color, ...): soft-float
    allwinner,
    /// Rockchip RK3566 readers (Verta, InkPad One, PocketBook Q): hard-float
    rk3566,
};

pub fn build(b: *std.Build) void {
    const platform = b.option(Platform, "platform", "Reader hardware to build for (default: allwinner)") orelse .allwinner;

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = switch (platform) {
            .allwinner => .gnueabi,
            .rk3566 => .gnueabihf,
        },
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
        .os_version_min = .{ .semver = .{ .major = 3, .minor = 10, .patch = 0 } },
        // Zig's start code calls `getauxval`, which glibc has since 2.16
        .glibc_version = .{ .major = 2, .minor = 16, .patch = 0 },
    });
    const optimize = b.standardOptimizeOption(.{});

    const inkview = b.addTranslateC(.{
        .root_source_file = b.path("include/inkview.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    inkview.addIncludePath(b.path("include"));

    const exe = b.addExecutable(.{
        .name = app_name ++ ".app",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    const options = b.addOptions();
    options.addOption([:0]const u8, "app_name", app_name);
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "platform", @tagName(platform));
    // What the app compares with the published builds of itself
    options.addOption([]const u8, "commit", b.option([]const u8, "commit", "Git commit the build is made from") orelse "dev");
    options.addOption([]const u8, "channel", b.option([]const u8, "channel", "nightly, release or dev (default)") orelse "dev");
    exe.root_module.addOptions("build_options", options);

    exe.root_module.addImport("c", inkview.createModule());
    addCatalog(b, exe.root_module);
    exe.root_module.addLibraryPath(b.path("lib"));
    exe.root_module.linkSystemLibrary("inkview", .{});
    exe.root_module.linkLibrary(stubLibrary(b, target, "curl", 4));

    b.installArtifact(exe);

    // `zig build test` runs the unit tests on the build machine, for the files that need
    // nothing from the reader.
    const test_step = b.step("test", "Run the unit tests");
    for ([_][]const u8{ "src/i18n.zig", "src/catalog.zig", "src/view.zig", "src/failure.zig", "src/zip.zig" }) |file| {
        const tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(file),
                .target = b.graph.host,
                .link_libc = true,
            }),
        });
        addCatalog(b, tests.root_module);
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
}

/// The catalog is built into the app, for when it cannot be loaded
fn addCatalog(b: *std.Build, module: *std.Build.Module) void {
    module.addAnonymousImport("catalog_txt", .{ .root_source_file = b.path("catalog.txt") });
}

/// libcurl only exists on the reader. To link without a copy of it, a stub exports the same
/// symbols under the same soname (lib<name>.so.<major>).
fn stubLibrary(b: *std.Build, target: std.Build.ResolvedTarget, name: []const u8, major: usize) *std.Build.Step.Compile {
    return b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .version = .{ .major = major, .minor = 0, .patch = 0 },
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("stubs/{s}.zig", .{name})),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });
}
