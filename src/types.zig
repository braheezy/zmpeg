const std = @import("std");

pub const PLM_PACKET_INVALID_TS = -1;

pub const Packet = struct {
    type: PacketType = .private,
    pts: f64 = 0,
    length: usize = 0,
    data: []const u8 = &[_]u8{},
};

pub const Plane = struct {
    width: u32 = 0,
    height: u32 = 0,
    data: []u8 = undefined,
};

pub const Frame = struct {
    time: f64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    y: Plane = .{},
    cr: Plane = .{},
    cb: Plane = .{},
};

pub const SAMPLES_PER_FRAME = 1152;

pub const Samples = struct {
    time: f64,
    count: u32,
    left: [SAMPLES_PER_FRAME]f32 = undefined,
    right: [SAMPLES_PER_FRAME]f32 = undefined,
    interleaved: [SAMPLES_PER_FRAME * 2]f32 = undefined,
};

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

    pub fn fromInt(value: i32) !StartCode {
        return @enumFromInt(value);
    }
};

pub const Vlc = struct {
    index: i16 = 0,
    value: i16 = 0,
};

pub const VlcUint = struct {
    index: i16,
    value: u16,
};

test "types" {
    std.testing.refAllDecls(@This());
}
