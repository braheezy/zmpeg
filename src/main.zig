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
            if (c_index >= cr_data.len or c_index >= cb_data.len) break;

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
    var test_audio_packets: ?usize = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (arg.len > 0 and arg[0] != '-') {
            input_path = arg;
        } else if (std.mem.startsWith(u8, arg, "--test-audio=")) {
            const num_str = arg["--test-audio=".len..];
            test_audio_packets = std.fmt.parseInt(usize, num_str, 10) catch {
                std.debug.print("Invalid number for --test-audio\n", .{});
                return error.InvalidArgument;
            };
        }
    }

    // Initialize MPEG decoder
    var mpeg = try zmpeg.createFromFile(allocator, input_path);
    defer mpeg.deinit();

    const width = mpeg.getWidth();
    const height = mpeg.getHeight();

    std.debug.print("width: {d}, height: {d}\n", .{ width, height });
    if (width <= 0 or height <= 0) return;

    // Initialize SDL
    try sdl.init(.{
        .video = test_audio_packets == null,
        .audio = true,
    });
    defer sdl.quit();

    // Skip SDL resources in test mode
    const window_width = 800;
    const window_height = 600;

    const window = if (test_audio_packets == null) try sdl.createWindow(
        "ZMPEG Video Player",
        .centered,
        .centered,
        window_width,
        window_height,
        .{},
    ) else undefined;
    defer if (test_audio_packets == null) window.destroy();

    // Create renderer
    const renderer = if (test_audio_packets == null) try sdl.createRenderer(window, null, .{
        .accelerated = true,
        .present_vsync = true,
    }) else undefined;
    defer if (test_audio_packets == null) renderer.destroy();

    // Create SDL texture for video frames
    const texture = if (test_audio_packets == null) try sdl.createTexture(
        renderer,
        .rgb24,
        .streaming,
        @intCast(width),
        @intCast(height),
    ) else undefined;
    defer if (test_audio_packets == null) texture.destroy();

    // Calculate destination rectangle to maintain aspect ratio
    const dest_rect = if (test_audio_packets == null) calculateAspectRatioRect(window_width, window_height, @intCast(width), @intCast(height)) else undefined;

    // Frame buffer for BGR conversion
    const row_stride = @as(usize, @intCast(width)) * 3;
    const frame_size = @as(usize, @intCast(height)) * row_stride;
    var dummy_buffer: [1]u8 = .{0};
    const frame_buffer = if (test_audio_packets == null) try allocator.alloc(u8, frame_size) else dummy_buffer[0..];
    defer if (test_audio_packets == null) allocator.free(frame_buffer);

    // Audio device will be initialized once we decode the first audio header
    var audio_device: ?sdl.AudioDevice = null;
    defer if (audio_device) |device| device.close();

    var running = true;
    var audio_packet_count: usize = 0;

    if (mpeg.video_decoder) |video_decoder| {
        const video_reader = mpeg.video_reader;
        const packet_type = mpeg.video_packet_type;

        var demux_done = false;

        while (running) {
            // Handle events (skip in test mode)
            if (test_audio_packets == null) {
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
            }

            // Try to decode a frame (skip rendering in test mode)
            if (video_decoder.decode()) |frame| {
                if (test_audio_packets == null) {
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

                    // Small delay to control playback speed (roughly 25 FPS)
                    sdl.delay(40);
                }
                continue;
            }

            // If no frame available, try to get more data
            if (demux_done) {
                continue;
            }
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

            // Handle audio packets
            if (mpeg.audio_packet_type) |aptype| {
                if (packet.type == aptype) {
                    if (mpeg.audio_reader) |reader| {
                        reader.append(packet.data) catch break;

                        // Decode available audio frames
                        if (mpeg.audio_decoder) |audio_decoder| {
                            const is_test_mode = test_audio_packets != null;

                            // Initialize audio device once we have a sample rate (skip in test mode)
                            if (audio_device == null and !is_test_mode) {
                                const sample_rate = audio_decoder.getSamplerate();
                                if (sample_rate > 0) {
                                    std.debug.print("Opening SDL audio: {d} Hz\n", .{sample_rate});
                                    const result = sdl.openAudioDevice(.{
                                        .desired_spec = .{
                                            .sample_rate = @intCast(sample_rate),
                                            .buffer_format = sdl.AudioFormat.f32,
                                            .channel_count = 2,
                                            .buffer_size_in_frames = 4096,
                                            .callback = null,
                                            .userdata = null,
                                        },
                                    }) catch |err| {
                                        std.debug.print("Failed to open audio device: {}\n", .{err});
                                        break;
                                    };
                                    audio_device = result.device;
                                    std.debug.print("SDL audio device opened successfully!\n", .{});
                                    std.debug.print("  Requested: {d} Hz, f32, 2 channels\n", .{sample_rate});
                                    std.debug.print("  Got:       {d} Hz, {any}, {d} channels\n", .{
                                        result.obtained_spec.sample_rate,
                                        result.obtained_spec.buffer_format,
                                        result.obtained_spec.channel_count,
                                    });
                                    audio_device.?.pause(false);
                                    std.debug.print("SDL audio UNPAUSED - should be playing now!\n", .{});
                                }
                            }

                            var frames_decoded_this_packet: usize = 0;
                            var decode_attempts: usize = 0;
                            while (decode_attempts < 10) : (decode_attempts += 1) {
                                const samples = audio_decoder.decode() catch |err| {
                                    std.debug.print("Audio decode error: {}\n", .{err});
                                    break;
                                };
                                if (samples) |s| {
                                    frames_decoded_this_packet += 1;
                                    // In test mode, hash and print
                                    if (is_test_mode) {
                                        const sample_bytes = std.mem.sliceAsBytes(s.interleaved[0..]);
                                        const packet_hash = hashFrame(fnv_offset_basis, sample_bytes);
                                        std.debug.print("Zig audio packet {d} time={d:.6} hash={x:0>16}\n", .{ audio_packet_count, s.time, packet_hash });
                                        audio_packet_count += 1;

                                        if (audio_packet_count >= test_audio_packets.?) {
                                            std.debug.print("audio packets decoded: {d}\n", .{audio_packet_count});
                                            return;
                                        }
                                    } else {
                                        // Queue audio samples to SDL
                                        if (audio_device) |device| {
                                            const sample_count = @as(usize, s.count) * 2;
                                            const active_samples = s.interleaved[0..sample_count];
                                            var max_val: f32 = 0;
                                            for (active_samples) |sample| {
                                                const abs_val = @abs(sample);
                                                if (abs_val > max_val) max_val = abs_val;
                                            }
                                            if (frames_decoded_this_packet <= 3 or max_val > 0.01) {
                                                std.debug.print("Frame {d}: max={d:.6}, samples=[{d:.3}, {d:.3}, {d:.3}, {d:.3}]\n", .{
                                                    frames_decoded_this_packet,
                                                    max_val,
                                                    active_samples[0],
                                                    active_samples[1],
                                                    active_samples[2],
                                                    active_samples[3],
                                                });
                                            }

                                            const sample_bytes = std.mem.sliceAsBytes(active_samples);
                                            const queue_before = device.getQueuedAudioSize();
                                            device.queueAudio(sample_bytes) catch |err| {
                                                std.debug.print("Failed to queue audio: {}\n", .{err});
                                            };
                                            const queue_after = device.getQueuedAudioSize();
                                            if (frames_decoded_this_packet <= 3 or max_val > 0.01) {
                                                std.debug.print("  Queued to SDL: {d} -> {d} bytes\n", .{ queue_before, queue_after });
                                            }
                                        }
                                    }
                                } else {
                                    break;
                                }
                            }
                            if (!is_test_mode and frames_decoded_this_packet > 0) {
                                std.debug.print("Decoded {d} audio frames from packet\n", .{frames_decoded_this_packet});
                            }
                            // Discard consumed audio data
                            reader.discardReadBytes();
                        }
                    }
                }
            }
        }
    }

    std.debug.print("Playback complete.\n", .{});
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
