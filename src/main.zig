const std = @import("std");
const builtin = @import("builtin");
const zmpeg = @import("zmpeg");
const sdl = @import("sdl2");
const c = sdl.c;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const AudioOutput = struct {
    device: sdl.AudioDevice,
    sample_rate: u32,
    bytes_per_frame: usize,
    min_queue_bytes: usize,
    lead_time: f64,
    started: bool = false,

    fn init(sample_rate: u32, buffer_frames: u16) !AudioOutput {
        const desired_spec: sdl.AudioSpecRequest = .{
            .sample_rate = @intCast(sample_rate),
            .buffer_format = sdl.AudioFormat.f32,
            .channel_count = 2,
            .buffer_size_in_frames = buffer_frames,
            .callback = null,
            .userdata = null,
        };

        const result = try sdl.openAudioDevice(.{ .desired_spec = desired_spec });

        std.debug.print(
            "Audio device opened: {d}Hz, format={any}, channels={d}\n",
            .{ result.obtained_spec.sample_rate, result.obtained_spec.buffer_format, result.obtained_spec.channel_count },
        );

        const channels: usize = @intCast(result.obtained_spec.channel_count);
        const sample_bits: usize = @intCast(result.obtained_spec.buffer_format.sample_length_bits);
        const bytes_per_sample = sample_bits / 8;
        const bytes_per_frame = channels * bytes_per_sample;
        const frame_bytes = zmpeg.SAMPLES_PER_FRAME * bytes_per_frame;

        var self = AudioOutput{
            .device = result.device,
            .sample_rate = @intCast(result.obtained_spec.sample_rate),
            .bytes_per_frame = bytes_per_frame,
            .min_queue_bytes = @max(frame_bytes * 6, buffer_frames * bytes_per_frame),
            .lead_time = @as(f64, @floatFromInt(buffer_frames)) / @as(f64, @floatFromInt(sample_rate)),
            .started = false,
        };

        // Ensure minimum lead time
        if (self.lead_time < 0.18) {
            self.lead_time = 0.18;
        }

        self.device.pause(true);
        return self;
    }

    fn deinit(self: *AudioOutput) void {
        self.device.close();
    }

    fn queue(self: *AudioOutput, samples: *const zmpeg.Samples) !void {
        const sample_count: usize = @intCast(samples.count);
        const source = std.mem.sliceAsBytes(samples.interleaved[0 .. sample_count * 2]);
        try self.device.queueAudio(source);

        if (!self.started and self.device.getQueuedAudioSize() >= self.min_queue_bytes / 2) {
            self.device.pause(false);
            self.started = true;
        }
    }

    fn needsMoreAudio(self: *const AudioOutput) bool {
        return self.device.getQueuedAudioSize() < self.min_queue_bytes;
    }

    fn queuedSeconds(self: *const AudioOutput) f64 {
        const queued_bytes = self.device.getQueuedAudioSize();
        const queued_f = @as(f64, @floatFromInt(queued_bytes));
        const frame_bytes_f = @as(f64, @floatFromInt(self.bytes_per_frame));
        const frames = queued_f / frame_bytes_f;
        return frames / @as(f64, @floatFromInt(self.sample_rate));
    }
};

