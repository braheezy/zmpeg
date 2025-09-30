const Vlc = @import("root.zig").Vlc;
const VlcUint = @import("root.zig").VlcUint;

pub const pixel_aspect_ratio = [_]f32{
    1.0000, // square pixels
    0.6735, // 3:4?
    0.7031, // MPEG-1 / MPEG-2 video encoding divergence?
    0.7615,
    0.8055,
    0.8437,
    0.8935,
    0.9157,
    0.9815,
    1.0255,
    1.0695,
    1.0950,
    1.1575,
    1.2051,
};

pub const picture_rate = [_]f64{
    0.000,
    23.976,
    24.000,
    25.000,
    29.970,
    30.000,
    50.000,
    59.940,
    60.000,
    0.000,
    0.000,
    0.000,
    0.000,
    0.000,
    0.000,
    0.000,
};

pub const zig_zag = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

pub const intra_quant_matrix = [_]u8{
    8,  16, 19, 22, 26, 27, 29, 34,
    16, 16, 22, 24, 27, 29, 34, 37,
    19, 22, 26, 27, 29, 34, 34, 38,
    22, 22, 26, 27, 29, 34, 37, 40,
    22, 26, 27, 29, 32, 35, 40, 48,
    26, 27, 29, 32, 35, 40, 48, 58,
    26, 27, 29, 34, 38, 46, 56, 69,
    27, 29, 35, 38, 46, 56, 69, 83,
};

pub const non_intra_quant_matrix = [_]u8{
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
    16, 16, 16, 16, 16, 16, 16, 16,
};

pub const premultiplier_matrix = [_]u8{
    32, 44, 42, 38, 32, 25, 17, 9,
    44, 62, 58, 52, 44, 35, 24, 12,
    42, 58, 55, 49, 42, 33, 23, 12,
    38, 52, 49, 44, 38, 30, 20, 10,
    32, 44, 42, 38, 32, 25, 17, 9,
    25, 35, 33, 30, 25, 20, 14, 7,
    17, 24, 23, 20, 17, 14, 9,  5,
    9,  12, 12, 10, 9,  7,  5,  2,
};

pub const macroblock_address_increment = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 0, .value = 1 }, //   0: x
    .{ .index = 2 << 1, .value = 0 }, .{ .index = 3 << 1, .value = 0 }, //   1: 0x
    .{ .index = 4 << 1, .value = 0 }, .{ .index = 5 << 1, .value = 0 }, //   2: 00x
    .{ .index = 0, .value = 3 }, .{ .index = 0, .value = 2 }, //   3: 01x
    .{ .index = 6 << 1, .value = 0 }, .{ .index = 7 << 1, .value = 0 }, //   4: 000x
    .{ .index = 0, .value = 5 }, .{ .index = 0, .value = 4 }, //   5: 001x
    .{ .index = 8 << 1, .value = 0 }, .{ .index = 9 << 1, .value = 0 }, //   6: 0000x
    .{ .index = 0, .value = 7 }, .{ .index = 0, .value = 6 }, //   7: 0001x
    .{ .index = 10 << 1, .value = 0 }, .{ .index = 11 << 1, .value = 0 }, //   8: 0000 0x
    .{ .index = 12 << 1, .value = 0 }, .{ .index = 13 << 1, .value = 0 }, //   9: 0000 1x
    .{ .index = 14 << 1, .value = 0 }, .{ .index = 15 << 1, .value = 0 }, //  10: 0000 00x
    .{ .index = 16 << 1, .value = 0 }, .{ .index = 17 << 1, .value = 0 }, //  11: 0000 01x
    .{ .index = 18 << 1, .value = 0 }, .{ .index = 19 << 1, .value = 0 }, //  12: 0000 10x
    .{ .index = 0, .value = 9 }, .{ .index = 0, .value = 8 }, //  13: 0000 11x
    .{ .index = -1, .value = 0 }, .{ .index = 20 << 1, .value = 0 }, //  14: 0000 000x
    .{ .index = -1, .value = 0 }, .{ .index = 21 << 1, .value = 0 }, //  15: 0000 001x
    .{ .index = 22 << 1, .value = 0 }, .{ .index = 23 << 1, .value = 0 }, //  16: 0000 010x
    .{ .index = 0, .value = 15 }, .{ .index = 0, .value = 14 }, //  17: 0000 011x
    .{ .index = 0, .value = 13 }, .{ .index = 0, .value = 12 }, //  18: 0000 100x
    .{ .index = 0, .value = 11 }, .{ .index = 0, .value = 10 }, //  19: 0000 101x
    .{ .index = 24 << 1, .value = 0 }, .{ .index = 25 << 1, .value = 0 }, //  20: 0000 0001x
    .{ .index = 26 << 1, .value = 0 }, .{ .index = 27 << 1, .value = 0 }, //  21: 0000 0011x
    .{ .index = 28 << 1, .value = 0 }, .{ .index = 29 << 1, .value = 0 }, //  22: 0000 0100x
    .{ .index = 30 << 1, .value = 0 }, .{ .index = 31 << 1, .value = 0 }, //  23: 0000 0101x
    .{ .index = 32 << 1, .value = 0 }, .{ .index = -1, .value = 0 }, //  24: 0000 0001 0x
    .{ .index = -1, .value = 0 }, .{ .index = 33 << 1, .value = 0 }, //  25: 0000 0001 1x
    .{ .index = 34 << 1, .value = 0 }, .{ .index = 35 << 1, .value = 0 }, //  26: 0000 0011 0x
    .{ .index = 36 << 1, .value = 0 }, .{ .index = 37 << 1, .value = 0 }, //  27: 0000 0011 1x
    .{ .index = 38 << 1, .value = 0 }, .{ .index = 39 << 1, .value = 0 }, //  28: 0000 0100 0x
    .{ .index = 0, .value = 21 }, .{ .index = 0, .value = 20 }, //  29: 0000 0100 1x
    .{ .index = 0, .value = 19 }, .{ .index = 0, .value = 18 }, //  30: 0000 0101 0x
    .{ .index = 0, .value = 17 }, .{ .index = 0, .value = 16 }, //  31: 0000 0101 1x
    .{ .index = 0, .value = 35 }, .{ .index = -1, .value = 0 }, //  32: 0000 0001 00x
    .{ .index = -1, .value = 0 }, .{ .index = 0, .value = 34 }, //  33: 0000 0001 11x
    .{ .index = 0, .value = 33 }, .{ .index = 0, .value = 32 }, //  34: 0000 0011 00x
    .{ .index = 0, .value = 31 }, .{ .index = 0, .value = 30 }, //  35: 0000 0011 01x
    .{ .index = 0, .value = 29 }, .{ .index = 0, .value = 28 }, //  36: 0000 0011 10x
    .{ .index = 0, .value = 27 }, .{ .index = 0, .value = 26 }, //  37: 0000 0011 11x
    .{ .index = 0, .value = 25 }, .{ .index = 0, .value = 24 }, //  38: 0000 0100 00x
    .{ .index = 0, .value = 23 }, .{ .index = 0, .value = 22 }, //  39: 0000 0100 01x
};

