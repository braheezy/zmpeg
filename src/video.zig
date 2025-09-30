const std = @import("std");
const BitReader = @import("bitreader.zig");
const types = @import("types.zig");
const tables = @import("tables.zig");

const PacketType = types.PacketType;
const FrameType = types.Frame;
const PictureType = types.PictureType;

pub const Video = struct {
    allocator: std.mem.Allocator,

    framerate: f64 = 0,
    pixel_aspect_ratio: f64 = 0,
    time: f64 = 0,
    frames_decoded: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    mb_width: i32 = 0,
    mb_height: i32 = 0,
    mb_size: i32 = 0,

    luma_width: i32 = 0,
    luma_height: i32 = 0,

    chroma_width: i32 = 0,
    chroma_height: i32 = 0,

    start_code: i32 = 0,
    picture_type: i32 = 0,

    motion_forward: Motion = .{},
    motion_backward: Motion = .{},

    has_sequence_header: bool = false,

    quantizer_scale: i32 = 0,
    slice_begin: i32 = 0,
    macroblock_address: i32 = 0,

    mb_row: i32 = 0,
    mb_col: i32 = 0,

    macroblock_type: i32 = 0,
    macroblock_intra: bool = false,

    dc_predictor: [3]i32 = .{ 0, 0, 0 },

    reader: *BitReader,
    own_reader: bool = false,

    frame_current: Frame = .{},
    frame_forward: Frame = .{},
    frame_backward: Frame = .{},

    frames_data: []u8 = &[_]u8{},

    block_data: [64]i32 = .{0} ** 64,
    intra_quant_matrix: [64]u8 = .{0} ** 64,
    non_intra_quant_matrix: [64]u8 = .{0} ** 64,

    has_reference_frame: bool = false,
    assume_no_b_frames: bool = false,

    pub fn init(allocator: std.mem.Allocator, reader: *BitReader, own_reader: bool) !*Video {
        const video = try allocator.create(Video);
        video.* = .{
            .allocator = allocator,
            .reader = reader,
            .own_reader = own_reader,
        };

        if (reader.findStartCode(@intFromEnum(types.StartCode.sequence))) |code| {
            video.start_code = code;
            _ = try video.decodeSequenceHeader();
        }

        return video;
    }

    pub fn deinit(self: *Video) void {
        if (self.has_sequence_header and self.frames_data.len != 0) {
            self.allocator.free(self.frames_data);
        }
        if (self.own_reader) {
            self.reader.deinit();
        }
    }

    pub fn getWidth(self: *Video) i32 {
        return if (self.hasHeaders() catch false) self.width else 0;
    }

    pub fn getHeight(self: *Video) i32 {
        return if (self.hasHeaders() catch false) self.height else 0;
    }

    pub fn decode(self: *Video) ?*Frame {
        if (!self.has_sequence_header) {
            return null;
        }

        var frame: ?*Frame = null;
        const picture_code_i32 = @intFromEnum(types.StartCode.picture);
        const picture_code_u8: u8 = @intCast(picture_code_i32);

        while (frame == null) {
            if (self.start_code != picture_code_i32) {
                self.start_code = @intCast(self.reader.findStartCode(picture_code_u8) orelse {
                    // If we reached the end of the file and the previously decoded
                    // frame was a reference frame, we still have to return it.
                    if (self.has_reference_frame and !self.assume_no_b_frames and self.reader.hasEnded() and
                        (self.picture_type == @intFromEnum(PictureType.intra) or self.picture_type == @intFromEnum(PictureType.predictive)))
                    {
                        self.has_reference_frame = false;
                        frame = &self.frame_backward;
                        break;
                    }
                    return null;
                });
            }

            // Make sure we have a full picture in the buffer before attempting to
            // decode it. Sadly, this can only be done by seeking for the start code
            // of the next picture. Also, if we didn't find the start code for the
            // next picture, but the source has ended, we assume that this last
            // picture is in the buffer.
            if (!self.reader.hasStartCode(picture_code_u8) and !self.reader.hasEnded()) return null;

            self.reader.discardReadBytes();

            self.decodePicture() catch return null;

            if (self.assume_no_b_frames) {
                frame = &self.frame_backward;
            } else if (self.picture_type == @intFromEnum(PictureType.b)) {
                frame = &self.frame_current;
            } else if (self.has_reference_frame) {
                frame = &self.frame_forward;
            } else {
                self.has_reference_frame = true;
            }
        }

        const out_frame = frame.?;
        out_frame.time = self.time;
        self.frames_decoded += 1;
        self.time = @as(f64, @floatFromInt(self.frames_decoded)) / self.framerate;

        return out_frame;
    }

    pub fn ensurePictureStart(self: *Video) bool {
        const picture_code = @intFromEnum(types.StartCode.picture);
        if (self.start_code == picture_code) return true;
        const saved_seek = self.reader.reader.seek;
        const saved_bit = self.reader.bit_index;
        const picture_code_u8: u8 = @intCast(picture_code);
        if (self.reader.findStartCode(picture_code_u8)) |code| {
            self.start_code = @intCast(code);
            return true;
        }
        self.reader.reader.seek = saved_seek;
        self.reader.bit_index = saved_bit;
        return false;
    }

    fn decodeSequenceHeader(self: *Video) !bool {
        // 64 bit header + 2x 64 byte matrix
        const max_header_size = 64 + 2 * 64 * 8;
        if (!(self.reader.has(max_header_size) catch false)) {
            return false;
        }
        self.width = @intCast(self.reader.readBits(12) catch return false);
        self.height = @intCast(self.reader.readBits(12) catch return false);
        if (self.width <= 0 or self.height <= 0) {
            return false;
        }
        // get pixel aspect ratio
        var pixel_aspect_ratio_code = self.reader.readBits(4) catch 0;
        const par_last = tables.pixel_aspect_ratio.len - 1;
        if (pixel_aspect_ratio_code > par_last) {
            pixel_aspect_ratio_code = par_last;
        }
        self.pixel_aspect_ratio = tables.pixel_aspect_ratio[pixel_aspect_ratio_code];
        // Get frame rate
        self.framerate = tables.picture_rate[self.reader.readBits(4) catch 0];
        // Skip bit_rate, marker, buffer_size and constrained bit
        self.reader.skip(18 + 1 + 10 + 1);
        // Load custom intra quant matrix?
        if ((self.reader.readBits(1) catch 0) != 0) {
            for (0..64) |i| {
                const idx = tables.zig_zag[i];
                self.intra_quant_matrix[idx] = @intCast(self.reader.readBits(8) catch return false);
            }
        } else {
            @memcpy(&self.intra_quant_matrix, &tables.intra_quant_matrix);
        }

        self.mb_width = (self.width + 15) >> 4;
        self.mb_height = (self.height + 15) >> 4;
        self.mb_size = self.mb_width * self.mb_height;

        self.luma_width = self.mb_width << 4;
        self.luma_height = self.mb_height << 4;

        self.chroma_width = self.mb_width << 3;
        self.chroma_height = self.mb_height << 3;

        // Allocate one big chunk of data for all 3 frames = 9 planes
        const luma_plane_size = self.luma_width * self.luma_height;
        const chroma_plane_size = self.chroma_width * self.chroma_height;
        const frame_data_size = (luma_plane_size + 2 * chroma_plane_size);

        self.frames_data = try self.allocator.alloc(u8, @intCast(frame_data_size * 3));
        self.initFrame(&self.frame_current, self.frames_data[@intCast(frame_data_size * 0)..]);
        self.initFrame(&self.frame_forward, self.frames_data[@intCast(frame_data_size * 1)..]);
        self.initFrame(&self.frame_backward, self.frames_data[@intCast(frame_data_size * 2)..]);

        self.has_sequence_header = true;
        return true;
    }

    fn decodePicture(self: *Video) !void {
        // skip temporalReference
        self.reader.skip(10);
        self.picture_type = @intCast(try self.reader.readBits(3));
        // skip vbv_delay
        self.reader.skip(16);
        // D frames or unknown coding type
        if (self.picture_type <= 0 or self.picture_type > @intFromEnum(PictureType.b)) return;

        // Forward full_px, f_code
        if (self.picture_type == @intFromEnum(PictureType.predictive) or
            self.picture_type == @intFromEnum(PictureType.b))
        {
            self.motion_forward.full_px = @intCast(try self.reader.readBits(1));
            const f_code: i32 = @intCast(try self.reader.readBits(3));
            // Ignore picture with zero f_code
            if (f_code == 0) return;
            self.motion_forward.r_size = f_code - 1;
        }

        // Backward full_px, f_code
        if (self.picture_type == @intFromEnum(PictureType.b)) {
            self.motion_backward.full_px = @intCast(try self.reader.readBits(1));
            const f_code: i32 = @intCast(try self.reader.readBits(3));
            // Ignore picture with zero f_code
            if (f_code == 0) return;
            self.motion_backward.r_size = f_code - 1;
        }

        const frame_temp = self.frame_forward;
        if (self.picture_type == @intFromEnum(PictureType.intra) or
            self.picture_type == @intFromEnum(PictureType.predictive))
        {
            self.frame_forward = self.frame_backward;
        }

        // Find first slice start code; skip extension and user data
        while (true) {
            self.start_code = self.reader.nextStartCode() orelse {
                return;
            };
            if (self.start_code == @intFromEnum(types.StartCode.extension) or
                self.start_code == @intFromEnum(types.StartCode.user_data))
            {
                break;
            }
        }
        // Decode all slices
        while (codeIsSlice(self.start_code)) {
            try self.decodeSlice(self.start_code & 0x000000FF);
            if (self.macroblock_address >= self.mb_size - 2) {
                break;
            }
            self.start_code = self.reader.nextStartCode() orelse {
                return;
            };
        }

        // If this is a reference picture rotate the prediction pointers
        if (self.picture_type == @intFromEnum(PictureType.intra) or
            self.picture_type == @intFromEnum(PictureType.predictive))
        {
            self.frame_backward = self.frame_current;
            self.frame_current = frame_temp;
        }
    }

    fn decodeSlice(self: *Video, slice: i32) !void {
        self.slice_begin = 1;
        self.macroblock_address = (slice - 1) * self.mb_width - 1;

        // Reset motion vectors and DC predictors
        self.motion_backward.h = 0;
        self.motion_forward.h = 0;
        self.motion_backward.v = 0;
        self.motion_forward.v = 0;
        self.dc_predictor[0] = 128;
        self.dc_predictor[1] = 128;
        self.dc_predictor[2] = 128;

        self.quantizer_scale = @intCast(try self.reader.readBits(5));

        // Skip extra
        while ((self.reader.readBits(1) catch return) != 0) {
            self.reader.skip(8);
        }

        while (true) {
            try self.decodeMacroblock();

            if (self.macroblock_address < self.mb_size - 1 and self.reader.peekNonZero(23) catch return) {
                break;
            }
        }
    }

    fn decodeMacroblock(self: *Video) !void {
        // decode increment
        var increment: i32 = 0;
        var t = try self.reader.readVlc(&tables.macroblock_address_increment);

        while (t == 34) {
            // macroblock_stuffing
            t = try self.reader.readVlc(&tables.macroblock_address_increment);
        }
        while (t == 35) {
            // macroblock_escape
            increment += 33;
            t = try self.reader.readVlc(&tables.macroblock_address_increment);
        }
        increment += t;

        // Process any skipped macroblocks
        if (self.slice_begin != 0) {
            // The first increment of each slice is relative to beginning of the
            // previous row, not the previous macroblock
            self.slice_begin = 0;
            self.macroblock_address += increment;
        } else {
            if (self.macroblock_address + increment >= self.mb_size) {
                return; // invalid
            }
            if (increment > 1) {
                // Skipped macroblocks reset DC predictors
                self.dc_predictor[0] = 128;
                self.dc_predictor[1] = 128;
                self.dc_predictor[2] = 128;
                // Skipped macroblocks in P-pictures reset motion vectors
                if (self.picture_type == @intFromEnum(PictureType.predictive)) {
                    self.motion_forward.h = 0;
                    self.motion_forward.v = 0;
                }
            }

            // Predict skipped macroblocks
            while (increment > 1) {
                self.macroblock_address += 1;
                self.mb_row = @divTrunc(self.macroblock_address, self.mb_width);
                self.mb_col = @mod(self.macroblock_address, self.mb_width);
                self.predictMacroblock();
                increment -= 1;
            }
            self.macroblock_address += 1;
        }

        self.mb_row = @divTrunc(self.macroblock_address, self.mb_width);
        self.mb_col = @mod(self.macroblock_address, self.mb_width);

        if (self.mb_col >= self.mb_width or self.mb_row >= self.mb_height) {
            return; // corrupt stream;
        }

        // Process the current macroblock
        const tbl = tables.macroblock_type[@intCast(self.picture_type)];
        self.macroblock_type = try self.reader.readVlc(tbl.?);

        self.macroblock_intra = (self.macroblock_type & 0x01) != 0;
        self.motion_forward.is_set = (self.macroblock_type & 0x08) != 0;
        self.motion_backward.is_set = (self.macroblock_type & 0x04) != 0;

        // Quantizer scale
        if ((self.macroblock_type & 0x10) != 0) {
            self.quantizer_scale = @intCast(try self.reader.readBits(5));
        }

        if (self.macroblock_intra) {
            // Intra-coded macroblocks reset motion vectors
            self.motion_backward.h = 0;
            self.motion_forward.h = 0;
            self.motion_backward.v = 0;
            self.motion_forward.v = 0;
        } else {
            // Non-intra macroblocks reset DC predictors
            self.dc_predictor[0] = 128;
            self.dc_predictor[1] = 128;
            self.dc_predictor[2] = 128;

            self.decodeMotionVectors();
            self.predictMacroblock();
        }

        // Decode blocks
        const cbp: i16 = if ((self.macroblock_type & 0x02) != 0)
            try self.reader.readVlc(&tables.code_block_pattern)
        else if (self.macroblock_intra) 0x3f else 0;

        var mask: i32 = 0x20;
        for (0..6) |block| {
            if ((cbp & mask) != 0) {
                try self.decodeBlock(@intCast(block));
            }
            mask >>= 1;
        }
    }

    fn decodeBlock(self: *Video, block: i32) !void {
        var n: i32 = 0;
        var quant_matrix: []const u8 = undefined;

        // Decode DC coefficient of intra-coded blocks
        if (self.macroblock_intra) {
            // dc prediction
            const plane_index = if (block > 3) block - 3 else 0;
            const predictor = self.dc_predictor[@intCast(plane_index)];
            const dct_size = try self.reader.readVlc(tables.dct_size[@intCast(plane_index)]);

            // Read DC coeff
            if (dct_size > 0) {
                const differential: i32 = @intCast(try self.reader.readBits(@intCast(dct_size)));
                if ((differential & (@as(i32, 1) << @intCast(dct_size - 1))) != 0) {
                    self.block_data[0] = predictor + differential;
                } else {
                    self.block_data[0] = predictor + (-(@as(i32, 1) << @intCast(dct_size)) | (differential + 1));
                }
            } else {
                self.block_data[0] = predictor;
            }

            // Save predictor value
            self.dc_predictor[@intCast(plane_index)] = self.block_data[0];

            // Dequantize + premultiply
            self.block_data[0] <<= (3 + 5);

            quant_matrix = &self.intra_quant_matrix;
            n = 1;
        } else {
            quant_matrix = &self.non_intra_quant_matrix;
        }

        // Decode AC coefficients (+DC for non-intra)
        var level: i32 = 0;
        while (true) {
            var run: i32 = 0;
            const coeff = try self.reader.readVlcUint(&tables.dct_coeff);

            if (coeff == 0x0001 and n > 0 and !(self.reader.readBit() catch false)) {
                break;
            }
            if (coeff == 0xffff) {
                // escape
                run = @intCast(try self.reader.readBits(6));
                level = @intCast(try self.reader.readBits(8));
                if (level == 0) {
                    level = @intCast(try self.reader.readBits(8));
                } else if (level == 128) {
                    level = @intCast(try self.reader.readBits(8) - 256);
                } else if (level > 128) {
                    level = level - 256;
                }
            } else {
                run = coeff >> 8;
                level = coeff & 0xff;
                if (self.reader.readBit() catch false) {
                    level = -level;
                }
            }

            n += run;
            if (n < 0 or n >= 64) {
                return; // invalid
            }

            const de_zig_zagged = tables.zig_zag[@intCast(n)];
            n += 1;

            // Dequantize, oddify, clip
            level = @intCast(@as(u32, @intCast(level)) << 1);
            if (!self.macroblock_intra) {
                level += if (level < 0) -1 else 1;
            }
            level = (level * self.quantizer_scale * quant_matrix[de_zig_zagged]) >> 4;
            if ((level & 1) == 0) {
                level = if (level < 0) -1 else 1;
            }
            if (level > 2047) {
                level = 2047;
            } else if (level < -2048) {
                level = -2048;
            }

            // Save premultiplied coefficient
            self.block_data[de_zig_zagged] = level * tables.premultiplier_matrix[de_zig_zagged];
        }

        // Move block to its place
        var d: []u8 = undefined;
        var dw: i32 = undefined;
        var di: i32 = undefined;
        if (block < 4) {
            d = self.frame_current.y.data;
            dw = self.luma_width;
            di = (self.mb_row * self.luma_width + self.mb_col) << 4;
            if ((block & 1) != 0) {
                di += 8;
            }
            if ((block & 2) != 0) {
                di += self.luma_width << 3;
            }
        } else {
            d = if (block == 4) self.frame_current.cb.data else self.frame_current.cr.data;
            dw = self.chroma_width;
            di = ((self.mb_row * self.luma_width) << 2) + (self.mb_col << 3);
        }

        var s = self.block_data[0..];
        const si = 0;
        if (self.macroblock_intra) {
            // Overwrite (no prediction)
            if (n == 1) {
                const clamped = clampSignedToU8((s[0] + 128) >> 8);
                blockSet(u8, d, @intCast(di), @intCast(dw), u8, &.{clamped}, si, 1, 8, DcOnlyHandler{ .value = clamped });
                s[0] = 0;
            } else {
                idct(s);
                const clamped = clampSignedToU8(s[si]);
                blockSet(u8, d, @intCast(di), @intCast(dw), i32, s, si, 1, 8, DcOnlyHandler{ .value = clamped });
                @memset(&self.block_data, 0);
            }
        } else {
            // Add data to the predicted macroblock
            if (n == 1) {
                const value = (s[0] + 128) >> 8;
                const clamped = clampSignedToU8(d[@intCast(di)] + value);
                blockSet(u8, d, @intCast(di), @intCast(dw), i32, s, si, 1, 8, DcOnlyHandler{ .value = clamped });
                s[0] = 0;
            } else {
                idct(s);
                const clamped = clampSignedToU8(d[@intCast(di)] + s[si]);
                blockSet(u8, d, @intCast(di), @intCast(dw), i32, s, si, 1, 8, DcOnlyHandler{ .value = clamped });
                @memset(&self.block_data, 0);
            }
        }
    }

    fn decodeMotionVectors(self: *Video) void {
        // forward
        if (self.motion_forward.is_set) {
            const r_size = self.motion_forward.r_size;
            self.motion_forward.h = self.decodeMotionVector(r_size, self.motion_forward.h);
            self.motion_forward.v = self.decodeMotionVector(r_size, self.motion_forward.v);
        } else if (self.picture_type == @intFromEnum(PictureType.predictive)) {
            // No motion information in P-picture, reset vectors
            self.motion_forward.h = 0;
            self.motion_forward.v = 0;
        }

        if (self.motion_backward.is_set) {
            const r_size = self.motion_backward.r_size;
            self.motion_backward.h = self.decodeMotionVector(r_size, self.motion_backward.h);
            self.motion_backward.v = self.decodeMotionVector(r_size, self.motion_backward.v);
        }
    }

    fn decodeMotionVector(self: *Video, r_size: i32, motion: i32) i32 {
        var m = motion;
        const fscale = @as(i32, 1) << @intCast(r_size);
        const m_code = self.reader.readVlc(&tables.motion) catch return m;
        var r: i32 = 0;
        var d: i32 = 0;

        if ((m_code != 0) and (fscale != 1)) {
            r = @intCast(self.reader.readBits(@intCast(r_size)) catch return m);
            d = ((@abs(m_code) - 1) << @intCast(r_size)) + r + 1;
            if (m_code < 0) {
                d = -d;
            }
        } else {
            d = m_code;
        }

        m += d;
        if (m > (fscale << 4) - 1) {
            m -= fscale << 5;
        } else if (m < @as(i32, @intCast(@as(i64, @bitCast(~@as(i64, @intCast(fscale)))) << 4))) {
            m += fscale << 5;
        }
        return m;
    }

    fn predictMacroblock(self: *Video) void {
        var fw_h = self.motion_forward.h;
        var fw_v = self.motion_forward.v;

        if (self.motion_forward.full_px != 0) {
            fw_h <<= 1;
            fw_v <<= 1;
        }

        if (self.picture_type == @intFromEnum(PictureType.b)) {
            var bw_h = self.motion_backward.h;
            var bw_v = self.motion_backward.v;

            if (self.motion_backward.full_px != 0) {
                bw_h <<= 1;
                bw_v <<= 1;
            }

            if (self.motion_backward.is_set) {
                self.copyMacroblock(&self.frame_forward, fw_h, fw_v);
                if (self.motion_backward.is_set) {
                    self.interpolateMacroblock(&self.frame_backward, bw_h, bw_v);
                }
            } else {
                self.copyMacroblock(&self.frame_backward, bw_h, bw_v);
            }
        } else {
            self.copyMacroblock(&self.frame_forward, fw_h, fw_v);
        }
    }

    fn processMacroblock(
        self: *Video,
        source: []const u8,
        dest: []u8,
        motion_h: i32,
        motion_v: i32,
        block_size: usize,
        interpolate: bool,
    ) void {
        if (self.mb_width == 0 or self.mb_height == 0) return;

        const block_size_i = @as(i64, @intCast(block_size));
        const mb_width_i = @as(i64, self.mb_width);
        const mb_height_i = @as(i64, self.mb_height);
        const dw = mb_width_i * block_size_i;
        const hp = (@as(i64, motion_h)) >> 1;
        const vp = (@as(i64, motion_v)) >> 1;
        const odd_h = (motion_h & 1) != 0;
        const odd_v = (motion_v & 1) != 0;

        const si = ((@as(i64, self.mb_row) * block_size_i) + vp) * dw + (@as(i64, self.mb_col) * block_size_i) + hp;
        const di = ((@as(i64, self.mb_row) * dw) + @as(i64, self.mb_col)) * block_size_i;
        const max_address = dw * ((mb_height_i * block_size_i) - block_size_i + 1) - block_size_i;

        if (si < 0 or di < 0 or si > max_address or di > max_address) return;

        const stride = @as(usize, @intCast(dw));
        if (stride == 0) return;

        const src_index = @as(usize, @intCast(si));
        const dst_index = @as(usize, @intCast(di));
        if (src_index >= source.len or dst_index >= dest.len) return;

        const case_id: u3 = (@as(u3, if (interpolate) 1 else 0) << 2) |
            (@as(u3, if (odd_h) 1 else 0) << 1) |
            @as(u3, if (odd_v) 1 else 0);

        switch (case_id) {
            0 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, CopyHandler{}),
            1 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, AvgVerticalHandler{ .stride = stride }),
            2 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, AvgHorizontalHandler{}),
            3 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, AvgBilinearHandler{ .stride = stride }),
            4 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, InterpCopyHandler{}),
            5 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, InterpVerticalHandler{ .stride = stride }),
            6 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, InterpHorizontalHandler{}),
            7 => blockSet(u8, dest, dst_index, stride, u8, source, src_index, stride, block_size, InterpBilinearHandler{ .stride = stride }),
        }
    }

    fn copyMacroblock(self: *Video, frame: *Frame, h: i32, v: i32) void {
        const d = &self.frame_current;
        self.processMacroblock(frame.y.data, d.y.data, h, v, 16, false);
        self.processMacroblock(frame.cr.data, d.cr.data, @divTrunc(h, 2), @divTrunc(v, 2), 8, false);
        self.processMacroblock(frame.cb.data, d.cb.data, @divTrunc(h, 2), @divTrunc(v, 2), 8, false);
    }

    fn interpolateMacroblock(self: *Video, frame: *Frame, h: i32, v: i32) void {
        const d = &self.frame_current;
        self.processMacroblock(frame.y.data, d.y.data, h, v, 16, true);
        self.processMacroblock(frame.cr.data, d.cr.data, @divTrunc(h, 2), @divTrunc(v, 2), 8, true);
        self.processMacroblock(frame.cb.data, d.cb.data, @divTrunc(h, 2), @divTrunc(v, 2), 8, true);
    }

    fn initFrame(self: *Video, frame: *Frame, base: []u8) void {
        const luma_plane_size = self.luma_width * self.luma_height;
        const chroma_plane_size = self.chroma_width * self.chroma_height;

        frame.width = @intCast(self.width);
        frame.height = @intCast(self.height);
        frame.y.width = self.luma_width;
        frame.y.height = self.luma_height;
        frame.y.data = base;

        frame.cr.width = self.chroma_width;
        frame.cr.height = self.chroma_height;
        frame.cr.data = base[@intCast(luma_plane_size)..];

        frame.cb.width = self.chroma_width;
        frame.cb.height = self.chroma_height;
        frame.cb.data = base[@intCast(luma_plane_size + chroma_plane_size)..];
    }

    fn hasHeaders(self: *Video) !bool {
        if (self.has_sequence_header) return true;

        if (self.start_code != @intFromEnum(types.StartCode.sequence)) {
            self.start_code = self.reader.findStartCode(@intFromEnum(types.StartCode.sequence)) orelse return false;
        }

        if (!try self.decodeSequenceHeader()) return false;

        return true;
    }
};

