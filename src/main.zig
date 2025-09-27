const std = @import("std");
const builtin = @import("builtin");
const zmpeg = @import("zmpeg");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var v = try zmpeg.Video.createFromFile(allocator, "trouble-pogo.mpg");
    defer v.deinit();

    std.debug.print("duration: {d}\n", .{v.demux.getDuration(.video1)});
}