pub var macroblock_type_intra = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 0, .value = 0x01 }, //   0: x
    .{ .index = -1, .value = 0 }, .{ .index = 0, .value = 0x11 }, //   1: 0x
};

pub var macroblock_type_predictive = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 0, .value = 0x0a }, //   0: x
    .{ .index = 2 << 1, .value = 0 }, .{ .index = 0, .value = 0x02 }, //   1: 0x
    .{ .index = 3 << 1, .value = 0 }, .{ .index = 0, .value = 0x08 }, //   2: 00x
    .{ .index = 4 << 1, .value = 0 }, .{ .index = 5 << 1, .value = 0 }, //   3: 000x
    .{ .index = 6 << 1, .value = 0 }, .{ .index = 0, .value = 0x12 }, //   4: 0000x
    .{ .index = 0, .value = 0x1a }, .{ .index = 0, .value = 0x01 }, //   5: 0001x
    .{ .index = -1, .value = 0 }, .{ .index = 0, .value = 0x11 }, //   6: 0000 0x
};

pub var macroblock_type_b = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 2 << 1, .value = 0 }, //   0: x
    .{ .index = 3 << 1, .value = 0 }, .{ .index = 4 << 1, .value = 0 }, //   1: 0x
    .{ .index = 0, .value = 0x0c }, .{ .index = 0, .value = 0x0e }, //   2: 1x
    .{ .index = 5 << 1, .value = 0 }, .{ .index = 6 << 1, .value = 0 }, //   3: 00x
    .{ .index = 0, .value = 0x04 }, .{ .index = 0, .value = 0x06 }, //   4: 01x
    .{ .index = 7 << 1, .value = 0 }, .{ .index = 8 << 1, .value = 0 }, //   5: 000x
    .{ .index = 0, .value = 0x08 }, .{ .index = 0, .value = 0x0a }, //   6: 001x
    .{ .index = 9 << 1, .value = 0 }, .{ .index = 10 << 1, .value = 0 }, //   7: 0000x
    .{ .index = 0, .value = 0x1e }, .{ .index = 0, .value = 0x01 }, //   8: 0001x
    .{ .index = -1, .value = 0 }, .{ .index = 0, .value = 0x11 }, //   9: 0000 0x
    .{ .index = 0, .value = 0x16 }, .{ .index = 0, .value = 0x1a }, //  10: 0000 1x
};

pub const macroblock_type = [_]?[]Vlc{ null, &macroblock_type_intra, &macroblock_type_predictive, &macroblock_type_b };

