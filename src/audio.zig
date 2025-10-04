const std = @import("std");

const tables = @import("tables.zig");
const BitReader = @import("bitreader.zig").BitReader;
const types = @import("types.zig");

pub const Audio = struct {
    allocator: std.mem.Allocator,
    time: f64 = 0,
    samples_decoded: u32 = 0,
    samplerate_index: u8 = 3,
    bitrate_index: u8 = 0,
    version: u8 = 0,
    layer: u8 = 0,
    mode: u8 = 0,
    bound: u8 = 0,
    v_pos: u16 = 0,
    next_frame_data_size: u32 = 0,
    has_header: bool = false,
    use_interleaved: bool = false,

    reader: *BitReader,

    allocation: [2][32]?QuantizerSpec = undefined,
    scale_factor_info: [2][32]u8 = undefined,
    scale_factor: [2][32][3]i32 = undefined,
    sample: [2][32][3]i32 = undefined,

    samples: *types.Samples = undefined,
    D: [1024]f32 = undefined,
    V: [2][1024]f32 = undefined,
    U: [32]f32 = undefined,

    pub fn init(allocator: std.mem.Allocator, reader: *BitReader, use_interleaved: bool) !*Audio {
        const self = try allocator.create(Audio);
        self.* = .{
            .allocator = allocator,
            .reader = reader,
            .samples = try allocator.create(types.Samples),
            .allocation = undefined,
            .scale_factor_info = undefined,
            .scale_factor = undefined,
            .sample = undefined,
            .D = undefined,
            .V = undefined,
            .U = undefined,
            .use_interleaved = use_interleaved,
        };
        self.samples.count = types.SAMPLES_PER_FRAME;
        @memcpy(self.D[0..512], tables.synthesis_window[0..512]);
        @memcpy(self.D[512..], tables.synthesis_window[0..512]);
        for (&self.V) |*row| {
            @memset(row, @as(f32, 0.0));
        }
        @memset(&self.U, @as(f32, 0.0));

        return self;
    }

    pub fn deinit(self: *Audio, allocator: std.mem.Allocator) void {
        allocator.destroy(self.samples);
        allocator.destroy(self);
    }

    pub fn decode(self: *Audio) !?*types.Samples {
        // Do we have at least enough information to decode the frame header?
        if (self.next_frame_data_size == 0) {
            const has_header_data = self.reader.has(48) catch false;
            if (!has_header_data) {
                return null;
            }
            self.next_frame_data_size = self.decodeHeader() catch |err| {
                std.debug.print("Audio header decode failed: {}\n", .{err});
                return null;
            };
            // Don't consume yet - return so caller can see next_frame_data_size
            return null;
        }

        if (self.next_frame_data_size == 0) {
            return null;
        }

        const has_frame_data = self.reader.has(self.next_frame_data_size << 3) catch false;
        if (!has_frame_data) {
            return null;
        }

        try self.decodeFrame();
        self.next_frame_data_size = 0;

        self.samples.time = self.time;
        self.samples_decoded += types.SAMPLES_PER_FRAME;
        const samples_decoded_f: f64 = @floatFromInt(self.samples_decoded);
        const samplerate_f: f64 = @floatFromInt(sample_rates[self.samplerate_index]);
        self.time = samples_decoded_f / samplerate_f;

        return self.samples;
    }

    pub fn hasEnded(self: *Audio) bool {
        return self.reader.hasEnded();
    }

    pub fn rewind(self: *Audio) void {
        self.reader.seekTo(0);
        self.time = 0;
        self.samples_decoded = 0;
        self.next_frame_data_size = 0;
    }

    pub fn setTime(self: *Audio, time: f64) void {
        self.samples_decoded = @intCast(time * @as(f64, intToF32(sample_rates[self.samplerate_index])));
        self.time = time;
    }

    pub fn getSamplerate(self: *Audio) u32 {
        return if (self.hasHeader()) sample_rates[self.samplerate_index] else 0;
    }

    fn decodeHeader(self: *Audio) !u32 {
        if (!(self.reader.has(48) catch false)) {
            return 0;
        }

        _ = self.reader.skipBytes(0x00) catch 0;
        const sync = self.reader.readBits(11) catch return 0;

        // Attempt to resync if no syncword was found. This sucks balls. The MP2
        // stream contains a syncword just before every frame (11 bits set to 1).
        // However, this syncword is not guaranteed to not occur elsewhere in the
        // stream. So, if we have to resync, we also have to check if the header
        // (samplerate, bitrate) differs from the one we had before. This all
        // may still lead to garbage data being decoded :/
        if (sync != frame_sync and !self.findFrameSync()) {
            return 0;
        }

        self.version = @as(u8, @intCast(self.reader.readBits(2) catch return 0));
        self.layer = @as(u8, @intCast(self.reader.readBits(2) catch return 0));
        const hasCRC = (self.reader.readBits(1) catch 0) == 0; // Inverted: 0 means CRC present

        if (self.version != mpeg_1 or self.layer != layer_ii) return 0;

        const bitrate_index = @as(u8, @intCast((self.reader.readBits(4) catch return 0) - 1));
        if (bitrate_index > 13) return 0;

        const samplerate_index = @as(u8, @intCast(self.reader.readBits(2) catch return 0));
        if (samplerate_index == 3) return 0;

        const padding = self.reader.readBits(1) catch return 0;
        self.reader.skip(1); // f_private
        const mode = @as(u8, @intCast(self.reader.readBits(2) catch return 0));

        // If we already have a header, make sure the samplerate, bitrate and mode
        // are still the same, otherwise we might have missed sync.
        if (self.has_header and (self.bitrate_index != bitrate_index or
            self.samplerate_index != samplerate_index or
            self.mode != mode)) return 0;

        self.bitrate_index = bitrate_index;
        self.samplerate_index = samplerate_index;
        self.mode = mode;
        self.has_header = true;

        // Parse the mode_extension, set up the stereo bound
        if (mode == mode_joint_stereo) {
            self.bound = @as(u8, @intCast(((@as(u8, @intCast(self.reader.readBits(2) catch return 0))) + 1) << 2));
        } else {
            self.reader.skip(2);
            self.bound = if (mode == mode_mono) 0 else 32;
        }

        // Discard the last 4 bits of the header and the CRC value, if present
        self.reader.skip(4); // copyright(1), original(1), emphasis(2)
        if (hasCRC) self.reader.skip(16);

        // Compute frame size, check if we have enough data to decode the whole
        // frame.
        const bitrate = bit_rates[bitrate_index];
        const samplerate = sample_rates[samplerate_index];
        const frame_size = @divTrunc(144000 * @as(i32, bitrate), @as(i32, samplerate)) + @as(i32, @intCast(padding));
        const crc_adjustment: i32 = if (hasCRC) 6 else 4;
        return @as(u32, @intCast(frame_size - crc_adjustment));
    }

    fn decodeFrame(self: *Audio) !void {
        // Prepare the quantizer table lookups
        const tab1: u8 = if (self.mode == mode_mono) 0 else 1;
        const tab2 = tables.quant_lut_step_1[tab1][self.bitrate_index];
        var tab3 = tables.quant_lut_step_2[tab2][self.samplerate_index];
        const sblimit = tab3 & 63;
        tab3 >>= 6;

        if (self.bound > sblimit) {
            self.bound = sblimit;
        }

        // Read the allocation information
        for (0..self.bound) |sb| {
            self.allocation[0][sb] = try self.readAllocation(@intCast(sb), tab3);
            self.allocation[1][sb] = try self.readAllocation(@intCast(sb), tab3);
        }

        var sb = self.bound;
        while (sb < sblimit) : (sb += 1) {
            const alloc = try self.readAllocation(@intCast(sb), tab3);
            self.allocation[0][sb] = alloc;
            self.allocation[1][sb] = alloc;
        }

        // Read the scale factor selector information
        const channels: u8 = if (self.mode == mode_mono) 1 else 2;
        for (0..sblimit) |s| {
            for (0..channels) |ch| {
                if (self.allocation[ch][s] != null) {
                    self.scale_factor_info[ch][s] = @intCast(try self.reader.readBits(2));
                }
            }
            if (self.mode == mode_mono) {
                self.scale_factor_info[1][s] = self.scale_factor_info[0][s];
            }
        }
        // Read scale factors
        for (0..sblimit) |s| {
            for (0..channels) |ch| {
                if (self.allocation[ch][s] != null) {
                    const sf = &self.scale_factor[ch][s];
                    switch (self.scale_factor_info[ch][s]) {
                        0 => {
                            sf[0] = @intCast(try self.reader.readBits(6));
                            sf[1] = @intCast(try self.reader.readBits(6));
                            sf[2] = @intCast(try self.reader.readBits(6));
                        },
                        1 => {
                            const val: i32 = @intCast(try self.reader.readBits(6));
                            sf[0] = val;
                            sf[1] = val;
                            sf[2] = @intCast(try self.reader.readBits(6));
                        },
                        2 => {
                            const val: i32 = @intCast(try self.reader.readBits(6));
                            sf[0] = val;
                            sf[1] = val;
                            sf[2] = val;
                        },
                       3 => {
                           sf[0] = @intCast(try self.reader.readBits(6));
                            const val: i32 = @intCast(try self.reader.readBits(6));
                            sf[1] = val;
                            sf[2] = val;
                        },
                        else => {},
                    }
                }
            }
            if (self.mode == mode_mono) {
                self.scale_factor[1][s][0] = self.scale_factor[0][s][0];
                self.scale_factor[1][s][1] = self.scale_factor[0][s][1];
                self.scale_factor[1][s][2] = self.scale_factor[0][s][2];
            }
        }

        // Coefficient input and reconstruction
        var out_pos: usize = 0;
        for (0..3) |part| {
            for (0..4) |_| {
                // read the samples
                for (0..self.bound) |b| {
                    try self.readSamples(0, @intCast(b), @intCast(part));
                    try self.readSamples(1, @intCast(b), @intCast(part));
                }
                var b = self.bound;
                while (b < sblimit) : (b += 1) {
                    try self.readSamples(0, b, @intCast(part));
                    self.sample[1][b][0] = self.sample[0][b][0];
                    self.sample[1][b][1] = self.sample[0][b][1];
                    self.sample[1][b][2] = self.sample[0][b][2];
                }
                b = sblimit;
                while (b < 32) : (b += 1) {
                    self.sample[0][b][0] = 0;
                    self.sample[0][b][1] = 0;
                    self.sample[0][b][2] = 0;
                    self.sample[1][b][0] = 0;
                    self.sample[1][b][1] = 0;
                    self.sample[1][b][2] = 0;
                }

                // Synthesis loop
                for (0..3) |p| {
                    // Shifting step
                    self.v_pos = @intCast((@as(u16, @intCast(self.v_pos)) -% 64) & 1023);

                    for (0..2) |ch| {
                        idct36(self.sample[ch], @intCast(p), &self.V[ch], @intCast(self.v_pos));

                        // Build U, windowing, calculate output
                        @memset(&self.U, 0);

                        var d_index = 512 - (@as(u16, @intCast(self.v_pos)) >> 1);
                        var v_index = (self.v_pos % 128) >> 1;
                        while (v_index < 1024) {
                            for (0..32) |i| {
                                self.U[i] += self.D[d_index] * self.V[ch][v_index];
                                d_index += 1;
                                v_index += 1;
                            }

                            v_index += 128 - 32;
                            d_index += 64 - 32;
                        }

                        d_index -= (512 - 32);
                        v_index = (128 - 32 + 1024) - v_index;
                        while (v_index < 1024) {
                            for (0..32) |i| {
                                self.U[i] += self.D[d_index] * self.V[ch][v_index];
                                d_index += 1;
                                v_index += 1;
                            }

                            v_index += 128 - 32;
                            d_index += 64 - 32;
                        }

                        if (self.use_interleaved) {
                            for (0..32) |j| {
                                self.samples.interleaved[((out_pos + j) << 1) + ch] = self.U[j] / -1090519040.0;
                            }
                        } else {
                            const out_channel = if (ch == 0) &self.samples.left else &self.samples.right;
                            for (0..32) |j| {
                                out_channel[out_pos + j] = self.U[j] / -1090519040.0;
                            }
                        }
                    } // End of synthesis channel loop
                    out_pos += 32;
                } // End of synthesis sub-block loop
            } // Decoding of the granule finished
        }

        self.reader.alignToByte();
    }

    fn findFrameSync(self: *Audio) bool {
        var i = self.reader.reader.seek;
        const end = self.reader.reader.end;

        while (i + 1 < end) : (i += 1) {
            const b0 = self.reader.reader.buffer[i];
            const b1 = self.reader.reader.buffer[i + 1];
            if (b0 == 0xFF and (b1 & 0xFE) == 0xFC) {
                self.reader.reader.seek = i + 1;
                self.reader.bit_index = 3;
                return true;
            }
        }

        const clamped = @min(i + 1, end);
        self.reader.reader.seek = clamped;
        self.reader.bit_index = 0;
        return false;
    }

    fn hasHeader(self: *Audio) bool {
        if (self.has_header) return true;

        self.next_frame_data_size = self.decodeHeader() catch 0;
        return self.has_header;
    }

    fn readAllocation(self: *Audio, sb: u8, tab3: u8) !?QuantizerSpec {
        const tab4 = tables.quant_lut_step_3[tab3][sb];
        const qtab = tables.quant_lut_step_4[tab4 & 15][try self.reader.readBits(@intCast(tab4 >> 4))];
        return if (qtab != 0) tables.audio_quant_tab[qtab - 1] else null;
    }

    fn readSamples(self: *Audio, ch: u8, sb: u8, part: u8) !void {
        var sf = self.scale_factor[ch][sb][part];
        const sample = &self.sample[ch][sb];
        var val: i32 = 0;

        if (self.allocation[ch][sb]) |*q| {
            if (self.samples_decoded == 0 and ch == 0 and sb == 0) {
                const has_data = self.reader.has(@intCast(q.bits * 3)) catch false;
                std.debug.print("BitReader has {d} bits available? {}\n", .{ q.bits * 3, has_data });
                std.debug.print("  seek={d} end={d} bit_index={d}\n", .{ self.reader.reader.seek, self.reader.reader.end, self.reader.bit_index });
                if (self.reader.reader.seek < self.reader.reader.end) {
                    const bytes_to_show = @min(4, self.reader.reader.end - self.reader.reader.seek);
                    std.debug.print("  Buffer bytes: ", .{});
                    for (0..bytes_to_show) |i| {
                        std.debug.print("0x{x:0>2} ", .{self.reader.reader.buffer[self.reader.reader.seek + i]});
                    }
                    std.debug.print("\n", .{});
                }
            }
            // Resolve scalefactor
            const sf_orig = sf;
            if (sf == 63) {
                sf = 0;
            } else {
                const shift: u5 = @intCast(@divTrunc(sf, 3));
                const base = scale_factor_base[@intCast(@mod(sf, 3))];
                const rounding = (@as(i32, 1) << shift) >> 1;
                const numerator = base + rounding;
                sf = numerator >> shift;
                if (self.samples_decoded == 0 and ch == 0 and sb < 2) {
                    std.debug.print("SF: orig={d} shift={d} base={d} round={d} num={d} final={d}\n", .{ sf_orig, shift, base, rounding, numerator, sf });
                }
            }

            // Decode samples
            var adj: i32 = @intCast(q.levels);
            if (q.group != 0) {
                // Decode grouped samples
                val = @intCast(try self.reader.readBits(@intCast(q.bits)));
                sample[0] = @mod(val, adj);
                val = @divTrunc(val, adj);
                sample[1] = @mod(val, adj);
                sample[2] = @divTrunc(val, adj);
            } else {
                // Decode direct samples
                const s0_raw = try self.reader.readBits(@intCast(q.bits));
                const s1_raw = try self.reader.readBits(@intCast(q.bits));
                const s2_raw = try self.reader.readBits(@intCast(q.bits));
                sample[0] = @intCast(s0_raw);
                sample[1] = @intCast(s1_raw);
                sample[2] = @intCast(s2_raw);

                if (self.samples_decoded == 0 and ch == 0 and sb == 0) {
                    std.debug.print("RAW BITS READ: s0=0x{x} s1=0x{x} s2=0x{x} ({d} bits each)\n", .{ s0_raw, s1_raw, s2_raw, q.bits });
                }
            }

            // Debug first decode and track amplitudes
            const pre0 = sample[0];
            const pre1 = sample[1];
            const pre2 = sample[2];
            _ = pre0;
            _ = pre1;
            _ = pre2;

            // Postmultiply samples
            const scale = @divTrunc(65536, adj + 1);
            adj = ((adj + 1) >> 1) - 1;

            val = (adj - sample[0]) * scale;
            sample[0] = (val * (sf >> 12) + ((val * (sf & 4095) + 2048) >> 12)) >> 12;

            val = (adj - sample[1]) * scale;
            sample[1] = (val * (sf >> 12) + ((val * (sf & 4095) + 2048) >> 12)) >> 12;

            val = (adj - sample[2]) * scale;
            sample[2] = (val * (sf >> 12) + ((val * (sf & 4095) + 2048) >> 12)) >> 12;
        } else {
            // No bits allocated for this subband
            sample[0] = 0;
            sample[1] = 0;
            sample[2] = 0;
            return;
        }
    }
};

