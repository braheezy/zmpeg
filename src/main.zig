const std = @import("std");
const meta = std.meta;
const builtin = @import("builtin");
const zmpeg = @import("zmpeg");
const sdl = @import("sdl2");
const c = sdl.c;
const BitReader = zmpeg.BitReader;

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
    start_threshold_bytes: usize,
    min_queue_bytes: usize,
    bytes_per_frame: usize,
    lead_seconds: f64,
    started: bool = false,
    sample_rate: usize,

    fn deinit(self: *AudioOutput) void {
        self.device.close();
    }

    fn queue(self: *AudioOutput, samples: *const zmpeg.Samples) !usize {
        const expected_channels: usize = 2;
        const sample_count: usize = @intCast(samples.count);
        const source = std.mem.sliceAsBytes(samples.interleaved[0 .. sample_count * expected_channels]);
        try self.device.queueAudio(source);
        const queued = self.device.getQueuedAudioSize();
        if (!self.started and queued >= self.start_threshold_bytes) {
            self.device.pause(false);
            self.started = true;
        }
        return queued;
    }

    fn needsMoreAudio(self: *AudioOutput) bool {
        return self.device.getQueuedAudioSize() < self.min_queue_bytes;
    }

    fn queuedSeconds(self: *AudioOutput) f64 {
        if (self.bytes_per_frame == 0 or self.sample_rate == 0) return 0;
        const queued_bytes = self.device.getQueuedAudioSize();
        const queued_f = @as(f64, @floatFromInt(queued_bytes));
        const frame_bytes_f = @as(f64, @floatFromInt(self.bytes_per_frame));
        const frames = queued_f / frame_bytes_f;
        return frames / @as(f64, @floatFromInt(self.sample_rate));
    }

    fn leadTime(self: *const AudioOutput) f64 {
        return self.lead_seconds;
    }
};

const PumpResult = struct {
    need_more_audio: bool = false,
    need_more_data: bool = false,
    decoded_samples: bool = false,
    test_done: bool = false,
};

fn pumpAudio(
    audio_decoder: *zmpeg.Audio,
    reader: *BitReader,
    audio_output: ?*AudioOutput,
    audio_dump_file: ?*std.fs.File,
    audio_dump_path: ?[]const u8,
    test_audio_packets: ?usize,
    audio_packet_count: *usize,
    log_audio: bool,
    target_time: ?f64,
) PumpResult {
    var result = PumpResult{};
    var need_more_bits = false;

    while (true) {
        if (target_time) |limit| {
            if (audio_decoder.time >= limit and (audio_output == null or !audio_output.?.needsMoreAudio())) {
                break;
            }
        }

        const maybe_samples = audio_decoder.decode() catch |err| {
            std.debug.print("Audio decode error: {}\n", .{err});
            break;
        };
        if (maybe_samples) |samples| {
            result.decoded_samples = true;
            if (audio_dump_file) |file| {
                const bytes = std.mem.sliceAsBytes(samples.interleaved[0 .. samples.count * 2]);
                file.writeAll(bytes) catch |err| {
                    std.debug.print("Failed to write audio dump: {}\n", .{err});
                };
            }

            var queued_after: usize = 0;
            if (audio_output) |output| {
                queued_after = output.queue(samples) catch |err| {
                    std.debug.print("Failed to queue audio: {}\n", .{err});
                    return result;
                };
                if (audio_dump_path == null) {
                    result.need_more_audio = output.needsMoreAudio();
                }
            }

            if (test_audio_packets != null) {
                const sample_bytes = std.mem.sliceAsBytes(samples.interleaved[0 .. samples.count * 2]);
                const packet_hash = hashFrame(fnv_offset_basis, sample_bytes);
                std.debug.print("Zig audio packet {d} time={d:.6} hash={x:0>16}\n", .{ audio_packet_count.*, samples.time, packet_hash });
                audio_packet_count.* += 1;
                if (audio_packet_count.* >= test_audio_packets.?) {
                    std.debug.print("audio packets decoded: {d}\n", .{audio_packet_count.*});
                    result.test_done = true;
                    break;
                }
            }

            if (log_audio) {
                const buffered = reader.reader.end - reader.reader.seek;
                std.debug.print(
                    "audio pump: queued={d} need_more={} buffered={d}\n",
                    .{ queued_after, result.need_more_audio, buffered },
                );
            }

            if (target_time) |limit| {
                if (audio_decoder.time >= limit) break;
            } else if (audio_output != null and audio_dump_path == null and !result.need_more_audio) {
                break;
            }
        } else {
            need_more_bits = true;
            break;
        }
    }

    reader.discardReadBytes();

    if (need_more_bits) {
        result.need_more_data = true;
    }

    if (audio_output) |output| {
        if (audio_dump_path == null) {
            result.need_more_audio = output.needsMoreAudio();
            if (log_audio) {
                const queued = output.device.getQueuedAudioSize();
                const buffered = reader.reader.end - reader.reader.seek;
                std.debug.print(
                    "audio queue: queued={d} need_more={} buffered={d}\n",
                    .{ queued, result.need_more_audio, buffered },
                );
            }
        }
    } else if (log_audio) {
        const buffered = reader.reader.end - reader.reader.seek;
        std.debug.print("audio queue: queued=0 need_more={} buffered={d}\n", .{ result.need_more_audio, buffered });
    }

    return result;
}