pub const code_block_pattern = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 2 << 1, .value = 0 }, //   0: x
    .{ .index = 3 << 1, .value = 0 }, .{ .index = 4 << 1, .value = 0 }, //   1: 0x
    .{ .index = 5 << 1, .value = 0 }, .{ .index = 6 << 1, .value = 0 }, //   2: 1x
    .{ .index = 7 << 1, .value = 0 }, .{ .index = 8 << 1, .value = 0 }, //   3: 00x
    .{ .index = 9 << 1, .value = 0 }, .{ .index = 10 << 1, .value = 0 }, //   4: 01x
    .{ .index = 11 << 1, .value = 0 }, .{ .index = 12 << 1, .value = 0 }, //   5: 10x
    .{ .index = 13 << 1, .value = 0 }, .{ .index = 0, .value = 60 }, //   6: 11x
    .{ .index = 14 << 1, .value = 0 }, .{ .index = 15 << 1, .value = 0 }, //   7: 000x
    .{ .index = 16 << 1, .value = 0 }, .{ .index = 17 << 1, .value = 0 }, //   8: 001x
    .{ .index = 18 << 1, .value = 0 }, .{ .index = 19 << 1, .value = 0 }, //   9: 010x
    .{ .index = 20 << 1, .value = 0 }, .{ .index = 21 << 1, .value = 0 }, //  10: 011x
    .{ .index = 22 << 1, .value = 0 }, .{ .index = 23 << 1, .value = 0 }, //  11: 100x
    .{ .index = 0, .value = 32 }, .{ .index = 0, .value = 16 }, //  12: 101x
    .{ .index = 0, .value = 8 }, .{ .index = 0, .value = 4 }, //  13: 110x
    .{ .index = 24 << 1, .value = 0 }, .{ .index = 25 << 1, .value = 0 }, //  14: 0000x
    .{ .index = 26 << 1, .value = 0 }, .{ .index = 27 << 1, .value = 0 }, //  15: 0001x
    .{ .index = 28 << 1, .value = 0 }, .{ .index = 29 << 1, .value = 0 }, //  16: 0010x
    .{ .index = 30 << 1, .value = 0 }, .{ .index = 31 << 1, .value = 0 }, //  17: 0011x
    .{ .index = 0, .value = 62 }, .{ .index = 0, .value = 2 }, //  18: 0100x
    .{ .index = 0, .value = 61 }, .{ .index = 0, .value = 1 }, //  19: 0101x
    .{ .index = 0, .value = 56 }, .{ .index = 0, .value = 52 }, //  20: 0110x
    .{ .index = 0, .value = 44 }, .{ .index = 0, .value = 28 }, //  21: 0111x
    .{ .index = 0, .value = 40 }, .{ .index = 0, .value = 20 }, //  22: 1000x
    .{ .index = 0, .value = 48 }, .{ .index = 0, .value = 12 }, //  23: 1001x
    .{ .index = 32 << 1, .value = 0 }, .{ .index = 33 << 1, .value = 0 }, //  24: 0000 0x
    .{ .index = 34 << 1, .value = 0 }, .{ .index = 35 << 1, .value = 0 }, //  25: 0000 1x
    .{ .index = 36 << 1, .value = 0 }, .{ .index = 37 << 1, .value = 0 }, //  26: 0001 0x
    .{ .index = 38 << 1, .value = 0 }, .{ .index = 39 << 1, .value = 0 }, //  27: 0001 1x
    .{ .index = 40 << 1, .value = 0 }, .{ .index = 41 << 1, .value = 0 }, //  28: 0010 0x
    .{ .index = 42 << 1, .value = 0 }, .{ .index = 43 << 1, .value = 0 }, //  29: 0010 1x
    .{ .index = 0, .value = 63 }, .{ .index = 0, .value = 3 }, //  30: 0011 0x
    .{ .index = 0, .value = 36 }, .{ .index = 0, .value = 24 }, //  31: 0011 1x
    .{ .index = 44 << 1, .value = 0 }, .{ .index = 45 << 1, .value = 0 }, //  32: 0000 00x
    .{ .index = 46 << 1, .value = 0 }, .{ .index = 47 << 1, .value = 0 }, //  33: 0000 01x
    .{ .index = 48 << 1, .value = 0 }, .{ .index = 49 << 1, .value = 0 }, //  34: 0000 10x
    .{ .index = 50 << 1, .value = 0 }, .{ .index = 51 << 1, .value = 0 }, //  35: 0000 11x
    .{ .index = 52 << 1, .value = 0 }, .{ .index = 53 << 1, .value = 0 }, //  36: 0001 00x
    .{ .index = 54 << 1, .value = 0 }, .{ .index = 55 << 1, .value = 0 }, //  37: 0001 01x
    .{ .index = 56 << 1, .value = 0 }, .{ .index = 57 << 1, .value = 0 }, //  38: 0001 10x
    .{ .index = 58 << 1, .value = 0 }, .{ .index = 59 << 1, .value = 0 }, //  39: 0001 11x
    .{ .index = 0, .value = 34 }, .{ .index = 0, .value = 18 }, //  40: 0010 00x
    .{ .index = 0, .value = 10 }, .{ .index = 0, .value = 6 }, //  41: 0010 01x
    .{ .index = 0, .value = 33 }, .{ .index = 0, .value = 17 }, //  42: 0010 10x
    .{ .index = 0, .value = 9 }, .{ .index = 0, .value = 5 }, //  43: 0010 11x
    .{ .index = -1, .value = 0 }, .{ .index = 60 << 1, .value = 0 }, //  44: 0000 000x
    .{ .index = 61 << 1, .value = 0 }, .{ .index = 62 << 1, .value = 0 }, //  45: 0000 001x
    .{ .index = 0, .value = 58 }, .{ .index = 0, .value = 54 }, //  46: 0000 010x
    .{ .index = 0, .value = 46 }, .{ .index = 0, .value = 30 }, //  47: 0000 011x
    .{ .index = 0, .value = 57 }, .{ .index = 0, .value = 53 }, //  48: 0000 100x
    .{ .index = 0, .value = 45 }, .{ .index = 0, .value = 29 }, //  49: 0000 101x
    .{ .index = 0, .value = 38 }, .{ .index = 0, .value = 26 }, //  50: 0000 110x
    .{ .index = 0, .value = 37 }, .{ .index = 0, .value = 25 }, //  51: 0000 111x
    .{ .index = 0, .value = 43 }, .{ .index = 0, .value = 23 }, //  52: 0001 000x
    .{ .index = 0, .value = 51 }, .{ .index = 0, .value = 15 }, //  53: 0001 001x
    .{ .index = 0, .value = 42 }, .{ .index = 0, .value = 22 }, //  54: 0001 010x
    .{ .index = 0, .value = 50 }, .{ .index = 0, .value = 14 }, //  55: 0001 011x
    .{ .index = 0, .value = 41 }, .{ .index = 0, .value = 21 }, //  56: 0001 100x
    .{ .index = 0, .value = 49 }, .{ .index = 0, .value = 13 }, //  57: 0001 101x
    .{ .index = 0, .value = 35 }, .{ .index = 0, .value = 19 }, //  58: 0001 110x
    .{ .index = 0, .value = 11 }, .{ .index = 0, .value = 7 }, //  59: 0001 111x
    .{ .index = 0, .value = 39 }, .{ .index = 0, .value = 27 }, //  60: 0000 0001x
    .{ .index = 0, .value = 59 }, .{ .index = 0, .value = 55 }, //  61: 0000 0010x
    .{ .index = 0, .value = 47 }, .{ .index = 0, .value = 31 }, //  62: 0000 0011x
};

