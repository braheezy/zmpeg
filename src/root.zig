const std = @import("std");

const types = @import("types.zig");
const bitreader_mod = @import("bitreader.zig");
const demux_mod = @import("demux.zig");
const mpeg_mod = @import("mpeg.zig");

pub const BitReader = bitreader_mod.BitReader;
pub const Demux = demux_mod.Demux;

pub const Mpeg = mpeg_mod.Mpeg;

pub fn createFromFile(allocator: std.mem.Allocator, path: []const u8) !*Mpeg {
    const reader_ptr = try allocator.create(BitReader);
    errdefer allocator.destroy(reader_ptr);

    reader_ptr.* = try BitReader.initFromFile(allocator, path);
    errdefer reader_ptr.deinit();

    const mpeg = try Mpeg.init(allocator, reader_ptr);
    mpeg.owns_source_reader = true;
    return mpeg;
}

pub fn createFromMemory(allocator: std.mem.Allocator, data: []const u8) !*Mpeg {
    var reader = BitReader.initFromMemory(allocator, data);
    errdefer reader.deinit();
    return try Mpeg.init(allocator, &reader);
}

pub fn createWithReader(allocator: std.mem.Allocator, reader: *BitReader) !*Mpeg {
    return Mpeg.init(allocator, reader);
}

pub const PLM_PACKET_INVALID_TS = types.PLM_PACKET_INVALID_TS;
pub const Packet = types.Packet;
pub const Plane = types.Plane;
pub const Frame = types.Frame;
pub const SAMPLES_PER_FRAME = types.SAMPLES_PER_FRAME;
pub const Samples = types.Samples;
pub const PacketType = types.PacketType;
pub const PictureType = types.PictureType;
pub const StartCode = types.StartCode;
pub const Vlc = types.Vlc;
pub const VlcUint = types.VlcUint;

test "all" {
    @import("std").testing.refAllDecls(@This());
}
