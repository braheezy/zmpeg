const std = @import("std");
const sdl = @import("sdl");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = std.builtin.OptimizeMode.ReleaseFast;

    const sdk = sdl.init(b, .{});

    const mod = b.addModule("zmpeg", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "player",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zmpeg", .module = mod },
                .{ .name = "sdl2", .module = sdk.getWrapperModule() },
            },
        }),
    });

    sdk.link(exe, .static, sdl.Library.SDL2);

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    var converted_args: ?[]const []const u8 = null;
    const allocator = std.heap.page_allocator;
    if (b.args) |args| {
        var convert_index: ?usize = null;
        var mp4_input: []const u8 = undefined;
        for (args, 0..) |arg, index| {
            if (hasMp4Extension(arg)) {
                convert_index = index;
                mp4_input = arg;
                break;
            }
        }

        if (convert_index) |index| {
            const mpg_path = convertMp4ToMpgPath(allocator, mp4_input);
            const convert_cmd = b.addSystemCommand(&.{
                "ffmpeg",
                "-y",
                "-i",
                mp4_input,
                "-q:v",
                "2",
                "-q:a",
                "2",
                "-f",
                "mpeg",
                mpg_path,
            });
            run_cmd.step.dependOn(&convert_cmd.step);

            var args_copy_list = std.ArrayList([]const u8).empty;
            for (args) |arg| {
                args_copy_list.append(allocator, arg) catch |err| {
                    std.debug.panic("unable to copy run args: {}", .{err});
                };
            }
            const args_copy = args_copy_list.items;
            args_copy[index] = mpg_path;
            converted_args = args_copy;
        }
    }

    if (converted_args) |args| {
        run_cmd.addArgs(args);
    } else if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
}

const mp4Ext = ".mp4";

fn hasMp4Extension(path: []const u8) bool {
    return extensionMatchesCaseInsensitive(path, mp4Ext);
}

fn convertMp4ToMpgPath(allocator: std.mem.Allocator, input_path: []const u8) []const u8 {
    const base = input_path[0 .. input_path.len - mp4Ext.len];
    return std.fmt.allocPrint(allocator, "{s}.mpg", .{base}) catch |err| {
        std.debug.panic("failed to build output path for mp4 conversion: {}", .{err});
    };
}

fn extensionMatchesCaseInsensitive(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    const suffix = path[path.len - ext.len ..];
    var i: usize = 0;
    while (i < ext.len) : (i += 1) {
        if (toLowerAscii(suffix[i]) != toLowerAscii(ext[i])) return false;
    }
    return true;
}

fn toLowerAscii(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