pub const motion = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 0, .value = 0 }, //   0: x
    .{ .index = 2 << 1, .value = 0 }, .{ .index = 3 << 1, .value = 0 }, //   1: 0x
    .{ .index = 4 << 1, .value = 0 }, .{ .index = 5 << 1, .value = 0 }, //   2: 00x
    .{ .index = 0, .value = 1 }, .{ .index = 0, .value = -1 }, //   3: 01x
    .{ .index = 6 << 1, .value = 0 }, .{ .index = 7 << 1, .value = 0 }, //   4: 000x
    .{ .index = 0, .value = 2 }, .{ .index = 0, .value = -2 }, //   5: 001x
    .{ .index = 8 << 1, .value = 0 }, .{ .index = 9 << 1, .value = 0 }, //   6: 0000x
    .{ .index = 0, .value = 3 }, .{ .index = 0, .value = -3 }, //   7: 0001x
    .{ .index = 10 << 1, .value = 0 }, .{ .index = 11 << 1, .value = 0 }, //   8: 0000 0x
    .{ .index = 12 << 1, .value = 0 }, .{ .index = 13 << 1, .value = 0 }, //   9: 0000 1x
    .{ .index = -1, .value = 0 }, .{ .index = 14 << 1, .value = 0 }, //  10: 0000 00x
    .{ .index = 15 << 1, .value = 0 }, .{ .index = 16 << 1, .value = 0 }, //  11: 0000 01x
    .{ .index = 17 << 1, .value = 0 }, .{ .index = 18 << 1, .value = 0 }, //  12: 0000 10x
    .{ .index = 0, .value = 4 }, .{ .index = 0, .value = -4 }, //  13: 0000 11x
    .{ .index = -1, .value = 0 }, .{ .index = 19 << 1, .value = 0 }, //  14: 0000 001x
    .{ .index = 20 << 1, .value = 0 }, .{ .index = 21 << 1, .value = 0 }, //  15: 0000 010x
    .{ .index = 0, .value = 7 }, .{ .index = 0, .value = -7 }, //  16: 0000 011x
    .{ .index = 0, .value = 6 }, .{ .index = 0, .value = -6 }, //  17: 0000 100x
    .{ .index = 0, .value = 5 }, .{ .index = 0, .value = -5 }, //  18: 0000 101x
    .{ .index = 22 << 1, .value = 0 }, .{ .index = 23 << 1, .value = 0 }, //  19: 0000 0011x
    .{ .index = 24 << 1, .value = 0 }, .{ .index = 25 << 1, .value = 0 }, //  20: 0000 0100x
    .{ .index = 26 << 1, .value = 0 }, .{ .index = 27 << 1, .value = 0 }, //  21: 0000 0101x
    .{ .index = 28 << 1, .value = 0 }, .{ .index = 29 << 1, .value = 0 }, //  22: 0000 0011 0x
    .{ .index = 30 << 1, .value = 0 }, .{ .index = 31 << 1, .value = 0 }, //  23: 0000 0011 1x
    .{ .index = 32 << 1, .value = 0 }, .{ .index = 33 << 1, .value = 0 }, //  24: 0000 0100 0x
    .{ .index = 0, .value = 10 }, .{ .index = 0, .value = -10 }, //  25: 0000 0100 1x
    .{ .index = 0, .value = 9 }, .{ .index = 0, .value = -9 }, //  26: 0000 0101 0x
    .{ .index = 0, .value = 8 }, .{ .index = 0, .value = -8 }, //  27: 0000 0101 1x
    .{ .index = 0, .value = 16 }, .{ .index = 0, .value = -16 }, //  28: 0000 0011 00x
    .{ .index = 0, .value = 15 }, .{ .index = 0, .value = -15 }, //  29: 0000 0011 01x
    .{ .index = 0, .value = 14 }, .{ .index = 0, .value = -14 }, //  30: 0000 0011 10x
    .{ .index = 0, .value = 13 }, .{ .index = 0, .value = -13 }, //  31: 0000 0011 11x
    .{ .index = 0, .value = 12 }, .{ .index = 0, .value = -12 }, //  32: 0000 0100 00x
    .{ .index = 0, .value = 11 }, .{ .index = 0, .value = -11 }, //  33: 0000 0100 01x
};