inline fn clampSignedToU8(value: i32) u8 {
    if (value > 255) return 255;
    if (value < 0) return 0;
    return @intCast(value);
}

fn idct(block: []i32) void {
    var b1: i32 = undefined;
    var b3: i32 = undefined;
    var b4: i32 = undefined;
    var b6: i32 = undefined;
    var b7: i32 = undefined;
    var tmp1: i32 = undefined;
    var tmp2: i32 = undefined;
    var m0: i32 = undefined;
    var x0: i32 = undefined;
    var x1: i32 = undefined;
    var x2: i32 = undefined;
    var x3: i32 = undefined;
    var x4: i32 = undefined;
    var y3: i32 = undefined;
    var y4: i32 = undefined;
    var y5: i32 = undefined;
    var y6: i32 = undefined;
    var y7: i32 = undefined;

    // transform colummns
    for (0..8) |i| {
        b1 = block[4 * 8 + i];
        b3 = block[2 * 8 + i] + block[6 * 8 + i];
        b4 = block[5 * 8 + i] - block[3 * 8 + i];
        tmp1 = block[1 * 8 + i] + block[7 * 8 + i];
        tmp2 = block[3 * 8 + i] + block[5 * 8 + i];
        b6 = block[1 * 8 + i] - block[7 * 8 + i];
        b7 = tmp1 + tmp2;
        m0 = block[0 * 8 + i];
        x4 = ((b6 * 473 - b4 * 196 + 128) >> 8) - b7;
        x0 = x4 - (((tmp1 - tmp2) * 362 + 128) >> 8);
        x1 = m0 - b1;
        x2 = (((block[2 * 8 + i] - block[6 * 8 + i]) * 362 + 128) >> 8) - b3;
        x3 = m0 + b1;
        y3 = x1 + x2;
        y4 = x3 + b3;
        y5 = x1 - x2;
        y6 = x3 - b3;
        y7 = -x0 - ((b4 * 473 + b6 * 196 + 128) >> 8);
        block[0 * 8 + i] = b7 + y4;
        block[1 * 8 + i] = x4 + y3;
        block[2 * 8 + i] = y5 - x0;
        block[3 * 8 + i] = y6 - y7;
        block[4 * 8 + i] = y6 + y7;
        block[5 * 8 + i] = x0 + y5;
        block[6 * 8 + i] = y3 - x4;
        block[7 * 8 + i] = y4 - y3;
    }

    // transform rows
    var i: usize = 0;
    while (i < 64) : (i += 8) {
        b1 = block[i + 4];
        b3 = block[i + 2] + block[i + 6];
        b4 = block[i + 5] - block[i + 3];
        tmp1 = block[i + 1] + block[i + 7];
        tmp2 = block[i + 3] + block[i + 5];
        b6 = block[i + 1] - block[i + 7];
        b7 = tmp1 + tmp2;
        m0 = block[i + 0];
        x4 = ((b6 * 473 - b4 * 196 + 128) >> 8) - b7;
        x0 = x4 - (((tmp1 - tmp2) * 362 + 128) >> 8);
        x1 = m0 - b1;
        x2 = (((block[i + 2] - block[i + 6]) * 362 + 128) >> 8) - b3;
        x3 = m0 + b1;
        y3 = x1 + x2;
        y4 = x3 + b3;
        y5 = x1 - x2;
        y6 = x3 - b3;
        y7 = -x0 - ((b4 * 473 + b6 * 196 + 128) >> 8);
        block[i + 0] = (b7 + y4 + 128) >> 8;
        block[i + 1] = (x4 + y3 + 128) >> 8;
        block[i + 2] = (y5 - x0 + 128) >> 8;
        block[i + 3] = (y6 - y7 + 128) >> 8;
        block[i + 4] = (y6 + y7 + 128) >> 8;
        block[i + 5] = (x0 + y5 + 128) >> 8;
        block[i + 6] = (y3 - x4 + 128) >> 8;
        block[i + 7] = (y4 - y3 + 128) >> 8;
    }
}