fn bytesPerSample(format: sdl.AudioFormat) usize {
    const bits = @as(usize, format.sample_length_bits);
    return (bits + 7) / 8;
}

fn initAudioOutput(allocator: std.mem.Allocator, sample_rate: u32) !AudioOutput {
    const desired_spec: sdl.AudioSpecRequest = .{
        .sample_rate = @intCast(sample_rate),
        .buffer_format = sdl.AudioFormat.f32,
        .channel_count = 2,
        .buffer_size_in_frames = 4096,
        .callback = null,
        .userdata = null,
    };

    const result = sdl.openAudioDevice(.{
        .desired_spec = desired_spec,
    }) catch |err| {
        std.debug.print("Failed to open audio device: {}\n", .{err});
        return err;
    };

    std.debug.print(
        "SDL audio device: freq={d} format={any} channels={d}\n",
        .{ result.obtained_spec.sample_rate, result.obtained_spec.buffer_format, result.obtained_spec.channel_count },
    );

    var output = AudioOutput{
        .allocator = allocator,
        .device = result.device,
        .spec = result.obtained_spec,
        .start_threshold_bytes = 0,
        .min_queue_bytes = 0,
        .bytes_per_frame = 0,
        .lead_seconds = 0,
        .sample_rate = 0,
    };

    errdefer output.deinit();

    const channels = @as(usize, result.obtained_spec.channel_count);
    const bytes_per_sample = bytesPerSample(result.obtained_spec.buffer_format);
    output.bytes_per_frame = channels * bytes_per_sample;
    const frame_bytes: usize = zmpeg.SAMPLES_PER_FRAME * output.bytes_per_frame;
    output.start_threshold_bytes = frame_bytes * 4; // ≈92ms at 44.1k to avoid early underruns
    const base_frames = @as(usize, @max(result.obtained_spec.buffer_size_in_frames, 2048));
    output.min_queue_bytes = @max(frame_bytes * 6, base_frames * channels * bytes_per_sample);
    output.sample_rate = if (result.obtained_spec.sample_rate > 0)
        @as(usize, @intCast(result.obtained_spec.sample_rate))
    else
        @as(usize, @intCast(sample_rate));

    if (output.bytes_per_frame > 0 and output.sample_rate > 0) {
        const rate_f = @as(f64, @floatFromInt(output.sample_rate));
        const buffer_frames = @as(f64, @floatFromInt(result.obtained_spec.buffer_size_in_frames));
        output.lead_seconds = if (buffer_frames > 0)
            buffer_frames / rate_f
        else
            @as(f64, @floatFromInt(output.start_threshold_bytes)) /
                (@as(f64, @floatFromInt(output.bytes_per_frame)) * rate_f);
    } else {
        output.lead_seconds = 0;
    }
    if (output.lead_seconds < 0.18) {
        output.lead_seconds = 0.18;
    }

    output.device.pause(true);

    return output;
}

fn computeAudioClock(audio_decoder: *zmpeg.Audio, audio_output: ?*AudioOutput) f64 {
    const decoder_time = audio_decoder.time;
    if (audio_output) |output| {
        const queued = output.queuedSeconds();
        if (decoder_time >= queued) {
            return decoder_time - queued;
        }
        return 0;
    }
    return decoder_time;
}