pub var dct_size_luminance = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 2 << 1, .value = 0 }, //   0: x
    .{ .index = 0, .value = 1 }, .{ .index = 0, .value = 2 }, //   1: 0x
    .{ .index = 3 << 1, .value = 0 }, .{ .index = 4 << 1, .value = 0 }, //   2: 1x
    .{ .index = 0, .value = 0 }, .{ .index = 0, .value = 3 }, //   3: 10x
    .{ .index = 0, .value = 4 }, .{ .index = 5 << 1, .value = 0 }, //   4: 11x
    .{ .index = 0, .value = 5 }, .{ .index = 6 << 1, .value = 0 }, //   5: 111x
    .{ .index = 0, .value = 6 }, .{ .index = 7 << 1, .value = 0 }, //   6: 1111x
    .{ .index = 0, .value = 7 }, .{ .index = 8 << 1, .value = 0 }, //   7: 1111 1x
    .{ .index = 0, .value = 8 }, .{ .index = -1, .value = 0 }, //   8: 1111 11x
};

pub var dct_size_chrominance = [_]Vlc{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 2 << 1, .value = 0 }, //   0: x
    .{ .index = 0, .value = 0 }, .{ .index = 0, .value = 1 }, //   1: 0x
    .{ .index = 0, .value = 2 }, .{ .index = 3 << 1, .value = 0 }, //   2: 1x
    .{ .index = 0, .value = 3 }, .{ .index = 4 << 1, .value = 0 }, //   3: 11x
    .{ .index = 0, .value = 4 }, .{ .index = 5 << 1, .value = 0 }, //   4: 111x
    .{ .index = 0, .value = 5 }, .{ .index = 6 << 1, .value = 0 }, //   5: 1111x
    .{ .index = 0, .value = 6 }, .{ .index = 7 << 1, .value = 0 }, //   6: 1111 1x
    .{ .index = 0, .value = 7 }, .{ .index = 8 << 1, .value = 0 }, //   7: 1111 11x
    .{ .index = 0, .value = 8 }, .{ .index = -1, .value = 0 }, //   8: 1111 111x
};

pub const dct_size = [_][]Vlc{
    &dct_size_luminance,
    &dct_size_chrominance,
    &dct_size_chrominance,
};

//  Decoded values are unsigned. Sign bit follows in the stream.

