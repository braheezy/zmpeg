const std = @import("std");
const demux_mod = @import("demux.zig");
const BitReader = @import("bitreader.zig").BitReader;
const Demux = demux_mod.Demux;
const Video = @import("video.zig").Video;
const types = @import("types.zig");
const PacketType = types.PacketType;

pub const Mpeg = struct {
    allocator: std.mem.Allocator,

    demux: *Demux,
    source_reader: *BitReader,
    owns_source_reader: bool = false,
    time: f64 = 0,
    has_ended: bool = false,
    loop: bool = false,
    has_decoders: bool = false,

    video_enabled: bool = true,
    video_packet_type: ?PacketType = null,
    video_reader: ?*BitReader = null,
    video_decoder: ?*Video = null,

    audio_enabled: bool = true,
    audio_packet_type: ?PacketType = null,
    audio_stream_index: u8 = 0,

    pub fn init(allocator: std.mem.Allocator, reader: *BitReader) !*Mpeg {
        const self = try allocator.create(Mpeg);
        self.* = .{
            .allocator = allocator,
            .demux = try Demux.init(allocator, reader),
            .source_reader = reader,
            .owns_source_reader = false,
        };

        _ = try self.initDecoders();
        return self;
    }

    pub fn deinit(self: *Mpeg) void {
        self.demux.deinit(self.allocator);
        if (self.video_decoder) |decoder| {
            decoder.deinit();
            self.allocator.destroy(decoder);
        }
        if (self.video_reader) |reader| {
            reader.deinit();
            self.allocator.destroy(reader);
        }
        self.video_reader = null;
        if (self.owns_source_reader) {
            self.source_reader.deinit();
            self.allocator.destroy(self.source_reader);
        }
        self.allocator.destroy(self);
    }

    pub fn setAudio(self: *Mpeg, enabled: bool) void {
        self.audio_enabled = enabled;

        if (!enabled) {
            self.audio_packet_type = null;
            return;
        }

        // self.audio_packet_type =
    }

    pub fn getWidth(self: *Mpeg) i32 {
        if (self.video_decoder == null) {
            return 0;
        }
        return self.video_decoder.?.getWidth();
    }

    pub fn getHeight(self: *Mpeg) i32 {
        if (self.video_decoder == null) {
            return 0;
        }
        return self.video_decoder.?.height;
    }

    fn initDecoders(self: *Mpeg) !bool {
        if (self.has_decoders) {
            return true;
        }

        if (!(try self.demux.hasHeaders())) {
            return false;
        }

        if (self.demux.getNumVideoStreams() > 0) {
            if (self.video_enabled) {
                self.video_packet_type = PacketType.video1;
            }
            if (self.video_decoder == null) {
                const reader_ptr = try self.ensureVideoReader();
                try self.ensureVideoSequenceHeader(reader_ptr);
                self.video_decoder = try Video.init(
                    self.allocator,
                    reader_ptr,
                    false,
                );
                try self.primeVideoDecoder();
            }
        } else {
            @panic("No video streams");
        }

        if (self.demux.getNumAudioStreams() > 0) {
            if (self.audio_enabled) {
                const base: u8 = @intFromEnum(PacketType.audio1);
                const idx: u8 = base + self.audio_stream_index;
                self.audio_packet_type = @enumFromInt(idx);
            } else {
                self.audio_packet_type = null;
            }

            // if (self.audio_decoder == null) {
            // self.audio_buffer = try self.allocator.alloc(u8, DEFAULT_BUFFER_SIZE);
            // self.audio_reader = BitReader.initFromMemory(self.allocator, self.audio_buffer.?);
            // self.audio_decoder = try Audio.init(
            //     self.allocator,
            //     &self.audio_reader,
            //     true,
            // );
            // }
        }

        self.has_decoders = true;
        return true;
    }

    fn ensureVideoReader(self: *Mpeg) !*BitReader {
        if (self.video_reader) |reader| {
            return reader;
        }
        const reader_ptr = try self.allocator.create(BitReader);
        reader_ptr.* = try BitReader.initAppend(self.allocator, 64 * 1024);
        self.video_reader = reader_ptr;
        return reader_ptr;
    }

    fn primeVideoDecoder(self: *Mpeg) !void {
        if (self.video_decoder == null) return;
        const decoder = self.video_decoder.?;
        const reader = decoder.reader;
        var attempts: usize = 0;
        while (!decoder.ensurePictureStart()) {
            if (attempts >= 128) return error.MissingSequenceHeader;
            const packet = self.demux.decode() orelse return error.MissingSequenceHeader;
            if (packet.type == self.video_packet_type.?) {
                if (self.video_reader) |video_reader| {
                    try video_reader.append(packet.data);
                    video_reader.seekTo(0);
                } else {
                    try reader.append(packet.data);
                    reader.seekTo(0);
                }
            }
            attempts += 1;
        }
    }

    fn ensureVideoSequenceHeader(self: *Mpeg, reader: *BitReader) !void {
        if (self.video_packet_type == null) return;
        reader.seekTo(0);
        const seq_code: u8 = @intCast(@intFromEnum(types.StartCode.sequence));
        const pic_code: u8 = @intCast(@intFromEnum(types.StartCode.picture));
        while (!reader.hasStartCode(seq_code)) {
            const packet = self.demux.decode() orelse return error.MissingSequenceHeader;
            if (packet.type == self.video_packet_type.?) {
                try reader.append(packet.data);
                reader.seekTo(0);
            }
        }
        while (!reader.hasStartCode(pic_code)) {
            const packet = self.demux.decode() orelse return error.MissingSequenceHeader;
            if (packet.type == self.video_packet_type.?) {
                try reader.append(packet.data);
                reader.seekTo(0);
            }
        }
        reader.seekTo(0);
    }
};