fn codeIsSlice(code: i32) bool {
    return code >= @intFromEnum(types.StartCode.slice_first) and code <= @intFromEnum(types.StartCode.slice_last);
}

fn blockSet(
    comptime DestT: type,
    dest: []DestT,
    dest_index: usize,
    dest_width: usize,
    comptime SourceT: type,
    source: []const SourceT,
    source_index: usize,
    source_width: usize,
    block_size: usize,
    handler: anytype,
) void {
    if (block_size == 0) return;
    var di = dest_index;
    var si = source_index;
    if (di >= dest.len or si >= source.len) return;

    const dest_scan = dest_width - block_size;
    const source_scan = source_width - block_size;
    var y: usize = 0;
    while (y < block_size) : (y += 1) {
        var x: usize = 0;
        while (x < block_size) : (x += 1) {
            if (si >= source.len or di >= dest.len) return;
            dest[di] = handler.apply(DestT, SourceT, dest, di, source, si);
            si += 1;
            di += 1;
        }
        si = si + source_scan;
        di = di + dest_scan;
    }
}

const CopyHandler = struct {
    fn apply(
        _: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        _: []const DestT,
        _: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        return @intCast(source[si]);
    }
};

const DcOnlyHandler = struct {
    value: u8,
    fn apply(
        self: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        _: []const DestT,
        _: usize,
        _: []const SourceT,
        _: usize,
    ) DestT {
        return @intCast(self.value);
    }
};