fn feedPackets(
    mpeg: *zmpeg.Mpeg,
    want_video: bool,
    want_audio: bool,
    demux_done: *bool,
) bool {
    if (demux_done.* or (!want_video and !want_audio)) return false;

    var need_video = want_video;
    var need_audio = want_audio;

    while (need_video or need_audio) {
        const packet = mpeg.demux.decode() orelse {
            demux_done.* = true;
            if (mpeg.video_reader) |reader| reader.signalEnd();
            if (mpeg.audio_reader) |reader| reader.signalEnd();
            return false;
        };

        if (mpeg.video_packet_type) |ptype| {
            if (packet.type == ptype) {
                if (mpeg.video_reader) |reader| {
                    reader.append(packet.data) catch |err| {
                        std.debug.print("Failed to append video packet: {}\n", .{err});
                        demux_done.* = true;
                        return false;
                    };
                } else if (mpeg.video_decoder) |decoder| {
                    decoder.reader.append(packet.data) catch |err| {
                        std.debug.print("Failed to append video packet: {}\n", .{err});
                        demux_done.* = true;
                        return false;
                    };
                }
                if (need_video) {
                    need_video = false;
                }
            }
        }

        if (mpeg.audio_packet_type) |aptype| {
            if (packet.type == aptype) {
                if (mpeg.audio_reader) |reader| {
                    reader.append(packet.data) catch |err| {
                        std.debug.print("Failed to append audio packet: {}\n", .{err});
                        demux_done.* = true;
                        return false;
                    };
                }
                if (need_audio) {
                    need_audio = false;
                }
            }
        }
    }

    return true;
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
    var capture_audio_frame: ?usize = null;
    var capture_audio_prefix: ?[]const u8 = null;
    var log_audio_state = false;
    var log_sync_state = false;

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
        } else if (std.mem.startsWith(u8, arg, "--capture-audio-frame=")) {
            const num_str = arg["--capture-audio-frame=".len..];
            capture_audio_frame = std.fmt.parseInt(usize, num_str, 10) catch {
                std.debug.print("Invalid number for --capture-audio-frame\n", .{});
                return error.InvalidArgument;
            };
        } else if (std.mem.startsWith(u8, arg, "--capture-audio-prefix=")) {
            capture_audio_prefix = arg["--capture-audio-prefix=".len..];
        } else if (std.mem.eql(u8, arg, "--test-pattern")) {
            run_test_pattern = true;
        } else if (std.mem.eql(u8, arg, "--log-audio")) {
            log_audio_state = true;
        } else if (std.mem.eql(u8, arg, "--log-sync")) {
            log_sync_state = true;
        }
    }

    if (run_test_pattern) {
        try runTestPattern(allocator);
        return;
    }

    // Initialize MPEG decoder
    var mpeg = try zmpeg.createFromFile(allocator, input_path);
    defer mpeg.deinit();

    if (capture_audio_frame != null and capture_audio_prefix != null) {
        if (mpeg.audio_decoder) |decoder| {
            decoder.setDebugCapture(.{
                .frame_index = capture_audio_frame.?,
                .prefix = capture_audio_prefix.?,
            });
        }
    }

    const width = mpeg.getWidth();
    const height = mpeg.getHeight();

    std.debug.print("width: {d}, height: {d}\n", .{ width, height });
    if (width <= 0 or height <= 0) return;

    // Initialize SDL
    const enable_audio_playback = audio_dump_path == null;
    var need_video = test_audio_packets == null;
    const need_sdl = need_video or enable_audio_playback;

    const window_width: usize = @as(usize, @intCast(width));
    const window_height: usize = @as(usize, @intCast(height));
    var window: sdl.Window = undefined;
    var renderer: sdl.Renderer = undefined;
    var texture: sdl.Texture = undefined;
    var window_ready = false;
    var renderer_ready = false;
    var texture_ready = false;
    const dest_rect: sdl.Rectangle = .{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    };

    var sdl_initialized = false;
    defer if (sdl_initialized) sdl.quit();

    if (need_sdl) {
        try sdl.init(.{
            .video = need_video,
            .audio = enable_audio_playback,
        });
        sdl_initialized = true;

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
                .iyuv,
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
        }
    }

    defer if (texture_ready) texture.destroy();
    defer if (renderer_ready) renderer.destroy();
    defer if (window_ready) window.destroy();

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
    const max_tick_step: f64 = 1.0 / 30.0;
    var playback_time: f64 = 0;
    var last_ticks: u64 = sdl.getTicks64();
    var last_video_time: f64 = 0;
    var sync_log_accum: f64 = 0;
    var dropped_frames: usize = 0;
    const video_present_slack: f64 = 0.02;
    const video_drop_margin: f64 = 0.5;
    const video_decode_ahead: f64 = 0.6;
    const audio_decode_ahead: f64 = 0.25;
    var pending_frame: ?*const zmpeg.Frame = null;

    if (mpeg.video_decoder) |video_decoder| {
        var demux_done = false;

        while (running) {
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

            const current_ticks = sdl.getTicks64();
            const delta_ticks = current_ticks - last_ticks;
            last_ticks = current_ticks;
            var elapsed = @as(f64, @floatFromInt(delta_ticks)) / 1000.0;
            if (elapsed > max_tick_step) elapsed = max_tick_step;

            const target_time = playback_time + elapsed;
            var master_clock = target_time;
            var audio_clock = playback_time;
            var audio_lead: f64 = 0.1;

            var decode_audio_failed = false;
            var decode_video_failed = false;
            var presented_frame = false;
            var decoded_any = false;

            if (mpeg.audio_decoder) |audio_decoder| {
                if (audio_output) |*out| {
                    audio_lead = out.leadTime();
                }
                const computed_clock = computeAudioClock(audio_decoder, if (audio_output) |*out| out else null);
                audio_clock = computed_clock;
            }

            if (audio_output != null and audio_output.?.started and audio_clock > 0) {
                master_clock = audio_clock;
            }
            if (master_clock < playback_time) {
                master_clock = playback_time;
            }

            var audio_target_time = if (audio_output != null and audio_output.?.started)
                master_clock + audio_lead + audio_decode_ahead
            else
                playback_time + audio_lead + audio_decode_ahead;
            if (mpeg.audio_decoder != null and audio_output != null and audio_output.?.needsMoreAudio()) {
                audio_target_time += audio_lead;
            }
            const present_threshold = if (audio_output != null and audio_output.?.started)
                master_clock + video_present_slack
            else
                playback_time + video_present_slack;
            const drop_threshold = if (audio_output != null and audio_output.?.started)
                master_clock - video_drop_margin
            else
                playback_time - 0.1;
            const decode_limit = if (audio_output != null and audio_output.?.started)
                master_clock + video_decode_ahead
            else
                playback_time + video_decode_ahead;

            while (true) {
                var did_decode = false;
                decode_audio_failed = false;
                decode_video_failed = false;

                if (mpeg.audio_decoder) |audio_decoder| {
                    const need_more_audio = if (audio_output) |*out| out.needsMoreAudio() else false;
                    if (audio_decoder.time < audio_target_time or need_more_audio) {
                        const maybe_samples = audio_decoder.decode() catch |err| {
                            std.debug.print("Audio decode error: {}\n", .{err});
                            decode_audio_failed = true;
                            break;
                        };

                        if (maybe_samples) |samples| {
                            if (audio_dump_file) |file| {
                                const bytes = std.mem.sliceAsBytes(samples.interleaved[0 .. samples.count * 2]);
                                file.writeAll(bytes) catch |err| {
                                    std.debug.print("Failed to write audio dump: {}\n", .{err});
                                };
                            }

                            if (enable_audio_playback and audio_output == null) {
                                const sample_rate = audio_decoder.getSamplerate();
                                if (sample_rate > 0) {
                                    audio_output = initAudioOutput(allocator, sample_rate) catch |err| {
                                        std.debug.print("Failed to initialise audio output: {}\n", .{err});
                                        break;
                                    };
                                }
                            }

                            if (audio_output) |*output| {
                                const queued_after = output.queue(samples) catch |err| {
                                    std.debug.print("Failed to queue audio: {}\n", .{err});
                                    running = false;
                                    break;
                                };
                                if (log_audio_state) {
                                    std.debug.print("audio queue enqueue queued={d}\n", .{queued_after});
                                }
                            }

                            if (test_audio_packets) |limit| {
                                const sample_bytes = std.mem.sliceAsBytes(samples.interleaved[0 .. samples.count * 2]);
                                const packet_hash = hashFrame(fnv_offset_basis, sample_bytes);
                                std.debug.print(
                                    "Zig audio packet {d} time={d:.6} hash={x:0>16}\n",
                                    .{ audio_packet_count, samples.time, packet_hash },
                                );
                                audio_packet_count += 1;
                                if (audio_packet_count >= limit) {
                                    std.debug.print("audio packets decoded: {d}\n", .{audio_packet_count});
                                    return;
                                }
                            }

                            did_decode = true;
                            decoded_any = true;
                            decode_audio_failed = false;
                            if (mpeg.audio_reader) |audio_reader| {
                                audio_reader.discardReadBytes();
                            }

                            if (audio_output) |*output| {
                                _ = output;
                            }
                        } else {
                            decode_audio_failed = true;
                        }
                    }
                }

                if (pending_frame) |frame_data| {
                    if (frame_data.time < drop_threshold) {
                        pending_frame = null;
                        dropped_frames += 1;
                        did_decode = true;
                        decoded_any = true;
                        continue;
                    }

                    if (test_audio_packets == null and frame_data.time <= present_threshold) {
                        const y_pitch: c_int = @intCast(frame_data.y.width);
                        const cb_pitch: c_int = @intCast(frame_data.cb.width);
                        const cr_pitch: c_int = @intCast(frame_data.cr.width);
                        const y_ptr: [*c]const u8 = @ptrCast(frame_data.y.data.ptr);
                        const cb_ptr: [*c]const u8 = @ptrCast(frame_data.cb.data.ptr);
                        const cr_ptr: [*c]const u8 = @ptrCast(frame_data.cr.data.ptr);
                        if (c.SDL_UpdateYUVTexture(
                            texture.ptr,
                            null,
                            y_ptr,
                            y_pitch,
                            cb_ptr,
                            cb_pitch,
                            cr_ptr,
                            cr_pitch,
                        ) != 0) {
                            const sdl_err = sdl.getError() orelse "unknown";
                            std.debug.print("Warning: texture update failed: {s}; disabling video.\n", .{sdl_err});
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
                            need_video = false;
                            pending_frame = null;
                            break;
                        }

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
                            need_video = false;
                            pending_frame = null;
                            break;
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
                            need_video = false;
                            pending_frame = null;
                            break;
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
                            need_video = false;
                            pending_frame = null;
                            break;
                        };

                        renderer.present();
                        last_video_time = frame_data.time;
                        pending_frame = null;
                        presented_frame = true;
                        did_decode = true;
                        decoded_any = true;
                        continue;
                    }
                }

                if (need_video) {
                    const should_decode = pending_frame == null and video_decoder.time <= decode_limit;
                    if (should_decode) {
                        const maybe_frame = video_decoder.decode();
                        if (maybe_frame) |frame| {
                            pending_frame = @ptrCast(frame);
                            did_decode = true;
                            decoded_any = true;
                            decode_video_failed = false;
                            continue;
                        } else {
                            decode_video_failed = true;
                        }
                    }
                }

                const need_video_packets = need_video and !demux_done and decode_video_failed;
                const need_audio_packets = (mpeg.audio_decoder != null) and !demux_done and decode_audio_failed;
                if (need_video_packets or need_audio_packets) {
                    if (!feedPackets(mpeg, need_video_packets, need_audio_packets, &demux_done)) {
                        break;
                    }
                    decode_video_failed = false;
                    decode_audio_failed = false;
                    continue;
                }

                if (!did_decode) {
                    break;
                }
            }

            playback_time = target_time;
            sync_log_accum += elapsed;

            if ((!need_video or decode_video_failed) and
                (mpeg.audio_decoder == null or decode_audio_failed) and
                demux_done)
            {
                running = false;
                continue;
            }

            var current_master = master_clock;
            if (mpeg.audio_decoder) |audio_decoder| {
                audio_clock = computeAudioClock(audio_decoder, if (audio_output) |*out| out else null);
                if (audio_output != null and audio_output.?.started and audio_clock > 0) {
                    current_master = audio_clock;
                }
            }

            playback_time = current_master;

            if (log_sync_state and sync_log_accum >= 1.0) {
                sync_log_accum = 0;
                const queued_bytes = if (audio_output) |*out| out.device.getQueuedAudioSize() else 0;
                std.debug.print(
                    "sync: master={d:.3} video={d:.3} audio={d:.3} queued={d} dropped={d}\n",
                    .{ current_master, last_video_time, audio_clock, queued_bytes, dropped_frames },
                );
            }

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

            if (!presented_frame and !decoded_any) {
                sdl.delay(1);
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
