const std = @import("std");

pub const BitReader = @import("bitreader.zig");
const demux_mod = @import("demux.zig");
pub const Demux = demux_mod.Demux;

// Demuxed MPEG PS packet
// The type maps directly to the various MPEG-PES start codes. PTS is the
// presentation time stamp of the packet in seconds. Note that not all packets
// have a PTS value, indicated by PLM_PACKET_INVALID_TS.
pub const PLM_PACKET_INVALID_TS = -1;

pub const Packet = struct {
    type: PacketType = .private,
    pts: f64 = 0,
    length: usize = 0,
    data: []const u8 = &[_]u8{},
};

// Decoded Video Plane
// The byte length of the data is width * height. Note that different planes
// have different sizes: the Luma plane (Y) is double the size of each of
// the two Chroma planes (Cr, Cb) - i.e. 4 times the byte length.
// Also note that the size of the plane does *not* denote the size of the
// displayed frame. The sizes of planes are always rounded up to the nearest
// macroblock (16px).
pub const Plane = struct {
    width: u32 = 0,
    height: u32 = 0,
    data: []const u8 = undefined,
};

// Decoded Video Frame
// width and height denote the desired display size of the frame. This may be
// different from the internal size of the 3 planes.
pub const Frame = struct {
    time: f64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    y: Plane,
    cr: Plane,
    cb: Plane,
};

// Decoded Audio Samples
// Samples are stored as normalized (-1, 1) float either interleaved, or if
// PLM_AUDIO_SEPARATE_CHANNELS is defined, in two separate arrays.
// The `count` is always PLM_AUDIO_SAMPLES_PER_FRAME and just there for
// convenience.
pub const SAMPLES_PER_FRAME = 1152;

pub const Samples = struct {
    time: f64,
    count: u32,
    left: ?[]const f32 = null,
    right: ?[]const f32 = null,
    interleaved: ?[]const f32 = null,
};

// High-level main video struct
pub const Video = struct {
    allocator: std.mem.Allocator,
    reader: BitReader,
    demux: *Demux,

    time: f64 = 0,
    has_ended: bool = false,
    loop_playback: bool = false,
    has_decoders: bool = false,

    video_enabled: bool = true,
    video_packet_type: PacketType = .video1,
    video_decoder: ?*anyopaque = null,

    audio_enabled: bool = true,
    audio_stream_index: u8 = 0,
    audio_packet_type: PacketType = .audio1,
    audio_lead_time: f64 = 0,
    audio_decoder: ?*anyopaque = null,

    pub fn createFromFile(allocator: std.mem.Allocator, filename: []const u8) !Video {
        var reader = try BitReader.initFromFile(allocator, filename);
        return Video.createWithReader(allocator, reader) catch |err| {
            reader.deinit();
            return err;
        };
    }

    pub fn createFromMemory(allocator: std.mem.Allocator, data: []const u8) !Video {
        var reader = BitReader.initFromMemory(allocator, data);
        return Video.createWithReader(allocator, reader) catch |err| {
            reader.deinit();
            return err;
        };
    }

    pub fn createWithReader(allocator: std.mem.Allocator, reader: BitReader) !Video {
        var video = Video{
            .allocator = allocator,
            .reader = reader,
            .demux = undefined,
        };
        errdefer video.reader.deinit();
        video.demux = try Demux.init(allocator, &video.reader);

        return video;
    }

    pub fn deinit(self: *Video) void {
        self.demux.deinit(self.allocator);
        self.reader.deinit();
    }
};

// demux public API
// Demux an MPEG Program Stream (PS) data into separate packages

pub const PacketType = enum(i32) {
    private = 0xBD,
    audio1 = 0xC0,
    audio2 = 0xC1,
    audio3 = 0xC2,
    audio4 = 0xC3,
    video1 = 0xE0,
};

pub const PictureType = enum(i32) {
    intra = 1,
    predictive = 2,
    b = 3,
};

pub const StartCode = enum(i32) {
    sequence = 0xB3,
    slice_first = 0x01,
    slice_last = 0xAF,
    picture = 0x00,
    extension = 0xB5,
    user_data = 0xB2,
};

pub const Vlc = struct {
    index: i16,
    value: i16,
};

// TODO: Does this really need to be a separate type? Union?
pub const VlcUint = struct {
    index: i16,
    value: u16,
};

test "all" {
    std.testing.refAllDecls(@This());
}
