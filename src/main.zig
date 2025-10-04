const std = @import("std");
const meta = std.meta;
const builtin = @import("builtin");
const zmpeg = @import("zmpeg");
const sdl = @import("sdl2");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const fnv_offset_basis: u64 = 1469598103934665603;
const fnv_prime: u64 = 1099511628211;

var texture_info_logged: bool = false;

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

fn runTestPattern(allocator: std.mem.Allocator) !void {
    const width: i32 = 640;
    const height: i32 = 360;
    const width_usize: usize = @as(usize, @intCast(width));
    const height_usize: usize = @as(usize, @intCast(height));
    const pitch: usize = width_usize * 4;
    const frame_size: usize = pitch * height_usize;

    try sdl.init(.{ .video = true, .audio = false });
    defer sdl.quit();

    var buffer = try allocator.alloc(u8, frame_size);
    defer allocator.free(buffer);

    { // Fill RGBA gradient test pattern.
        var y: usize = 0;
        const denom_x = if (width_usize > 1) width_usize - 1 else 1;
        const denom_y = if (height_usize > 1) height_usize - 1 else 1;

        while (y < height_usize) : (y += 1) {
            var x: usize = 0;
            while (x < width_usize) : (x += 1) {
                const idx = y * pitch + x * 4;
                const r_val = @min(255, (x * 255) / denom_x);
                const g_val = @min(255, (y * 255) / denom_y);
                const r: u8 = @intCast(r_val);
                const g: u8 = @intCast(g_val);
                const checker = ((x / 40) ^ (y / 40)) & 1;
                const b: u8 = if (checker == 0) 64 else 192;
                buffer[idx + 0] = r;
                buffer[idx + 1] = g;
                buffer[idx + 2] = b;
                buffer[idx + 3] = 255;
            }
        }
    }

    const window = try sdl.createWindow(
        "ZMPEG Test Pattern",
        .centered,
        .centered,
        width,
        height,
        .{},
    );
    defer window.destroy();

    const renderer = try sdl.createRenderer(window, null, .{
        .accelerated = true,
        .present_vsync = true,
    });
    defer renderer.destroy();

    const texture = try sdl.createTexture(renderer, .rgba8888, .streaming, width, height);
    defer texture.destroy();

    try texture.update(buffer, pitch, null);
    try renderer.setColorRGB(0, 0, 0);
    try renderer.clear();
    const dest = calculateAspectRatioRect(width, height, width, height);
    try renderer.copy(texture, null, dest);
    renderer.present();

    var running = true;
    while (running) {
        while (sdl.pollEvent()) |ev| {
            switch (ev) {
                .quit => running = false,
                .key_down => |key| {
                    if (key.scancode == .escape) running = false;
                },
                else => {},
            }
        }
        sdl.delay(16);
    }
}

const AudioOutput = struct {
    allocator: std.mem.Allocator,
    device: sdl.AudioDevice,
    spec: sdl.AudioSpecResponse,
    stream: ?sdl.AudioStream = null,
    convert_buffer: []u8 = &[_]u8{},
    started: bool = false,

    fn deinit(self: *AudioOutput) void {
        if (self.stream) |*stream| {
            stream.free();
        }
        if (self.convert_buffer.len > 0) {
            self.allocator.free(self.convert_buffer);
        }
        self.device.close();
    }

    fn queue(self: *AudioOutput, samples: *const zmpeg.Samples) !void {
        const expected_channels: usize = 2;
        const sample_count: usize = @intCast(samples.count);
        const source = std.mem.sliceAsBytes(samples.interleaved[0 .. sample_count * expected_channels]);

        if (self.stream) |*stream| {
            try stream.put(@constCast(source));

            var available_bytes = stream.available();
            while (available_bytes > 0) {
                if (available_bytes > self.convert_buffer.len) {
                    if (self.convert_buffer.len > 0) {
                        self.allocator.free(self.convert_buffer);
                    }
                    self.convert_buffer = try self.allocator.alloc(u8, available_bytes);
                }

                const converted = try stream.get(self.convert_buffer[0..available_bytes]);
                if (converted.len == 0) break;
                try self.device.queueAudio(converted);
                if (!self.started and self.device.getQueuedAudioSize() > 0) {
                    self.device.pause(false);
                    self.started = true;
                }
                available_bytes = stream.available();
            }
        } else {
            try self.device.queueAudio(source);
            if (!self.started and self.device.getQueuedAudioSize() > 0) {
                self.device.pause(false);
                self.started = true;
            }
        }
    }
};

