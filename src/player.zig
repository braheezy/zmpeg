const std = @import("std");
const zmpeg = @import("root.zig");

/// High-level player that handles A/V synchronization automatically
pub const Player = struct {
    mpeg: *zmpeg.Mpeg,

    // Timing state
    playback_time: f64 = 0,
    audio_lead_time: f64 = 0.25,

    // Video state
    pending_frame: ?*const zmpeg.Frame = null,
    demux_done: bool = false,

    // Callbacks
    video_callback: ?VideoCallback = null,
    audio_callback: ?AudioCallback = null,
    video_userdata: ?*anyopaque = null,
    audio_userdata: ?*anyopaque = null,

    // Timing constants
    const video_present_slack: f64 = 0.02;
    const video_drop_margin: f64 = 0.5;
    const video_decode_ahead: f64 = 0.6;
    const audio_decode_ahead: f64 = 0.25;

    pub const VideoCallback = *const fn (player: *Player, frame: *const zmpeg.Frame, userdata: ?*anyopaque) void;
    pub const AudioCallback = *const fn (player: *Player, samples: *const zmpeg.Samples, userdata: ?*anyopaque) void;

    pub fn init(mpeg: *zmpeg.Mpeg) Player {
        return .{
            .mpeg = mpeg,
        };
    }

    pub fn setVideoCallback(self: *Player, callback: VideoCallback, userdata: ?*anyopaque) void {
        self.video_callback = callback;
        self.video_userdata = userdata;
    }

    pub fn setAudioCallback(self: *Player, callback: AudioCallback, userdata: ?*anyopaque) void {
        self.audio_callback = callback;
        self.audio_userdata = userdata;
    }

    pub fn setAudioLeadTime(self: *Player, seconds: f64) void {
        self.audio_lead_time = seconds;
    }

    pub fn getTime(self: *const Player) f64 {
        return self.playback_time;
    }

    pub fn hasEnded(self: *const Player) bool {
        return self.demux_done and
            (self.mpeg.video_decoder == null or self.pending_frame == null) and
            (self.mpeg.audio_decoder == null);
    }

    /// Decode video and audio for the given elapsed time
    /// Calls video_callback and audio_callback as frames are decoded
    pub fn decode(self: *Player, elapsed: f64, audio_queued_seconds: f64) !void {
        const target_time = self.playback_time + elapsed;

        // Compute master clock (playback time adjusted by audio queue)
        var master_clock = self.playback_time;
        if (self.mpeg.audio_decoder != null) {
            master_clock = self.playback_time - audio_queued_seconds;
            if (master_clock < 0) master_clock = 0;
        }

        var decoded_any = false;
        var decode_audio_failed = false;
        var decode_video_failed = false;

        while (true) {
            var did_decode = false;

            // Decode audio up to target
            if (self.mpeg.audio_decoder) |audio| {
                const audio_target = target_time + self.audio_lead_time + audio_decode_ahead;

                while (audio.time < audio_target) {
                    const maybe_samples = audio.decode() catch |err| {
                        std.debug.print("Audio decode error: {}\n", .{err});
                        decode_audio_failed = true;
                        break;
                    };

                    if (maybe_samples) |samples| {
                        if (self.audio_callback) |callback| {
                            callback(self, samples, self.audio_userdata);
                        }

                        if (self.mpeg.audio_reader) |reader| {
                            reader.discardReadBytes();
                        }

                        did_decode = true;
                        decoded_any = true;
                        decode_audio_failed = false;
                    } else {
                        decode_audio_failed = true;
                        break;
                    }
                }
            }

            // Handle pending video frame
            if (self.pending_frame) |frame| {
                const present_threshold = master_clock + video_present_slack;
                const drop_threshold = master_clock - video_drop_margin;

                if (frame.time < drop_threshold) {
                    // Drop late frame
                    self.pending_frame = null;
                    did_decode = true;
                    decoded_any = true;
                    continue;
                }

                if (frame.time <= present_threshold) {
                    // Present frame
                    if (self.video_callback) |callback| {
                        callback(self, frame, self.video_userdata);
                    }
                    self.pending_frame = null;
                    did_decode = true;
                    decoded_any = true;
                    continue;
                }
            }

            // Decode video
            if (self.mpeg.video_decoder) |video| {
                const decode_limit = master_clock + video_decode_ahead;

                if (self.pending_frame == null and video.time <= decode_limit) {
                    const maybe_frame = video.decode();
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
        self.playback_time = target_time;
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
