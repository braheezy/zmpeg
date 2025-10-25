const std = @import("std");
const builtin = @import("builtin");
const zmpeg = @import("zmpeg");
const sdl = @import("sdl2");
const c = sdl.c;

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const App = struct {
    allocator: std.mem.Allocator,
    player: zmpeg.Player,
    window: sdl.Window,
    renderer: sdl.Renderer,
    texture: sdl.Texture,
    audio_device: ?sdl.AudioDevice = null,
    audio_sample_rate: u32 = 0,
    last_time: f64 = 0,
    wants_to_quit: bool = false,

    fn init(allocator: std.mem.Allocator, path: []const u8) !*App {
        var mpeg = try zmpeg.createFromFile(allocator, path);
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

        const self = try allocator.create(App);
        self.* = .{
            .allocator = allocator,
            .player = zmpeg.Player.init(mpeg),
            .window = window,
            .renderer = renderer,
            .texture = texture,
            .last_time = @as(f64, @floatFromInt(sdl.getTicks64())) / 1000.0,
        };

        // Set callbacks
        self.player.setVideoCallback(onVideo, self);
        self.player.setAudioCallback(onAudio, self);

        return self;
    }

    fn deinit(self: *App) void {
        if (self.audio_device) |device| device.close();
        self.texture.destroy();
        self.renderer.destroy();
        self.window.destroy();
        sdl.quit();
        self.player.mpeg.deinit();
        self.allocator.destroy(self);
    }

    fn update(self: *App) !void {
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

        // Calculate elapsed time (limit to 1/30th second max)
        const current_time = @as(f64, @floatFromInt(sdl.getTicks64())) / 1000.0;
        var elapsed = current_time - self.last_time;
        if (elapsed > 1.0 / 30.0) elapsed = 1.0 / 30.0;
        self.last_time = current_time;

        // Get audio queue state for sync
        const audio_queued = if (self.audio_device) |device| blk: {
            const queued_bytes = device.getQueuedAudioSize();
            const bytes_per_sample: f64 = 4.0 * 2.0; // f32 * 2 channels
            const samples = @as(f64, @floatFromInt(queued_bytes)) / bytes_per_sample;
            const rate = @as(f64, @floatFromInt(self.audio_sample_rate));
            break :blk samples / rate;
        } else 0.0;

        // Decode - the Player handles all timing internally!
        try self.player.decode(elapsed, audio_queued);

        // Check if done
        if (self.player.hasEnded()) {
            // Wait for remaining audio to finish
            if (self.audio_device) |device| {
                if (device.getQueuedAudioSize() > 0) {
                    sdl.delay(10);
                    return;
                }
            }
            self.wants_to_quit = true;
        }
    }

    // Callback for decoded video frames
    fn onVideo(_: *zmpeg.Player, frame: *const zmpeg.Frame, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));
        self.presentFrame(frame) catch |err| {
            std.debug.print("Failed to present frame: {}\n", .{err});
        };
    }

    // Callback for decoded audio samples
    fn onAudio(player: *zmpeg.Player, samples: *const zmpeg.Samples, userdata: ?*anyopaque) void {
        const self: *App = @ptrCast(@alignCast(userdata.?));

        // Initialize audio device on first audio
        if (self.audio_device == null) {
            if (player.mpeg.audio_decoder) |audio| {
                const sample_rate = audio.getSamplerate();
                self.audio_device = self.initAudio(sample_rate) catch |err| {
                    std.debug.print("Failed to init audio: {}\n", .{err});
                    return;
                };
                self.audio_sample_rate = sample_rate;
            }
        }

        // Queue audio
        if (self.audio_device) |device| {
            const sample_count: usize = @intCast(samples.count);
            const bytes = std.mem.sliceAsBytes(samples.interleaved[0 .. sample_count * 2]);
            device.queueAudio(bytes) catch |err| {
                std.debug.print("Failed to queue audio: {}\n", .{err});
            };
        }
    }

    fn initAudio(self: *App, sample_rate: u32) !sdl.AudioDevice {
        const desired_spec: sdl.AudioSpecRequest = .{
            .sample_rate = @intCast(sample_rate),
            .buffer_format = sdl.AudioFormat.f32,
            .channel_count = 2,
            .buffer_size_in_frames = 4096,
            .callback = null,
            .userdata = null,
        };

        const result = try sdl.openAudioDevice(.{ .desired_spec = desired_spec });
        std.debug.print("Audio: {d}Hz\n", .{result.obtained_spec.sample_rate});

        // Set audio lead time based on buffer size
        const lead = @as(f64, @floatFromInt(result.obtained_spec.buffer_size_in_frames)) /
            @as(f64, @floatFromInt(result.obtained_spec.sample_rate));
        self.player.setAudioLeadTime(lead);

        result.device.pause(false);
        return result.device;
    }

    fn presentFrame(self: *App, frame: *const zmpeg.Frame) !void {
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

    if (args.len < 2) {
        std.debug.print("Usage: player <video-file.mpg>\n", .{});
        return error.MissingArgument;
    }

    var app = try App.init(allocator, args[1]);
    defer app.deinit();

    while (!app.wants_to_quit) {
        try app.update();
    }

    std.debug.print("Playback complete.\n", .{});
}
