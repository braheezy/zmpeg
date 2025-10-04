const std = @import("std");
const sdl = @import("sdl");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdk = sdl.init(b, .{});

    const mod = b.addModule("zmpeg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "player",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zmpeg", .module = mod },
            },
        }),
    });

    exe.root_module.addImport("sdl2", sdk.getWrapperModule());
    sdk.link(exe, .static, sdl.Library.SDL2);

    b.installArtifact(exe);

    const dump_exe = b.addExecutable(.{
        .name = "audio_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/audio_dump.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "zmpeg", .module = mod } },
        }),
    });
    b.installArtifact(dump_exe);

    const dump_step = b.step("audio-dump", "Build audio dump utility");
    dump_step.dependOn(&dump_exe.step);

    // SDL audio test
    const test_exe = b.addExecutable(.{
        .name = "test_sdl_audio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_sdl_audio.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addImport("sdl2", sdk.getWrapperModule());
    sdk.link(test_exe, .static, sdl.Library.SDL2);
    b.installArtifact(test_exe);

    const test_run_step = b.step("test-audio", "Test SDL audio");
    const test_run_cmd = b.addRunArtifact(test_exe);
    test_run_step.dependOn(&test_run_cmd.step);
    test_run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}