pub const dct_coeff = [_]VlcUint{
    .{ .index = 1 << 1, .value = 0 }, .{ .index = 0, .value = 0x0001 }, //   0: x
    .{ .index = 2 << 1, .value = 0 }, .{ .index = 3 << 1, .value = 0 }, //   1: 0x
    .{ .index = 4 << 1, .value = 0 }, .{ .index = 5 << 1, .value = 0 }, //   2: 00x
    .{ .index = 6 << 1, .value = 0 }, .{ .index = 0, .value = 0x0101 }, //   3: 01x
    .{ .index = 7 << 1, .value = 0 }, .{ .index = 8 << 1, .value = 0 }, //   4: 000x
    .{ .index = 9 << 1, .value = 0 }, .{ .index = 10 << 1, .value = 0 }, //   5: 001x
    .{ .index = 0, .value = 0x0002 }, .{ .index = 0, .value = 0x0201 }, //   6: 010x
    .{ .index = 11 << 1, .value = 0 }, .{ .index = 12 << 1, .value = 0 }, //   7: 0000x
    .{ .index = 13 << 1, .value = 0 }, .{ .index = 14 << 1, .value = 0 }, //   8: 0001x
    .{ .index = 15 << 1, .value = 0 }, .{ .index = 0, .value = 0x0003 }, //   9: 0010x
    .{ .index = 0, .value = 0x0401 }, .{ .index = 0, .value = 0x0301 }, //  10: 0011x
    .{ .index = 16 << 1, .value = 0 }, .{ .index = 0, .value = 0xffff }, //  11: 0000 0x
    .{ .index = 17 << 1, .value = 0 }, .{ .index = 18 << 1, .value = 0 }, //  12: 0000 1x
    .{ .index = 0, .value = 0x0701 }, .{ .index = 0, .value = 0x0601 }, //  13: 0001 0x
    .{ .index = 0, .value = 0x0102 }, .{ .index = 0, .value = 0x0501 }, //  14: 0001 1x
    .{ .index = 19 << 1, .value = 0 }, .{ .index = 20 << 1, .value = 0 }, //  15: 0010 0x
    .{ .index = 21 << 1, .value = 0 }, .{ .index = 22 << 1, .value = 0 }, //  16: 0000 00x
    .{ .index = 0, .value = 0x0202 }, .{ .index = 0, .value = 0x0901 }, //  17: 0000 10x
    .{ .index = 0, .value = 0x0004 }, .{ .index = 0, .value = 0x0801 }, //  18: 0000 11x
    .{ .index = 23 << 1, .value = 0 }, .{ .index = 24 << 1, .value = 0 }, //  19: 0010 00x
    .{ .index = 25 << 1, .value = 0 }, .{ .index = 26 << 1, .value = 0 }, //  20: 0010 01x
    .{ .index = 27 << 1, .value = 0 }, .{ .index = 28 << 1, .value = 0 }, //  21: 0000 000x
    .{ .index = 29 << 1, .value = 0 }, .{ .index = 30 << 1, .value = 0 }, //  22: 0000 001x
    .{ .index = 0, .value = 0x0d01 }, .{ .index = 0, .value = 0x0006 }, //  23: 0010 000x
    .{ .index = 0, .value = 0x0c01 }, .{ .index = 0, .value = 0x0b01 }, //  24: 0010 001x
    .{ .index = 0, .value = 0x0302 }, .{ .index = 0, .value = 0x0103 }, //  25: 0010 010x
    .{ .index = 0, .value = 0x0005 }, .{ .index = 0, .value = 0x0a01 }, //  26: 0010 011x
    .{ .index = 31 << 1, .value = 0 }, .{ .index = 32 << 1, .value = 0 }, //  27: 0000 0000x
    .{ .index = 33 << 1, .value = 0 }, .{ .index = 34 << 1, .value = 0 }, //  28: 0000 0001x
    .{ .index = 35 << 1, .value = 0 }, .{ .index = 36 << 1, .value = 0 }, //  29: 0000 0010x
    .{ .index = 37 << 1, .value = 0 }, .{ .index = 38 << 1, .value = 0 }, //  30: 0000 0011x
    .{ .index = 39 << 1, .value = 0 }, .{ .index = 40 << 1, .value = 0 }, //  31: 0000 0000 0x
    .{ .index = 41 << 1, .value = 0 }, .{ .index = 42 << 1, .value = 0 }, //  32: 0000 0000 1x
    .{ .index = 43 << 1, .value = 0 }, .{ .index = 44 << 1, .value = 0 }, //  33: 0000 0001 0x
    .{ .index = 45 << 1, .value = 0 }, .{ .index = 46 << 1, .value = 0 }, //  34: 0000 0001 1x
    .{ .index = 0, .value = 0x1001 }, .{ .index = 0, .value = 0x0502 }, //  35: 0000 0010 0x
    .{ .index = 0, .value = 0x0007 }, .{ .index = 0, .value = 0x0203 }, //  36: 0000 0010 1x
    .{ .index = 0, .value = 0x0104 }, .{ .index = 0, .value = 0x0f01 }, //  37: 0000 0011 0x
    .{ .index = 0, .value = 0x0e01 }, .{ .index = 0, .value = 0x0402 }, //  38: 0000 0011 1x
    .{ .index = 47 << 1, .value = 0 }, .{ .index = 48 << 1, .value = 0 }, //  39: 0000 0000 00x
    .{ .index = 49 << 1, .value = 0 }, .{ .index = 50 << 1, .value = 0 }, //  40: 0000 0000 01x
    .{ .index = 51 << 1, .value = 0 }, .{ .index = 52 << 1, .value = 0 }, //  41: 0000 0000 10x
    .{ .index = 53 << 1, .value = 0 }, .{ .index = 54 << 1, .value = 0 }, //  42: 0000 0000 11x
    .{ .index = 55 << 1, .value = 0 }, .{ .index = 56 << 1, .value = 0 }, //  43: 0000 0001 00x
    .{ .index = 57 << 1, .value = 0 }, .{ .index = 58 << 1, .value = 0 }, //  44: 0000 0001 01x
    .{ .index = 59 << 1, .value = 0 }, .{ .index = 60 << 1, .value = 0 }, //  45: 0000 0001 10x
    .{ .index = 61 << 1, .value = 0 }, .{ .index = 62 << 1, .value = 0 }, //  46: 0000 0001 11x
    .{ .index = -1, .value = 0 }, .{ .index = 63 << 1, .value = 0 }, //  47: 0000 0000 000x
    .{ .index = 64 << 1, .value = 0 }, .{ .index = 65 << 1, .value = 0 }, //  48: 0000 0000 001x
    .{ .index = 66 << 1, .value = 0 }, .{ .index = 67 << 1, .value = 0 }, //  49: 0000 0000 010x
    .{ .index = 68 << 1, .value = 0 }, .{ .index = 69 << 1, .value = 0 }, //  50: 0000 0000 011x
    .{ .index = 70 << 1, .value = 0 }, .{ .index = 71 << 1, .value = 0 }, //  51: 0000 0000 100x
    .{ .index = 72 << 1, .value = 0 }, .{ .index = 73 << 1, .value = 0 }, //  52: 0000 0000 101x
    .{ .index = 74 << 1, .value = 0 }, .{ .index = 75 << 1, .value = 0 }, //  53: 0000 0000 110x
    .{ .index = 76 << 1, .value = 0 }, .{ .index = 77 << 1, .value = 0 }, //  54: 0000 0000 111x
    .{ .index = 0, .value = 0x000b }, .{ .index = 0, .value = 0x0802 }, //  55: 0000 0001 000x
    .{ .index = 0, .value = 0x0403 }, .{ .index = 0, .value = 0x000a }, //  56: 0000 0001 001x
    .{ .index = 0, .value = 0x0204 }, .{ .index = 0, .value = 0x0702 }, //  57: 0000 0001 010x
    .{ .index = 0, .value = 0x1501 }, .{ .index = 0, .value = 0x1401 }, //  58: 0000 0001 011x
    .{ .index = 0, .value = 0x0009 }, .{ .index = 0, .value = 0x1301 }, //  59: 0000 0001 100x
    .{ .index = 0, .value = 0x1201 }, .{ .index = 0, .value = 0x0105 }, //  60: 0000 0001 101x
    .{ .index = 0, .value = 0x0303 }, .{ .index = 0, .value = 0x0008 }, //  61: 0000 0001 110x
    .{ .index = 0, .value = 0x0602 }, .{ .index = 0, .value = 0x1101 }, //  62: 0000 0001 111x
    .{ .index = 78 << 1, .value = 0 }, .{ .index = 79 << 1, .value = 0 }, //  63: 0000 0000 0001x
    .{ .index = 80 << 1, .value = 0 }, .{ .index = 81 << 1, .value = 0 }, //  64: 0000 0000 0010x
    .{ .index = 82 << 1, .value = 0 }, .{ .index = 83 << 1, .value = 0 }, //  65: 0000 0000 0011x
    .{ .index = 84 << 1, .value = 0 }, .{ .index = 85 << 1, .value = 0 }, //  66: 0000 0000 0100x
    .{ .index = 86 << 1, .value = 0 }, .{ .index = 87 << 1, .value = 0 }, //  67: 0000 0000 0101x
    .{ .index = 88 << 1, .value = 0 }, .{ .index = 89 << 1, .value = 0 }, //  68: 0000 0000 0110x
    .{ .index = 90 << 1, .value = 0 }, .{ .index = 91 << 1, .value = 0 }, //  69: 0000 0000 0111x
    .{ .index = 0, .value = 0x0a02 }, .{ .index = 0, .value = 0x0902 }, //  70: 0000 0000 1000x
    .{ .index = 0, .value = 0x0503 }, .{ .index = 0, .value = 0x0304 }, //  71: 0000 0000 1001x
    .{ .index = 0, .value = 0x0205 }, .{ .index = 0, .value = 0x0107 }, //  72: 0000 0000 1010x
    .{ .index = 0, .value = 0x0106 }, .{ .index = 0, .value = 0x000f }, //  73: 0000 0000 1011x
    .{ .index = 0, .value = 0x000e }, .{ .index = 0, .value = 0x000d }, //  74: 0000 0000 1100x
    .{ .index = 0, .value = 0x000c }, .{ .index = 0, .value = 0x1a01 }, //  75: 0000 0000 1101x
    .{ .index = 0, .value = 0x1901 }, .{ .index = 0, .value = 0x1801 }, //  76: 0000 0000 1110x
    .{ .index = 0, .value = 0x1701 }, .{ .index = 0, .value = 0x1601 }, //  77: 0000 0000 1111x
    .{ .index = 92 << 1, .value = 0 }, .{ .index = 93 << 1, .value = 0 }, //  78: 0000 0000 0001 0x
    .{ .index = 94 << 1, .value = 0 }, .{ .index = 95 << 1, .value = 0 }, //  79: 0000 0000 0001 1x
    .{ .index = 96 << 1, .value = 0 }, .{ .index = 97 << 1, .value = 0 }, //  80: 0000 0000 0010 0x
    .{ .index = 98 << 1, .value = 0 }, .{ .index = 99 << 1, .value = 0 }, //  81: 0000 0000 0010 1x
    .{ .index = 100 << 1, .value = 0 }, .{ .index = 101 << 1, .value = 0 }, //  82: 0000 0000 0011 0x
    .{ .index = 102 << 1, .value = 0 }, .{ .index = 103 << 1, .value = 0 }, //  83: 0000 0000 0011 1x
    .{ .index = 0, .value = 0x001f }, .{ .index = 0, .value = 0x001e }, //  84: 0000 0000 0100 0x
    .{ .index = 0, .value = 0x001d }, .{ .index = 0, .value = 0x001c }, //  85: 0000 0000 0100 1x
    .{ .index = 0, .value = 0x001b }, .{ .index = 0, .value = 0x001a }, //  86: 0000 0000 0101 0x
    .{ .index = 0, .value = 0x0019 }, .{ .index = 0, .value = 0x0018 }, //  87: 0000 0000 0101 1x
    .{ .index = 0, .value = 0x0017 }, .{ .index = 0, .value = 0x0016 }, //  88: 0000 0000 0110 0x
    .{ .index = 0, .value = 0x0015 }, .{ .index = 0, .value = 0x0014 }, //  89: 0000 0000 0110 1x
    .{ .index = 0, .value = 0x0013 }, .{ .index = 0, .value = 0x0012 }, //  90: 0000 0000 0111 0x
    .{ .index = 0, .value = 0x0011 }, .{ .index = 0, .value = 0x0010 }, //  91: 0000 0000 0111 1x
    .{ .index = 104 << 1, .value = 0 }, .{ .index = 105 << 1, .value = 0 }, //  92: 0000 0000 0001 00x
    .{ .index = 106 << 1, .value = 0 }, .{ .index = 107 << 1, .value = 0 }, //  93: 0000 0000 0001 01x
    .{ .index = 108 << 1, .value = 0 }, .{ .index = 109 << 1, .value = 0 }, //  94: 0000 0000 0001 10x
    .{ .index = 110 << 1, .value = 0 }, .{ .index = 111 << 1, .value = 0 }, //  95: 0000 0000 0001 11x
    .{ .index = 0, .value = 0x0028 }, .{ .index = 0, .value = 0x0027 }, //  96: 0000 0000 0010 00x
    .{ .index = 0, .value = 0x0026 }, .{ .index = 0, .value = 0x0025 }, //  97: 0000 0000 0010 01x
    .{ .index = 0, .value = 0x0024 }, .{ .index = 0, .value = 0x0023 }, //  98: 0000 0000 0010 10x
    .{ .index = 0, .value = 0x0022 }, .{ .index = 0, .value = 0x0021 }, //  99: 0000 0000 0010 11x
    .{ .index = 0, .value = 0x0020 }, .{ .index = 0, .value = 0x010e }, // 100: 0000 0000 0011 00x
    .{ .index = 0, .value = 0x010d }, .{ .index = 0, .value = 0x010c }, // 101: 0000 0000 0011 01x
    .{ .index = 0, .value = 0x010b }, .{ .index = 0, .value = 0x010a }, // 102: 0000 0000 0011 10x
    .{ .index = 0, .value = 0x0109 }, .{ .index = 0, .value = 0x0108 }, // 103: 0000 0000 0011 11x
    .{ .index = 0, .value = 0x0112 }, .{ .index = 0, .value = 0x0111 }, // 104: 0000 0000 0001 000x
    .{ .index = 0, .value = 0x0110 }, .{ .index = 0, .value = 0x010f }, // 105: 0000 0000 0001 001x
    .{ .index = 0, .value = 0x0603 }, .{ .index = 0, .value = 0x1002 }, // 106: 0000 0000 0001 010x
    .{ .index = 0, .value = 0x0f02 }, .{ .index = 0, .value = 0x0e02 }, // 107: 0000 0000 0001 011x
    .{ .index = 0, .value = 0x0d02 }, .{ .index = 0, .value = 0x0c02 }, // 108: 0000 0000 0001 100x
    .{ .index = 0, .value = 0x0b02 }, .{ .index = 0, .value = 0x1f01 }, // 109: 0000 0000 0001 101x
    .{ .index = 0, .value = 0x1e01 }, .{ .index = 0, .value = 0x1d01 }, // 110: 0000 0000 0001 110x
    .{ .index = 0, .value = 0x1c01 }, .{ .index = 0, .value = 0x1b01 }, // 111: 0000 0000 0001 111x
};
