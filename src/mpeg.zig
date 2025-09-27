const std = @import("std");
const types = @import("types.zig");
const bitreader_mod = @import("bitreader.zig");
const demux_mod = @import("demux.zig");

const BitReader = bitreader_mod.BitReader;
const Demux = demux_mod.Demux;

pub const Mpeg = struct {
    allocator: std.mem.Allocator,
    reader: BitReader,
    demux: *Demux,

    time: f64 = 0,
    has_ended: bool = false,
    loop_playback: bool = false,
    has_decoders: bool = false,

    video_enabled: bool = true,
    video_packet_type: types.PacketType = .video1,
    video_decoder: ?*anyopaque = null,

    audio_enabled: bool = true,
    audio_stream_index: u8 = 0,
    audio_packet_type: types.PacketType = .audio1,
    audio_lead_time: f64 = 0,
    audio_decoder: ?*anyopaque = null,

    pub fn createFromFile(allocator: std.mem.Allocator, filename: []const u8) !Mpeg {
        var reader = try BitReader.initFromFile(allocator, filename);
        return Mpeg.createWithReader(allocator, reader) catch |err| {
            reader.deinit();
            return err;
        };
    }

    pub fn createFromMemory(allocator: std.mem.Allocator, data: []const u8) !Mpeg {
        var reader = BitReader.initFromMemory(allocator, data);
        return Mpeg.createWithReader(allocator, reader) catch |err| {
            reader.deinit();
            return err;
        };
    }

    pub fn createWithReader(allocator: std.mem.Allocator, reader: BitReader) !Mpeg {
        var video = Mpeg{
            .allocator = allocator,
            .reader = reader,
            .demux = undefined,
        };
        errdefer video.reader.deinit();
        video.demux = try Demux.init(allocator, &video.reader);

        return video;
    }

    pub fn deinit(self: *Mpeg) void {
        self.demux.deinit(self.allocator);
        self.reader.deinit();
    }
};