pub const QuantizerSpec = struct {
    levels: u16 = 0,
    group: u8 = 0,
    bits: u8 = 0,
};

const frame_sync = 0x7ff;
const mpeg_2_5 = 0x0;
const mpeg_2 = 0x2;
const mpeg_1 = 0x3;

const layer_iii = 0x1;
const layer_ii = 0x2;
const layer_i = 0x3;

const mode_stereo = 0x0;
const mode_joint_stereo = 0x1;
const mode_dual_channel = 0x2;
const mode_mono = 0x3;

const sample_rates = [_]u16{
    44100, 48000, 32000, 0, // MPEG-1
    22050, 24000, 16000, 0, // MPEG-2
};

const bit_rates = [_]i16{
    32, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, // MPEG-1
    8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, // MPEG-2
};

inline fn intToF32(value: i32) f32 {
    return @as(f32, @floatFromInt(value));
}

inline fn f32c(value: f64) f32 {
    return @floatCast(value);
}

const scale_factor_base = [_]i32{ 0x02000000, 0x01965FEA, 0x01428A30 };

fn idct36(s: [32][3]i32, ss: u32, d: []f32, dp: i32) void {
    const si: usize = @intCast(ss);

    var t01: f32 = intToF32(s[0][si] + s[31][si]);
    var t02: f32 = intToF32(s[0][si] - s[31][si]) * f32c(0.500602998235);
    var t03: f32 = intToF32(s[1][si] + s[30][si]);
    var t04: f32 = intToF32(s[1][si] - s[30][si]) * f32c(0.505470959898);
    var t05: f32 = intToF32(s[2][si] + s[29][si]);
    var t06: f32 = intToF32(s[2][si] - s[29][si]) * f32c(0.515447309923);
    var t07: f32 = intToF32(s[3][si] + s[28][si]);
    var t08: f32 = intToF32(s[3][si] - s[28][si]) * f32c(0.53104259109);
    var t09: f32 = intToF32(s[4][si] + s[27][si]);
    var t10: f32 = intToF32(s[4][si] - s[27][si]) * f32c(0.553103896034);
    var t11: f32 = intToF32(s[5][si] + s[26][si]);
    var t12: f32 = intToF32(s[5][si] - s[26][si]) * f32c(0.582934968206);
    var t13: f32 = intToF32(s[6][si] + s[25][si]);
    var t14: f32 = intToF32(s[6][si] - s[25][si]) * f32c(0.622504123036);
    var t15: f32 = intToF32(s[7][si] + s[24][si]);
    var t16: f32 = intToF32(s[7][si] - s[24][si]) * f32c(0.674808341455);
    var t17: f32 = intToF32(s[8][si] + s[23][si]);
    var t18: f32 = intToF32(s[8][si] - s[23][si]) * f32c(0.744536271002);
    var t19: f32 = intToF32(s[9][si] + s[22][si]);
    var t20: f32 = intToF32(s[9][si] - s[22][si]) * f32c(0.839349645416);
    var t21: f32 = intToF32(s[10][si] + s[21][si]);
    var t22: f32 = intToF32(s[10][si] - s[21][si]) * f32c(0.972568237862);
    var t23: f32 = intToF32(s[11][si] + s[20][si]);
    var t24: f32 = intToF32(s[11][si] - s[20][si]) * f32c(1.16943993343);
    var t25: f32 = intToF32(s[12][si] + s[19][si]);
    var t26: f32 = intToF32(s[12][si] - s[19][si]) * f32c(1.48416461631);
    var t27: f32 = intToF32(s[13][si] + s[18][si]);
    var t28: f32 = intToF32(s[13][si] - s[18][si]) * f32c(2.05778100995);
    var t29: f32 = intToF32(s[14][si] + s[17][si]);
    var t30: f32 = intToF32(s[14][si] - s[17][si]) * f32c(3.40760841847);
    var t31: f32 = intToF32(s[15][si] + s[16][si]);
    var t32: f32 = intToF32(s[15][si] - s[16][si]) * f32c(10.1900081235);

    var t33: f32 = t01 + t31;
    t31 = (t01 - t31) * f32c(0.502419286188);
    t01 = t03 + t29;
    t29 = (t03 - t29) * f32c(0.52249861494);
    t03 = t05 + t27;
    t27 = (t05 - t27) * f32c(0.566944034816);
    t05 = t07 + t25;
    t25 = (t07 - t25) * f32c(0.64682178336);
    t07 = t09 + t23;
    t23 = (t09 - t23) * f32c(0.788154623451);
    t09 = t11 + t21;
    t21 = (t11 - t21) * f32c(1.06067768599);
    t11 = t13 + t19;
    t19 = (t13 - t19) * f32c(1.72244709824);
    t13 = t15 + t17;
    t17 = (t15 - t17) * f32c(5.10114861869);
    t15 = t33 + t13;
    t13 = (t33 - t13) * f32c(0.509795579104);
    t33 = t01 + t11;
    t01 = (t01 - t11) * f32c(0.601344886935);
    t11 = t03 + t09;
    t09 = (t03 - t09) * f32c(0.899976223136);
    t03 = t05 + t07;
    t07 = (t05 - t07) * f32c(2.56291544774);
    t05 = t15 + t03;
    t15 = (t15 - t03) * f32c(0.541196100146);
    t03 = t33 + t11;
    t11 = (t33 - t11) * f32c(1.30656296488);
    t33 = t05 + t03;
    t05 = (t05 - t03) * f32c(0.707106781187);
    t03 = t15 + t11;
    t15 = (t15 - t11) * f32c(0.707106781187);
    t03 += t15;
    t11 = t13 + t07;
    t13 = (t13 - t07) * f32c(0.541196100146);
    t07 = t01 + t09;
    t09 = (t01 - t09) * f32c(1.30656296488);
    t01 = t11 + t07;
    t07 = (t11 - t07) * f32c(0.707106781187);
    t11 = t13 + t09;
    t13 = (t13 - t09) * f32c(0.707106781187);
    t11 += t13;
    t01 += t11;
    t11 += t07;
    t07 += t13;

    t09 = t31 + t17;
    t31 = (t31 - t17) * f32c(0.509795579104);
    t17 = t29 + t19;
    t29 = (t29 - t19) * f32c(0.601344886935);
    t19 = t27 + t21;
    t21 = (t27 - t21) * f32c(0.899976223136);
    t27 = t25 + t23;
    t23 = (t25 - t23) * f32c(2.56291544774);
    t25 = t09 + t27;
    t09 = (t09 - t27) * f32c(0.541196100146);
    t27 = t17 + t19;
    t19 = (t17 - t19) * f32c(1.30656296488);
    t17 = t25 + t27;
    t27 = (t25 - t27) * f32c(0.707106781187);
    t25 = t09 + t19;
    t19 = (t09 - t19) * f32c(0.707106781187);
    t25 += t19;
    t09 = t31 + t23;
    t31 = (t31 - t23) * f32c(0.541196100146);
    t23 = t29 + t21;
    t21 = (t29 - t21) * f32c(1.30656296488);
    t29 = t09 + t23;
    t23 = (t09 - t23) * f32c(0.707106781187);
    t09 = t31 + t21;
    t31 = (t31 - t21) * f32c(0.707106781187);
    t09 += t31;
    t29 += t09;
    t09 += t23;
    t23 += t31;

    t17 += t29;
    t29 += t25;
    t25 += t09;
    t09 += t27;
    t27 += t23;
    t23 += t19;
    t19 += t31;

    t21 = t02 + t32;
    t02 = (t02 - t32) * f32c(0.502419286188);
    t32 = t04 + t30;
    t04 = (t04 - t30) * f32c(0.52249861494);
    t30 = t06 + t28;
    t28 = (t06 - t28) * f32c(0.566944034816);
    t06 = t08 + t26;
    t08 = (t08 - t26) * f32c(0.64682178336);
    t26 = t10 + t24;
    t10 = (t10 - t24) * f32c(0.788154623451);
    t24 = t12 + t22;
    t22 = (t12 - t22) * f32c(1.06067768599);
    t12 = t14 + t20;
    t20 = (t14 - t20) * f32c(1.72244709824);
    t14 = t16 + t18;
    t16 = (t16 - t18) * f32c(5.10114861869);

    t18 = t21 + t14;
    t14 = (t21 - t14) * f32c(0.509795579104);
    t21 = t32 + t12;
    t32 = (t32 - t12) * f32c(0.601344886935);
    t12 = t30 + t24;
    t24 = (t30 - t24) * f32c(0.899976223136);
    t30 = t06 + t26;
    t26 = (t06 - t26) * f32c(2.56291544774);
    t06 = t18 + t30;
    t18 = (t18 - t30) * f32c(0.541196100146);
    t30 = t21 + t12;
    t12 = (t21 - t12) * f32c(1.30656296488);
    t21 = t06 + t30;
    t30 = (t06 - t30) * f32c(0.707106781187);
    t06 = t18 + t12;
    t12 = (t18 - t12) * f32c(0.707106781187);
    t06 += t12;

    t18 = t14 + t26;
    t26 = (t14 - t26) * f32c(0.541196100146);
    t14 = t32 + t24;
    t24 = (t32 - t24) * f32c(1.30656296488);
    t32 = t18 + t14;
    t14 = (t18 - t14) * f32c(0.707106781187);
    t18 = t26 + t24;
    t24 = (t26 - t24) * f32c(0.707106781187);
    t18 += t24;
    t32 += t18;
    t18 += t14;
    t26 = t14 + t24;

    t14 = t02 + t16;
    t02 = (t02 - t16) * f32c(0.509795579104);
    t16 = t04 + t20;
    t04 = (t04 - t20) * f32c(0.601344886935);
    t20 = t28 + t22;
    t22 = (t28 - t22) * f32c(0.899976223136);
    t28 = t08 + t10;
    t10 = (t08 - t10) * f32c(2.56291544774);
    t08 = t14 + t28;
    t14 = (t14 - t28) * f32c(0.541196100146);
    t28 = t16 + t20;
    t20 = (t16 - t20) * f32c(1.30656296488);
    t16 = t08 + t28;
    t28 = (t08 - t28) * f32c(0.707106781187);
    t08 = t14 + t20;
    t20 = (t14 - t20) * f32c(0.707106781187);
    t08 += t20;

    t14 = t02 + t10;
    t02 = (t02 - t10) * f32c(0.541196100146);
    t10 = t04 + t22;
    t22 = (t04 - t22) * f32c(1.30656296488);
    t04 = t14 + t10;
    t10 = (t14 - t10) * f32c(0.707106781187);
    t14 = t02 + t22;
    t02 = (t02 - t22) * f32c(0.707106781187);
    t14 += t02;
    t04 += t14;
    t14 += t10;
    t10 += t02;

    t16 += t04;
    t04 += t08;
    t08 += t14;
    t14 += t28;
    t28 += t10;
    t10 += t20;
    t20 += t02;

    t21 += t16;
    t16 += t32;
    t32 += t04;
    t04 += t06;
    t06 += t08;
    t08 += t18;
    t18 += t14;
    t14 += t30;
    t30 += t28;
    t28 += t26;
    t26 += t10;
    t10 += t12;
    t12 += t20;
    t20 += t24;
    t24 += t02;

    const base: usize = @intCast(dp);
    d[base + 48] = -t33;
    d[base + 49] = -t21;
    d[base + 47] = -t21;
    d[base + 50] = -t17;
    d[base + 46] = -t17;
    d[base + 51] = -t16;
    d[base + 45] = -t16;
    d[base + 52] = -t01;
    d[base + 44] = -t01;
    d[base + 53] = -t32;
    d[base + 43] = -t32;
    d[base + 54] = -t29;
    d[base + 42] = -t29;
    d[base + 55] = -t04;
    d[base + 41] = -t04;
    d[base + 56] = -t03;
    d[base + 40] = -t03;
    d[base + 57] = -t06;
    d[base + 39] = -t06;
    d[base + 58] = -t25;
    d[base + 38] = -t25;
    d[base + 59] = -t08;
    d[base + 37] = -t08;
    d[base + 60] = -t11;
    d[base + 36] = -t11;
    d[base + 61] = -t18;
    d[base + 35] = -t18;
    d[base + 62] = -t09;
    d[base + 34] = -t09;
    d[base + 63] = -t14;

    d[base + 32] = -t05;
    d[base + 0] = t05;
    d[base + 31] = -t30;
    d[base + 1] = t30;
    d[base + 30] = -t27;
    d[base + 2] = t27;
    d[base + 29] = -t28;
    d[base + 3] = t28;
    d[base + 28] = -t07;
    d[base + 4] = t07;
    d[base + 27] = -t26;
    d[base + 5] = t26;
    d[base + 26] = -t23;
    d[base + 6] = t23;
    d[base + 25] = -t10;
    d[base + 7] = t10;
    d[base + 24] = -t15;
    d[base + 8] = t15;
    d[base + 23] = -t12;
    d[base + 9] = t12;
    d[base + 22] = -t19;
    d[base + 10] = t19;
    d[base + 21] = -t20;
    d[base + 11] = t20;
    d[base + 20] = -t13;
    d[base + 12] = t13;
    d[base + 19] = -t24;
    d[base + 13] = t24;
    d[base + 18] = -t31;
    d[base + 14] = t31;
    d[base + 17] = -t02;
    d[base + 15] = t02;
    d[base + 16] = 0.0;
}