const Player = struct {
    allocator: std.mem.Allocator,
    mpeg: *zmpeg.Mpeg,
    window: sdl.Window,
    renderer: sdl.Renderer,
    texture: sdl.Texture,
    audio_output: ?AudioOutput = null,

    playback_time: f64 = 0,
    last_ticks: u64,
    pending_frame: ?*const zmpeg.Frame = null,
    demux_done: bool = false,
    wants_to_quit: bool = false,

    // Timing constants
    const max_tick_step: f64 = 1.0 / 30.0;
    const video_present_slack: f64 = 0.02;
    const video_drop_margin: f64 = 0.5;
    const video_decode_ahead: f64 = 0.6;
    const audio_decode_ahead: f64 = 0.25;

    fn init(allocator: std.mem.Allocator, mpeg_path: []const u8) !*Player {
        var mpeg = try zmpeg.createFromFile(allocator, mpeg_path);
        errdefer mpeg.deinit();

        const width = mpeg.getWidth();
        const height = mpeg.getHeight();
        if (width <= 0 or height <= 0) return error.InvalidVideoDimensions;

        std.debug.print("Video: {d}x{d}\n", .{ width, height });

        try sdl.init(.{ .video = true, .audio = true });
        errdefer sdl.quit();

        const window = try sdl.createWindow(
            "ZMPEG Player",
            .centered,
            .centered,
            @intCast(width),
            @intCast(height),
            .{},
        );
        errdefer window.destroy();

        const renderer = try sdl.createRenderer(window, null, .{
            .accelerated = true,
            .present_vsync = true,
        });
        errdefer renderer.destroy();

        const texture = try sdl.createTexture(
            renderer,
            .iyuv,
            .streaming,
            @intCast(width),
            @intCast(height),
        );
        errdefer texture.destroy();

        const self = try allocator.create(Player);
        self.* = .{
            .allocator = allocator,
            .mpeg = mpeg,
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .last_ticks = sdl.getTicks64(),
        };

        return self;
    }

    fn deinit(self: *Player) void {
        if (self.audio_output) |*output| output.deinit();
        self.texture.destroy();
        self.renderer.destroy();
        self.window.destroy();
        sdl.quit();
        self.mpeg.deinit();
        self.allocator.destroy(self);
    }

    fn update(self: *Player) !void {
        // Handle events
        while (sdl.pollEvent()) |ev| {
            switch (ev) {
                .quit => self.wants_to_quit = true,
                .key_down => |key| {
                    if (key.scancode == .escape) self.wants_to_quit = true;
                },
                else => {},
            }
        }

        // Calculate elapsed time
        const current_ticks = sdl.getTicks64();
        const delta_ticks = current_ticks - self.last_ticks;
        self.last_ticks = current_ticks;
        var elapsed = @as(f64, @floatFromInt(delta_ticks)) / 1000.0;
        if (elapsed > max_tick_step) elapsed = max_tick_step;

        const target_time = self.playback_time + elapsed;

        // Compute master clock (audio if available, otherwise playback time)
        var master_clock = target_time;
        var audio_lead: f64 = 0.1;

        if (self.audio_output) |*output| {
            audio_lead = output.lead_time;
            if (output.started) {
                const audio_decoder = self.mpeg.audio_decoder orelse unreachable;
                const audio_clock = audio_decoder.time - output.queuedSeconds();
                if (audio_clock > 0) {
                    master_clock = audio_clock;
                }
            }
        }

        // Decode loop
        var decoded_any = false;
        var decode_audio_failed = false;
        var decode_video_failed = false;

        while (true) {
            var did_decode = false;

            // Decode audio
            if (self.mpeg.audio_decoder) |audio_decoder| {
                const audio_target = if (self.audio_output != null and self.audio_output.?.started)
                    master_clock + audio_lead + audio_decode_ahead
                else
                    self.playback_time + audio_lead + audio_decode_ahead;

                while (audio_decoder.time < audio_target or
                    (self.audio_output != null and self.audio_output.?.needsMoreAudio()))
                {
                    const maybe_samples = audio_decoder.decode() catch |err| {
                        std.debug.print("Audio decode error: {}\n", .{err});
                        decode_audio_failed = true;
                        break;
                    };

                    if (maybe_samples) |samples| {
                        // Initialize audio output on first decode
                        if (self.audio_output == null) {
                            const sample_rate = audio_decoder.getSamplerate();
                            self.audio_output = AudioOutput.init(sample_rate, 4096) catch |err| {
                                std.debug.print("Failed to init audio: {}\n", .{err});
                                break;
                            };
                        }

                        if (self.audio_output) |*output| {
                            try output.queue(samples);
                        }

                        if (self.mpeg.audio_reader) |reader| {
                            reader.discardReadBytes();
                        }

                        did_decode = true;
                        decoded_any = true;
                        decode_audio_failed = false;

                        if (self.audio_output) |*output| {
                            if (!output.needsMoreAudio() and audio_decoder.time >= audio_target) {
                                break;
                            }
                        } else break;
                    } else {
                        decode_audio_failed = true;
                        break;
                    }
                }
            }

            // Handle pending video frame
            if (self.pending_frame) |frame_data| {
                const present_threshold = if (self.audio_output != null and self.audio_output.?.started)
                    master_clock + video_present_slack
                else
                    self.playback_time + video_present_slack;

                const drop_threshold = if (self.audio_output != null and self.audio_output.?.started)
                    master_clock - video_drop_margin
                else
                    self.playback_time - 0.1;

                if (frame_data.time < drop_threshold) {
                    // Drop late frame
                    self.pending_frame = null;
                    did_decode = true;
                    decoded_any = true;
                    continue;
                }

                if (frame_data.time <= present_threshold) {
                    // Present frame
                    try self.presentFrame(frame_data);
                    self.pending_frame = null;
                    did_decode = true;
                    decoded_any = true;
                    continue;
                }
            }

            // Decode video
            if (self.mpeg.video_decoder) |video_decoder| {
                const decode_limit = if (self.audio_output != null and self.audio_output.?.started)
                    master_clock + video_decode_ahead
                else
                    self.playback_time + video_decode_ahead;

                if (self.pending_frame == null and video_decoder.time <= decode_limit) {
                    const maybe_frame = video_decoder.decode();
                    if (maybe_frame) |frame| {
                        self.pending_frame = @ptrCast(frame);
                        did_decode = true;
                        decoded_any = true;
                        decode_video_failed = false;
                        continue;
                    } else {
                        decode_video_failed = true;
                    }
                }
            }

            // Feed more packets if needed
            const need_video = self.mpeg.video_decoder != null and decode_video_failed;
            const need_audio = self.mpeg.audio_decoder != null and decode_audio_failed;

            if (!self.demux_done and (need_video or need_audio)) {
                if (!self.feedPackets(need_video, need_audio)) {
                    break;
                }
                decode_video_failed = false;
                decode_audio_failed = false;
                continue;
            }

            if (!did_decode) break;
        }

        // Update playback time
        if (self.audio_output) |*output| {
            if (output.started) {
                const audio_decoder = self.mpeg.audio_decoder orelse unreachable;
                const audio_clock = audio_decoder.time - output.queuedSeconds();
                if (audio_clock > 0) {
                    self.playback_time = audio_clock;
                } else {
                    self.playback_time = target_time;
                }
            } else {
                self.playback_time = target_time;
            }
        } else {
            self.playback_time = target_time;
        }

        // Check if playback ended
        if (self.demux_done and
            (self.mpeg.video_decoder == null or decode_video_failed) and
            (self.mpeg.audio_decoder == null or decode_audio_failed))
        {
            // Wait for audio to finish
            if (self.audio_output) |*output| {
                if (output.device.getQueuedAudioSize() > 0) {
                    sdl.delay(10);
                    return;
                }
            }
            self.wants_to_quit = true;
        }

        // Small delay if nothing was decoded
        if (!decoded_any and self.pending_frame == null) {
            sdl.delay(1);
        }
    }

    fn presentFrame(self: *Player, frame: *const zmpeg.Frame) !void {
        const y_pitch: c_int = @intCast(frame.y.width);
        const cb_pitch: c_int = @intCast(frame.cb.width);
        const cr_pitch: c_int = @intCast(frame.cr.width);
        const y_ptr: [*c]const u8 = @ptrCast(frame.y.data.ptr);
        const cb_ptr: [*c]const u8 = @ptrCast(frame.cb.data.ptr);
        const cr_ptr: [*c]const u8 = @ptrCast(frame.cr.data.ptr);

        if (c.SDL_UpdateYUVTexture(
            self.texture.ptr,
            null,
            y_ptr,
            y_pitch,
            cb_ptr,
            cb_pitch,
            cr_ptr,
            cr_pitch,
        ) != 0) {
            return error.TextureUpdateFailed;
        }

        try self.renderer.copy(self.texture, null, null);
        self.renderer.present();
    }

    fn feedPackets(self: *Player, want_video: bool, want_audio: bool) bool {
        if (self.demux_done or (!want_video and !want_audio)) return false;

        var need_video = want_video;
        var need_audio = want_audio;

        while (need_video or need_audio) {
            const packet = self.mpeg.demux.decode() orelse {
                self.demux_done = true;
                if (self.mpeg.video_reader) |reader| reader.signalEnd();
                if (self.mpeg.audio_reader) |reader| reader.signalEnd();
                return false;
            };

            if (self.mpeg.video_packet_type) |vtype| {
                if (packet.type == vtype) {
                    if (self.mpeg.video_reader) |reader| {
                        reader.append(packet.data) catch return false;
                    } else if (self.mpeg.video_decoder) |decoder| {
                        decoder.reader.append(packet.data) catch return false;
                    }
                    if (need_video) need_video = false;
                }
            }

            if (self.mpeg.audio_packet_type) |atype| {
                if (packet.type == atype) {
                    if (self.mpeg.audio_reader) |reader| {
                        reader.append(packet.data) catch return false;
                    }
                    if (need_audio) need_audio = false;
                }
            }
        }

        return true;
    }
};

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

    // Parse arguments
    var input_path: ?[]const u8 = null;
    var run_test_pattern = false;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--test-pattern")) {
            run_test_pattern = true;
        } else if (arg.len > 0 and arg[0] != '-') {
            input_path = arg;
        }
    }

    if (input_path == null) {
        std.debug.print("Usage: player <video-file.mpg>\n", .{});
        std.debug.print("       player --test-pattern\n", .{});
        return error.MissingArgument;
    }

    // Create and run player
    var player = try Player.init(allocator, input_path.?);
    defer player.deinit();

    while (!player.wants_to_quit) {
        try player.update();
    }

    std.debug.print("Playback complete.\n", .{});
}