const AvgVerticalHandler = struct {
    stride: usize,
    fn apply(
        self: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        _: []const DestT,
        _: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        const a: DestT = @intCast(source[si]);
        const b: DestT = @intCast(source[si + self.stride]);
        return @intCast((@as(u16, a) + @as(u16, b) + 1) >> 1);
    }
};

const AvgHorizontalHandler = struct {
    fn apply(
        _: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        _: []const DestT,
        _: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        const a: DestT = @intCast(source[si]);
        const b: DestT = @intCast(source[si + 1]);
        return @intCast((@as(u16, a) + @as(u16, b) + 1) >> 1);
    }
};

const AvgBilinearHandler = struct {
    stride: usize,
    fn apply(
        self: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        _: []const DestT,
        _: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        const a: DestT = @intCast(source[si]);
        const b: DestT = @intCast(source[si + 1]);
        const c: DestT = @intCast(source[si + self.stride]);
        const d: DestT = @intCast(source[si + self.stride + 1]);
        return @intCast((@as(u16, a) + @as(u16, b) + @as(u16, c) + @as(u16, d) + 2) >> 2);
    }
};

const InterpCopyHandler = struct {
    fn apply(
        _: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        dest: []const DestT,
        di: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        const a: DestT = dest[di];
        const b: DestT = @intCast(source[si]);
        return @intCast((@as(u16, a) + @as(u16, b) + 1) >> 1);
    }
};

