const std = @import("std");
const BitReader = @import("bitreader.zig");
const root = @import("root.zig");
const Packet = root.Packet;
const PacketType = root.PacketType;

const START_PACK = 0xBA;
const START_END = 0xB9;
const START_SYSTEM = 0xBB;

pub const Demux = struct {
    reader: *BitReader,
    system_clock_ref: f64 = 0,

    start_time: f64 = root.PLM_PACKET_INVALID_TS,
    duration: f64 = root.PLM_PACKET_INVALID_TS,

    start_code: ?PacketType = null,
    has_pack_header: bool = false,
    has_system_header: bool = false,
    has_headers: bool = false,

    last_file_size: usize = 0,
    last_decoded_pts: f64 = root.PLM_PACKET_INVALID_TS,

    num_audio_streams: u32 = 0,
    num_video_streams: u32 = 0,
    current_packet: Packet = .{ .data = &[_]u8{}, .length = 0 },
    next_packet: Packet = .{ .data = &[_]u8{}, .length = 0 },

    pub fn init(allocator: std.mem.Allocator, reader: *BitReader) !*Demux {
        const self = try allocator.create(Demux);
        self.* = .{
            .reader = reader,
        };

        _ = try self.hasHeaders();
        return self;
    }

    pub fn deinit(self: *Demux, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }

    fn hasHeaders(self: *Demux) !bool {
        if (self.has_headers) return true;

        // decode pack header
        if (!self.has_pack_header) {
            if (self.reader.findStartCode(START_PACK) == null) {
                return false;
            }
            if (!(self.reader.has(64) catch false)) return false;

            if ((self.reader.readBits(4) catch return false) != 0x02) return false;

            self.system_clock_ref = self.decodeTime();
            self.reader.skip(1);
            self.reader.skip(22); // mux_rate * 50
            self.reader.skip(1);

            self.has_pack_header = true;
        }

        // Decode system header
        if (!self.has_system_header) {
            if (self.reader.findStartCode(START_SYSTEM) == null) {
                return false;
            }
            if (!(self.reader.has(56) catch false)) return false;

            // header_length
            self.reader.skip(16);
            // rate bound
            self.reader.skip(24);
            self.num_audio_streams = try self.reader.readBits(6);
            // misc flags
            self.reader.skip(5);
            self.num_video_streams = try self.reader.readBits(5);

            self.has_system_header = true;
        }
        self.has_headers = true;
        return true;
    }

    fn decodeTime(self: *Demux) f64 {
        var clock: i64 = (self.reader.readBits(3) catch 0) << 30;
        self.reader.skip(1);
        clock |= (self.reader.readBits(15) catch 0) << 15;
        self.reader.skip(1);
        clock |= (self.reader.readBits(15) catch 0);
        self.reader.skip(1);
        return @as(f64, @floatFromInt(clock)) / 90000.0;
    }

    fn probe(self: *Demux, probesize: usize) bool {
        const previous_pos = self.reader.tell();

        var video_stream: bool = false;
        var audio_streams = [_]bool{ false, false, false, false };
        while (true) {
            const code_opt = self.reader.nextStartCode();
            if (code_opt == null) break;
            const code_byte: u8 = code_opt.?;
            if (code_byte == @intFromEnum(PacketType.video1)) {
                video_stream = true;
                self.start_code = .video1;
            } else if (code_byte >= @intFromEnum(PacketType.audio1) and code_byte <= @intFromEnum(PacketType.audio4)) {
                const idx: usize = @intCast(code_byte - @intFromEnum(PacketType.audio1));
                audio_streams[idx] = true;
                self.start_code = @enumFromInt(code_byte);
            } else {
                self.start_code = null;
            }

            if ((self.reader.tell() - previous_pos) >= probesize) break;
        }

        self.num_video_streams = if (video_stream) 1 else 0;
        self.num_audio_streams = 0;
        var i: usize = 0;
        while (i < audio_streams.len) : (i += 1) {
            if (audio_streams[i]) self.num_audio_streams += 1;
        }

        self.seek(previous_pos);
        return (self.num_video_streams != 0 or self.num_audio_streams != 0);
    }

    fn getNumVideoStreams(self: *Demux) u32 {
        if (self.has_headers) return self.num_video_streams else 0;
    }

    fn getNumAudioStreams(self: *Demux) u32 {
        if (self.has_headers) return self.num_audio_streams else 0;
    }

    fn rewind(self: *Demux) void {
        self.reader.seekTo(0);
        self.current_packet = .{ .type = .private, .pts = root.PLM_PACKET_INVALID_TS, .length = 0, .data = &[_]u8{} };
        self.next_packet = .{ .type = .private, .pts = root.PLM_PACKET_INVALID_TS, .length = 0, .data = &[_]u8{} };
        self.start_code = null;
    }

    fn hasEnded(self: *Demux) bool {
        return self.reader.hasEnded();
    }

    fn seek(self: *Demux, pos: usize) void {
        self.reader.seekTo(pos);
        self.current_packet = .{ .type = .private, .pts = root.PLM_PACKET_INVALID_TS, .length = 0, .data = &[_]u8{} };
        self.next_packet = .{ .type = .private, .pts = root.PLM_PACKET_INVALID_TS, .length = 0, .data = &[_]u8{} };
        self.start_code = null;
    }

    fn decode(self: *Demux) ?*Packet {
        if (!(self.hasHeaders() catch false)) {
            return null;
        }

        if (self.current_packet.length > 0) {
            const bits_till_next_packet = self.current_packet.length << 3;
            if (!(self.reader.has(bits_till_next_packet) catch false)) {
                return null;
            }
            self.reader.skip(bits_till_next_packet);
            self.current_packet.length = 0;
            self.current_packet.data = &[_]u8{};
        }
        // Pending packet waiting for data?
        if (self.next_packet.length > 0) {
            return self.getPacket();
        }

        // Pending packet waiting for header?
        if (self.start_code != null) {
            return self.decodePacket(self.start_code.?);
        }

        while (true) {
            const code_opt = self.reader.nextStartCode();
            if (code_opt == null) break;
            const code_byte: u8 = code_opt.?;
            if (code_byte == @intFromEnum(PacketType.video1) or
                code_byte == @intFromEnum(PacketType.private) or
                (code_byte >= @intFromEnum(PacketType.audio1) and code_byte <= @intFromEnum(PacketType.audio4)))
            {
                self.start_code = @enumFromInt(code_byte);
                return self.decodePacket(self.start_code.?);
            }
        }
        return null;
    }

    fn decodePacket(self: *Demux, packet_type: PacketType) ?*Packet {
        if (!(self.reader.has(16 << 3) catch false)) {
            return null;
        }

        self.start_code = null;
        self.next_packet = .{ .type = packet_type, .pts = root.PLM_PACKET_INVALID_TS, .length = 0, .data = &[_]u8{} };

        const hi = self.reader.readBits(8) catch return null;
        const lo = self.reader.readBits(8) catch return null;
        var remaining = (@as(usize, hi) << 8) | @as(usize, lo);

        remaining -= self.reader.skipBytes(0xff) catch return null; // stuffing

        // skip P-STD (PES optional field)
        const pstd_marker = self.reader.readBits(2) catch return null;
        if (pstd_marker == 0x01) {
            if (!(self.reader.has(16) catch false)) return null;
            self.reader.skip(16);
            if (remaining >= 2) {
                remaining -= 2;
            } else return null;
        }

        const pts_dts_marker = self.reader.readBits(2) catch return null;
        if (pts_dts_marker == 0x03) {
            self.next_packet.pts = self.decodeTime();
            self.last_decoded_pts = self.next_packet.pts;
            self.reader.skip(40); // skip DTS
            if (remaining >= 10) {
                remaining -= 10;
            } else return null;
        } else if (pts_dts_marker == 0x02) {
            self.next_packet.pts = self.decodeTime();
            self.last_decoded_pts = self.next_packet.pts;
            if (remaining >= 5) {
                remaining -= 5;
            } else return null;
        } else if (pts_dts_marker == 0x00) {
            self.next_packet.pts = root.PLM_PACKET_INVALID_TS;
            self.reader.skip(4);
            if (remaining >= 1) {
                remaining -= 1;
            } else return null;
        } else {
            return null; // invalid
        }

        self.next_packet.length = remaining;
        return self.getPacket();
    }

    fn getPacket(self: *Demux) ?*Packet {
        if (self.next_packet.length == 0) return null;
        if (!(self.reader.has(self.next_packet.length << 3) catch false)) {
            return null;
        }

        self.reader.alignToByte();
        const start = self.reader.tell();
        const end = start + self.next_packet.length;
        if (end > self.reader.reader.end) return null;

        self.current_packet.type = self.next_packet.type;
        self.current_packet.pts = self.next_packet.pts;
        self.current_packet.length = self.next_packet.length;
        self.current_packet.data = self.reader.reader.buffer[start..end];

        self.next_packet.length = 0;
        return &self.current_packet;
    }

    pub fn getStartTime(self: *Demux, packet_type: PacketType) f64 {
        if (self.start_time != root.PLM_PACKET_INVALID_TS) {
            return self.start_time;
        }

        const previous_pos = self.reader.tell();
        const previous_start_code = self.start_code;

        // Find first video PTS
        self.rewind();
        while (self.decode()) |packet| {
            if (packet.type == packet_type and packet.pts != root.PLM_PACKET_INVALID_TS) {
                self.start_time = packet.pts;
                break;
            }
        }

        self.seek(previous_pos);
        self.start_code = previous_start_code;
        return self.start_time;
    }

    fn seekToTime(
        self: *Demux,
        seek_time: f64,
        packet_type: PacketType,
        force_intra: bool,
    ) ?*Packet {
        if (!self.hasHeaders() catch false) {
            return null;
        }

        const byte_total = self.reader.totalSize() orelse return null;
        var duration = self.duration;
        if (duration <= 0 or duration == root.PLM_PACKET_INVALID_TS) {
            duration = 1;
        }

        // Using the current time, current byte position and the average bytes per
        // second for this file, try to jump to a byte position that hopefully has
        // packets containing timestamps within one second before to the desired
        // seek_time.
        var byterate = @as(f64, @floatFromInt(byte_total)) / duration;
        var cur_time = self.system_clock_ref;
        var scan_span: f64 = 1;

        var target_time = seek_time;
        if (target_time > duration) target_time = duration;
        if (target_time < 0) target_time = 0;
        target_time += self.start_time;

        // The number of retries here is hard-limited to a generous amount. Usually
        // the correct range is found after 1--5 jumps, even for files with very
        // variable bitrates. If significantly more jumps are needed, there's
        // probably something wrong with the file and we just avoid getting into an
        // infinite loop. 32 retries should be enough for anybody.
        var retry: usize = 0;
        while (retry < 32) : (retry += 1) {
            var found_packet_with_pts = false;
            var found_packet_in_range = false;
            var last_valid_packet_start: ?usize = null;
            var first_packet_time: f64 = root.PLM_PACKET_INVALID_TS;

            const cur_pos = self.reader.tell();

            // Estimate byte offset and jump to it.
            const offset = (target_time - cur_time - scan_span) * byterate;
            var seek_pos = @as(f64, @floatFromInt(cur_pos)) + offset;
            if (seek_pos < 0) {
                seek_pos = 0;
            } else if (seek_pos > @as(f64, @floatFromInt(byte_total - 256))) {
                seek_pos = @as(f64, @floatFromInt(byte_total - 256));
            }

            self.seek(@intFromFloat(seek_pos));

            // Scan through all packets up to the seek_time to find the last packet
            // containing an intra frame.
            while (self.reader.findStartCode(@intFromEnum(packet_type)) != null) {
                const packet_start = self.reader.tell();
                const packet = self.decodePacket(packet_type);
                if (packet == null or packet.?.pts == root.PLM_PACKET_INVALID_TS) {
                    continue;
                }

                // Skip packet if it has no PTS
                const packet_pts = packet.?.pts;

                // Bail scanning through packets if we hit one that is outside
                // seek_time - scan_span.
                // We also adjust the cur_time and byterate values here so the next
                // iteration can be a bit more precise.
                if (packet_pts > target_time or packet_pts < target_time - scan_span) {
                    found_packet_with_pts = true;
                    const delta_bytes = @as(f64, @floatFromInt(@as(usize, @intFromFloat(seek_pos)) - cur_pos));
                    const delta_time = packet_pts - cur_time;
                    if (delta_time != 0) {
                        byterate = delta_bytes / delta_time;
                    }
                    cur_time = packet_pts;
                    break;
                }

                // Record first packet time in this range to possibly back off later.
                if (!found_packet_in_range) {
                    found_packet_in_range = true;
                    first_packet_time = packet_pts;
                }

                if (force_intra) {
                    // Check if this is an intra frame packet.
                    var i: usize = 0;
                    while (i + 6 < packet.?.data.len) : (i += 1) {
                        if (packet.?.data[i] == 0x00 and packet.?.data[i + 1] == 0x00 and packet.?.data[i + 2] == 0x01 and packet.?.data[i + 3] == 0x00) {
                            // Bits 11--13 in the picture header contain the frame type, where 1=Intra
                            if ((packet.?.data[i + 5] & 0x38) == 0x08) {
                                last_valid_packet_start = packet_start;
                            }
                            break;
                        }
                    }
                } else {
                    last_valid_packet_start = packet_start;
                }
            }

            // If there was at least one intra frame in the range scanned above,
            // our search is over. Jump back to the packet and decode it again.
            if (last_valid_packet_start) |pos| {
                self.seek(pos);
                return self.decodePacket(packet_type);
            } else if (found_packet_in_range) {
                // If we hit the right range, but still found no intra frame, we have
                // to increase the scan_span. This is done exponentially to also handle
                // video files with very few intra frames.
                scan_span *= 2;
                if (first_packet_time != root.PLM_PACKET_INVALID_TS) {
                    target_time = first_packet_time;
                }
            } else if (!found_packet_with_pts) {
                // If we didn't find any packet with a PTS, it probably means we reached
                // the end of the file. Estimate byterate and cur_time accordingly.
                const delta_bytes = @as(f64, @floatFromInt(@as(usize, @intFromFloat(seek_pos)) - cur_pos));
                const delta_time = duration - cur_time;
                if (delta_time != 0) {
                    byterate = delta_bytes / delta_time;
                }
                cur_time = duration;
            }
        }

        return null;
    }

    pub fn getDuration(self: *Demux, packet_type: PacketType) f64 {
        const maybe_size = self.reader.totalSize() orelse return root.PLM_PACKET_INVALID_TS;
        if (self.duration != root.PLM_PACKET_INVALID_TS and self.last_file_size == maybe_size) {
            return self.duration;
        }

        const previous_pos = self.reader.tell();
        const previous_start_code = self.start_code;

        // Find last video PTS. Start searching 64kb from the end and go further
        // back if needed.
        var last_pts: f64 = root.PLM_PACKET_INVALID_TS;
        var range: usize = 64 * 1024;
        while (range <= 4096 * 1024) : (range *= 2) {
            var seek_pos: isize = @intCast(maybe_size - range);
            if (seek_pos < 0) {
                seek_pos = 0;
                range = 4096 * 1024; // Make sure to bail after this round
            }

            self.seek(@intCast(seek_pos));
            self.current_packet.length = 0;
            self.current_packet.data = &[_]u8{};

            last_pts = root.PLM_PACKET_INVALID_TS;
            while (self.decode()) |packet| {
                if (packet.type == packet_type and packet.pts != root.PLM_PACKET_INVALID_TS) {
                    last_pts = packet.pts;
                }
            }

            if (last_pts != root.PLM_PACKET_INVALID_TS) {
                const start_pts = self.getStartTime(packet_type);
                if (start_pts != root.PLM_PACKET_INVALID_TS) {
                    self.duration = last_pts - start_pts;
                } else {
                    self.duration = root.PLM_PACKET_INVALID_TS;
                }
                break;
            }

            if (seek_pos == 0) {
                break;
            }
        }

        self.seek(previous_pos);
        self.start_code = previous_start_code;
        self.last_file_size = maybe_size;
        return self.duration;
    }
};
