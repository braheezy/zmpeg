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

    var mpeg = try zmpeg.createFromFile(allocator, "trouble-pogo-5s.mpg");
    defer mpeg.deinit();

    mpeg.setAudio(false);

    const width = mpeg.getWidth();
    const height = mpeg.getHeight();

    std.debug.print("width: {d}, height: {d}\n", .{ width, height });
}