fn bytesPerSample(format: sdl.AudioFormat) usize {
    const bits = @as(usize, format.sample_length_bits);
    return (bits + 7) / 8;
}

fn initAudioOutput(allocator: std.mem.Allocator, sample_rate: u32) !AudioOutput {
    // Ensure the SDL audio subsystem is ready before opening a device. This
    // mirrors what the C reference does and prevents "Audio subsystem is not
    // initialized" errors if SDL was started without the audio flag.
    try sdl.initSubSystem(.{ .audio = true });

    const desired_format = sdl.AudioFormat.f32;
    const desired_channels: u8 = 2;
    const desired_rate: i32 = @intCast(sample_rate);

    const desired_spec: sdl.AudioSpecRequest = .{
        .sample_rate = @intCast(sample_rate),
        .buffer_format = desired_format,
        .channel_count = desired_channels,
        .buffer_size_in_frames = 4096,
        .callback = null,
        .userdata = null,
    };

    const result = sdl.openAudioDevice(.{
        .desired_spec = desired_spec,
        .allowed_changes_from_desired = .{
            .sample_rate = true,
            .buffer_format = true,
            .channel_count = true,
            .buffer_size = true,
        },
    }) catch |err| {
        std.debug.print("Failed to open audio device: {}\n", .{err});
        return err;
    };

    var output = AudioOutput{
        .allocator = allocator,
        .device = result.device,
        .spec = result.obtained_spec,
        .stream = null,
        .convert_buffer = &[_]u8{},
    };

    errdefer output.deinit();

    const use_stream = !meta.eql(result.obtained_spec.buffer_format, desired_format) or
        result.obtained_spec.channel_count != desired_channels or
        result.obtained_spec.sample_rate != desired_rate;

    if (use_stream) {
        output.stream = try sdl.newAudioStream(
            desired_format,
            desired_channels,
            desired_rate,
            result.obtained_spec.buffer_format,
            result.obtained_spec.channel_count,
            result.obtained_spec.sample_rate,
        );

        // Allocate a scratch buffer sized for one decoded frame worth of destination audio.
        const dest_bytes_per_sample = bytesPerSample(result.obtained_spec.buffer_format);
        const dest_channels = @as(usize, result.obtained_spec.channel_count);
        const decoded_frames = @as(usize, zmpeg.SAMPLES_PER_FRAME);
        const safety_factor: usize = 2; // give the resampler headroom
        output.convert_buffer = try allocator.alloc(u8, decoded_frames * dest_channels * dest_bytes_per_sample * safety_factor);
    }

    output.device.pause(true);

    return output;
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
    var run_test_pattern = false;
    var audio_dump_path: ?[]const u8 = null;

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
        } else if (std.mem.startsWith(u8, arg, "--dump-audio=")) {
            audio_dump_path = arg["--dump-audio=".len..];
        } else if (std.mem.eql(u8, arg, "--test-pattern")) {
            run_test_pattern = true;
        }
    }

    if (run_test_pattern) {
        try runTestPattern(allocator);
        return;
    }

    // Initialize MPEG decoder
    var mpeg = try zmpeg.createFromFile(allocator, input_path);
    defer mpeg.deinit();

    const width = mpeg.getWidth();
    const height = mpeg.getHeight();

    std.debug.print("width: {d}, height: {d}\n", .{ width, height });
    if (width <= 0 or height <= 0) return;

    // Initialize SDL
    const enable_audio_playback = audio_dump_path == null;
    var need_video = test_audio_packets == null;
    const need_sdl = need_video or enable_audio_playback;

    const window_width = 800;
    const window_height = 600;
    var dummy_buffer: [1]u8 = .{0};
    var frame_buffer: []u8 = dummy_buffer[0..];
    var row_stride: usize = 0;
    var frame_buffer_allocated = false;
    var window: sdl.Window = undefined;
    var renderer: sdl.Renderer = undefined;
    var texture: sdl.Texture = undefined;
    var window_ready = false;
    var renderer_ready = false;
    var texture_ready = false;
    var dest_rect: sdl.Rectangle = undefined;

    if (need_sdl) {
        try sdl.init(.{
            .video = need_video,
            .audio = enable_audio_playback,
        });
        defer sdl.quit();

        if (need_video) video_init: {
            const created_window = sdl.createWindow(
                "ZMPEG Video Player",
                .centered,
                .centered,
                window_width,
                window_height,
                .{},
            ) catch |err| {
                std.debug.print("Warning: SDL window init failed ({}) – continuing without video.\n", .{err});
                need_video = false;
                break :video_init;
            };
            window = created_window;
            window_ready = true;

            const created_renderer = sdl.createRenderer(window, null, .{
                .accelerated = true,
                .present_vsync = true,
            }) catch |err| {
                std.debug.print("Warning: SDL renderer init failed ({}) – continuing without video.\n", .{err});
                window.destroy();
                window_ready = false;
                need_video = false;
                break :video_init;
            };
            renderer = created_renderer;
            renderer_ready = true;

            const created_texture = sdl.createTexture(
                renderer,
                .rgb24,
                .streaming,
                @intCast(width),
                @intCast(height),
            ) catch |err| {
                std.debug.print("Warning: SDL texture init failed ({}) – continuing without video.\n", .{err});
                renderer.destroy();
                renderer_ready = false;
                window.destroy();
                window_ready = false;
                need_video = false;
                break :video_init;
            };
            texture = created_texture;
            texture_ready = true;

            if (!texture_info_logged) {
                const tex_info_result = sdl.Texture.query(texture);
                if (tex_info_result) |info| {
                    texture_info_logged = true;
                    std.debug.print(
                        "SDL texture created: format={any} access={d} size={d}x{d}\n",
                        .{ info.format, @intFromEnum(info.access), info.width, info.height },
                    );
                } else |err| {
                    std.debug.print("Failed to query texture info: {}\n", .{err});
                }
            }

            dest_rect = calculateAspectRatioRect(window_width, window_height, @intCast(width), @intCast(height));

            row_stride = @as(usize, @intCast(width)) * 3;
            const frame_size = @as(usize, @intCast(height)) * row_stride;
            frame_buffer = allocator.alloc(u8, frame_size) catch |err| {
                std.debug.print("Warning: failed to allocate video buffer ({}); disabling video.\n", .{err});
                texture.destroy();
                texture_ready = false;
                renderer.destroy();
                renderer_ready = false;
                window.destroy();
                window_ready = false;
                need_video = false;
                break :video_init;
            };
            frame_buffer_allocated = true;
        }
    }

    defer if (texture_ready) texture.destroy();
    defer if (renderer_ready) renderer.destroy();
    defer if (window_ready) window.destroy();
    defer if (frame_buffer_allocated) allocator.free(frame_buffer);

    // Optional audio dump file
    var audio_dump_file: ?std.fs.File = null;
    if (audio_dump_path) |dump_path| {
        audio_dump_file = std.fs.cwd().createFile(dump_path, .{ .truncate = true }) catch |err| {
            std.debug.print("Failed to open audio dump file {s}: {}\n", .{ dump_path, err });
            return err;
        };
    }
    defer if (audio_dump_file) |*file| file.close();

    // Audio device will be initialized once we decode the first audio header
    var audio_output: ?AudioOutput = null;
    defer if (audio_output) |*output| output.deinit();

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
            const maybe_frame = video_decoder.decode();
            if (need_video) {
                if (maybe_frame) |frame| {
                    if (test_audio_packets == null) {
                        const frame_view: *const zmpeg.Frame = @ptrCast(frame);
                        frameToBgr(frame_view, frame_buffer, row_stride);

                        std.debug.print(
                            "Uploading RGB frame: stride={d} buffer_len={d}\n",
                            .{ row_stride, frame_buffer.len },
                        );

                        texture.update(frame_buffer, row_stride, null) catch |err| {
                            const sdl_err = sdl.getError() orelse "unknown";
                            std.debug.print("Warning: texture update failed ({}): {s}; disabling video.\n", .{ err, sdl_err });
                            if (texture_ready) {
                                texture.destroy();
                                texture_ready = false;
                            }
                            if (renderer_ready) {
                                renderer.destroy();
                                renderer_ready = false;
                            }
                            if (window_ready) {
                                window.destroy();
                                window_ready = false;
                            }
                            if (frame_buffer_allocated) {
                                allocator.free(frame_buffer);
                                frame_buffer_allocated = false;
                                frame_buffer = dummy_buffer[0..];
                            }
                            need_video = false;
                            continue;
                        };

                        renderer.setColorRGB(0, 0, 0) catch |err| {
                            const sdl_err = sdl.getError() orelse "unknown";
                            std.debug.print(
                                "Warning: renderer setColor failed ({}): {s}; disabling video.\n",
                                .{ err, sdl_err },
                            );
                            if (renderer_ready) {
                                renderer.destroy();
                                renderer_ready = false;
                            }
                            if (window_ready) {
                                window.destroy();
                                window_ready = false;
                            }
                            if (texture_ready) {
                                texture.destroy();
                                texture_ready = false;
                            }
                            if (frame_buffer_allocated) {
                                allocator.free(frame_buffer);
                                frame_buffer_allocated = false;
                                frame_buffer = dummy_buffer[0..];
                            }
                            need_video = false;
                            continue;
                        };

                        renderer.clear() catch |err| {
                            const sdl_err = sdl.getError() orelse "unknown";
                            std.debug.print(
                                "Warning: renderer clear failed ({}): {s}; disabling video.\n",
                                .{ err, sdl_err },
                            );
                            if (renderer_ready) {
                                renderer.destroy();
                                renderer_ready = false;
                            }
                            if (window_ready) {
                                window.destroy();
                                window_ready = false;
                            }
                            if (texture_ready) {
                                texture.destroy();
                                texture_ready = false;
                            }
                            if (frame_buffer_allocated) {
                                allocator.free(frame_buffer);
                                frame_buffer_allocated = false;
                                frame_buffer = dummy_buffer[0..];
                            }
                            need_video = false;
                            continue;
                        };

                        renderer.copy(texture, null, dest_rect) catch |err| {
                            const sdl_err = sdl.getError() orelse "unknown";
                            std.debug.print(
                                "Warning: renderer copy failed ({}): {s}; disabling video.\n",
                                .{ err, sdl_err },
                            );
                            if (renderer_ready) {
                                renderer.destroy();
                                renderer_ready = false;
                            }
                            if (window_ready) {
                                window.destroy();
                                window_ready = false;
                            }
                            if (texture_ready) {
                                texture.destroy();
                                texture_ready = false;
                            }
                            if (frame_buffer_allocated) {
                                allocator.free(frame_buffer);
                                frame_buffer_allocated = false;
                                frame_buffer = dummy_buffer[0..];
                            }
                            need_video = false;
                            continue;
                        };

                        renderer.present();

                        // Small delay to control playback speed (roughly 25 FPS)
                        sdl.delay(40);
                    }
                    continue;
                }
            } else if (maybe_frame != null) {
                continue;
            }

            // If no frame available, try to get more data
            if (demux_done) {
                if (audio_output) |*output| {
                    const remaining = output.device.getQueuedAudioSize();
                    if (remaining > 0) {
                        sdl.delay(10);
                        continue;
                    }
                }
                running = false;
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
                            // One-time SDL audio device initialization
                            if (enable_audio_playback and audio_output == null) {
                                const sample_rate = audio_decoder.getSamplerate();
                                if (sample_rate > 0) {
                                    audio_output = initAudioOutput(allocator, sample_rate) catch |err| {
                                        std.debug.print("Failed to initialise audio output: {}\n", .{err});
                                        break;
                                    };
                                }
                            }

                            while (true) {
                                const maybe_samples = audio_decoder.decode() catch |err| {
                                    std.debug.print("Audio decode error: {}\n", .{err});
                                    break;
                                };
                                if (maybe_samples) |samples| {
                                    if (audio_dump_file) |*file| {
                                        const bytes = std.mem.sliceAsBytes(samples.interleaved[0 .. samples.count * 2]);
                                        file.writeAll(bytes) catch |err| {
                                            std.debug.print("Failed to write audio dump: {}\n", .{err});
                                        };
                                    }
                                    if (audio_output) |*output| {
                                        output.queue(samples) catch |err| {
                                            std.debug.print("Failed to queue audio: {}\n", .{err});
                                        };
                                    }
                                    if (test_audio_packets != null) {
                                        const sample_bytes = std.mem.sliceAsBytes(samples.interleaved[0 .. samples.count * 2]);
                                        const packet_hash = hashFrame(fnv_offset_basis, sample_bytes);
                                        std.debug.print("Zig audio packet {d} time={d:.6} hash={x:0>16}\n", .{ audio_packet_count, samples.time, packet_hash });
                                        audio_packet_count += 1;
                                        if (audio_packet_count >= test_audio_packets.?) {
                                            std.debug.print("audio packets decoded: {d}\n", .{audio_packet_count});
                                            return;
                                        }
                                    }
                                } else break;
                            }

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
