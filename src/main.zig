const std = @import("std");
const builtin = @import("builtin");
const zmpeg = @import("zmpeg");
const sdl = @import("sdl2");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const fnv_offset_basis: u64 = 1469598103934665603;
const fnv_prime: u64 = 1099511628211;

fn hashFrame(hash: u64, data: []const u8) u64 {
    var h = hash;
    for (data) |byte| {
        h ^= byte;
        h *%= fnv_prime;
    }
    return h;
}

fn clampToU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

fn frameToBgr(frame: *const zmpeg.Frame, dest: []u8, row_stride: usize) void {
    const width = @as(usize, frame.width);
    const height = @as(usize, frame.height);
    if (height == 0 or width == 0) return;
    if (dest.len < row_stride * height) return;

    const cols = width >> 1;
    const rows = height >> 1;
    const yw = @as(i32, @intCast(frame.y.width));
    const cw = @as(i32, @intCast(frame.cb.width));

    const y_data = frame.y.data;
    const cr_data = frame.cr.data;
    const cb_data = frame.cb.data;

    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var c_index: usize = row * @as(usize, @intCast(cw));
        var y_index: usize = row * 2 * @as(usize, @intCast(yw));
        var d_index: usize = row * 2 * row_stride;

        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const cr = @as(i32, cr_data[c_index]) - 128;
            const cb = @as(i32, cb_data[c_index]) - 128;
            const r = (cr * 104_597) >> 16;
            const g = (cb * 25_674 + cr * 53_278) >> 16;
            const b = (cb * 132_201) >> 16;

            const y_stride_usize = @as(usize, @intCast(yw));

            if (y_index < y_data.len) {
                const yy0 = ((@as(i32, y_data[y_index]) - 16) * 76_309) >> 16;
                if (d_index + 2 < dest.len) {
                    dest[d_index + 2] = clampToU8(yy0 + r);
                    dest[d_index + 1] = clampToU8(yy0 - g);
                    dest[d_index + 0] = clampToU8(yy0 + b);
                }
            }

            if (y_index + 1 < y_data.len) {
                const yy1 = ((@as(i32, y_data[y_index + 1]) - 16) * 76_309) >> 16;
                const dst1 = d_index + 3;
                if (dst1 + 2 < dest.len) {
                    dest[dst1 + 2] = clampToU8(yy1 + r);
                    dest[dst1 + 1] = clampToU8(yy1 - g);
                    dest[dst1 + 0] = clampToU8(yy1 + b);
                }
            }

            if (y_index + y_stride_usize < y_data.len) {
                const yy2 = ((@as(i32, y_data[y_index + y_stride_usize]) - 16) * 76_309) >> 16;
                const dst2 = d_index + row_stride;
                if (dst2 + 2 < dest.len) {
                    dest[dst2 + 2] = clampToU8(yy2 + r);
                    dest[dst2 + 1] = clampToU8(yy2 - g);
                    dest[dst2 + 0] = clampToU8(yy2 + b);
                }
            }

            if (y_index + y_stride_usize + 1 < y_data.len) {
                const yy3 = ((@as(i32, y_data[y_index + y_stride_usize + 1]) - 16) * 76_309) >> 16;
                const dst3 = d_index + row_stride + 3;
                if (dst3 + 2 < dest.len) {
                    dest[dst3 + 2] = clampToU8(yy3 + r);
                    dest[dst3 + 1] = clampToU8(yy3 - g);
                    dest[dst3 + 0] = clampToU8(yy3 + b);
                }
            }

            c_index += 1;
            y_index += 2;
            d_index += 6;
        }
    }
}

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

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var input_path: []const u8 = "trouble-pogo-5s.mpg";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] != '-') {
            input_path = arg;
        }
    }

    // Initialize MPEG decoder
    var mpeg = try zmpeg.createFromFile(allocator, input_path);
    defer mpeg.deinit();

    mpeg.setAudio(false);

    const width = mpeg.getWidth();
    const height = mpeg.getHeight();

    std.debug.print("width: {d}, height: {d}\n", .{ width, height });
    if (width <= 0 or height <= 0) return;

    // Initialize SDL
    try sdl.init(.{
        .video = true,
    });
    defer sdl.quit();

    // Create window
    const window_width = 800;
    const window_height = 600;

    const window = try sdl.createWindow(
        "ZMPEG Video Player",
        .centered,
        .centered,
        window_width,
        window_height,
        .{},
    );
    defer window.destroy();

    // Create renderer
    const renderer = try sdl.createRenderer(window, null, .{
        .accelerated = true,
        .present_vsync = true,
    });
    defer renderer.destroy();

    // Create SDL texture for video frames
    const texture = try sdl.createTexture(
        renderer,
        .rgb24,
        .streaming,
        @intCast(width),
        @intCast(height),
    );
    defer texture.destroy();

    // Calculate destination rectangle to maintain aspect ratio
    const dest_rect = calculateAspectRatioRect(window_width, window_height, @intCast(width), @intCast(height));

    // Frame buffer for BGR conversion
    const row_stride = @as(usize, @intCast(width)) * 3;
    const frame_size = @as(usize, @intCast(height)) * row_stride;
    const frame_buffer = try allocator.alloc(u8, frame_size);
    defer allocator.free(frame_buffer);

    var running = true;
    var frame_count: usize = 0;

    if (mpeg.video_decoder) |video_decoder| {
        const video_reader = mpeg.video_reader;
        const packet_type = mpeg.video_packet_type;

        var demux_done = false;

        while (running) {
            // Handle events
            while (sdl.pollEvent()) |ev| {
                switch (ev) {
                    .quit => running = false,
                    .key_down => |key| {
                        if (key.scancode == .escape) {
                            running = false;
                        }
                    },
                    else => {},
                }
            }

            // Try to decode a frame
            if (video_decoder.decode()) |frame| {
                // Convert frame to BGR
                const frame_view: *const zmpeg.Frame = @ptrCast(frame);
                frameToBgr(frame_view, frame_buffer, row_stride);

                // Update SDL texture with frame data
                try texture.update(frame_buffer, row_stride, null);

                // Clear screen
                try renderer.setColorRGB(0, 0, 0);
                try renderer.clear();

                // Render the texture
                try renderer.copy(texture, null, dest_rect);
                renderer.present();

                frame_count += 1;
                std.debug.print("Frame {d} displayed\n", .{frame_count});

                // Small delay to control playback speed (roughly 25 FPS)
                sdl.delay(40);
                continue;
            }

            // If no frame available, try to get more data
            if (demux_done) break;
            const packet = mpeg.demux.decode() orelse {
                demux_done = true;
                if (video_reader) |reader| {
                    reader.signalEnd();
                }
                continue;
            };

            if (packet_type) |ptype| {
                if (packet.type == ptype) {
                    if (video_reader) |reader| {
                        reader.append(packet.data) catch break;
                    } else {
                        video_decoder.reader.append(packet.data) catch break;
                    }
                }
            }
        }
    }

    std.debug.print("Playback complete. Total frames: {d}\n", .{frame_count});
}

fn calculateAspectRatioRect(window_w: i32, window_h: i32, texture_w: i32, texture_h: i32) sdl.Rectangle {
    const window_aspect = @as(f32, @floatFromInt(window_w)) / @as(f32, @floatFromInt(window_h));
    const texture_aspect = @as(f32, @floatFromInt(texture_w)) / @as(f32, @floatFromInt(texture_h));

    var dest_rect: sdl.Rectangle = undefined;
    if (window_aspect > texture_aspect) {
        dest_rect.height = window_h;
        dest_rect.width = @intFromFloat(@as(f32, @floatFromInt(window_h)) * texture_aspect);
        dest_rect.x = @divExact(window_w - dest_rect.width, 2);
        dest_rect.y = 0;
    } else {
        dest_rect.width = window_w;
        dest_rect.height = @intFromFloat(@as(f32, @floatFromInt(window_w)) / texture_aspect);
        dest_rect.x = 0;
        dest_rect.y = @divExact(window_h - dest_rect.height, 2);
    }
    return dest_rect;
}