const InterpVerticalHandler = struct {
    stride: usize,
    fn apply(
        self: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        dest: []const DestT,
        di: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        const a: DestT = @intCast(source[si]);
        const b: DestT = @intCast(source[si + self.stride]);
        const avg = (@as(u16, a) + @as(u16, b) + 1) >> 1;
        return @intCast((@as(u16, dest[di]) + avg + 1) >> 1);
    }
};

const InterpHorizontalHandler = struct {
    fn apply(
        _: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        dest: []const DestT,
        di: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        const a: DestT = @intCast(source[si]);
        const b: DestT = @intCast(source[si + 1]);
        const avg = (@as(u16, a) + @as(u16, b) + 1) >> 1;
        return @intCast((@as(u16, dest[di]) + avg + 1) >> 1);
    }
};

const InterpBilinearHandler = struct {
    stride: usize,
    fn apply(
        self: @This(),
        comptime DestT: type,
        comptime SourceT: type,
        dest: []const DestT,
        di: usize,
        source: []const SourceT,
        si: usize,
    ) DestT {
        const a = @as(u16, @intCast(source[si]));
        const b = @as(u16, @intCast(source[si + 1]));
        const c = @as(u16, @intCast(source[si + self.stride]));
        const d = @as(u16, @intCast(source[si + self.stride + 1]));
        const avg = (a + b + c + d + 2) >> 2;
        return @intCast((@as(u16, dest[di]) + avg + 1) >> 1);
    }
};

// Decoded Video Frame
// width and height denote the desired display size of the frame. This may be
// different from the internal size of the 3 planes.
pub const Frame = struct {
    time: f64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    y: Plane = .{},
    cr: Plane = .{},
    cb: Plane = .{},
};

// Decoded Video Plane
// The byte length of the data is width * height. Note that different planes
// have different sizes: the Luma plane (Y) is double the size of each of
// the two Chroma planes (Cr, Cb) - i.e. 4 times the byte length.
// Also note that the size of the plane does *not* denote the size of the
// displayed frame. The sizes of planes are always rounded up to the nearest
// macroblock (16px).
pub const Plane = struct {
    width: i32 = 0,
    height: i32 = 0,
    data: []u8 = &[_]u8{},
};

const Motion = struct {
    full_px: i32 = 0,
    is_set: bool = false,
    r_size: i32 = 0,
    h: i32 = 0,
    v: i32 = 0,
};
