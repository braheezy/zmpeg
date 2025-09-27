const std = @import("std");

pub const BitReader = @This();
// Public interface we expose
reader: std.Io.Reader,
// bit-level state
bit_index: usize = 0,
// memory management
allocator: std.mem.Allocator,
// append-only buffer (APPEND mode) when present
append_list: ?std.ArrayList(u8) = null,
append_ended: bool = false,
// cached total size when known (file or fixed memory)
total_size: ?usize = null,
// internal file handle (for file mode)
file: ?std.fs.File = null,

pub fn init(allocator: std.mem.Allocator, buffer: []u8) BitReader {
    return BitReader{
        .reader = .{
            .vtable = &vtable,
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .allocator = allocator,
        .total_size = null,
    };
}

pub fn initFromFile(allocator: std.mem.Allocator, filename: []const u8) !BitReader {
    const file = try std.fs.cwd().openFile(filename, .{});
    const buffer = try allocator.alloc(u8, 8192); // Default buffer size
    var bit_reader = BitReader.init(allocator, buffer);
    bit_reader.file = file;
    bit_reader.total_size = @intCast(try file.getEndPos());
    try file.seekTo(0);
    return bit_reader;
}

pub fn initFromMemory(allocator: std.mem.Allocator, data: []const u8) BitReader {
    return BitReader{ .reader = std.Io.Reader.fixed(data), .allocator = allocator, .total_size = data.len };
}

pub fn initAppend(allocator: std.mem.Allocator, initial_capacity: usize) !BitReader {
    const list = std.ArrayList(u8).initCapacity(allocator, initial_capacity) catch return error.OutOfMemory;
    return BitReader{
        .reader = .{ .vtable = &vtable, .buffer = list.items, .seek = 0, .end = 0 },
        .allocator = allocator,
        .append_list = list,
        .append_ended = false,
        .total_size = null,
    };
}

pub fn append(self: *BitReader, data: []const u8) !void {
    if (self.append_list) |*list| {
        self.append_ended = false;
        try list.appendSlice(self.allocator, data);
        // Refresh reader slice to current storage (pointer may have moved)
        self.reader.buffer = list.items;
        self.reader.end = list.items.len;
        return;
    }
    return error.InvalidState;
}

pub fn deinit(self: *BitReader) void {
    if (self.file) |file| {
        file.close();
    }
    // Free the internal buffer only for file mode (we allocated it)
    if (self.file) |_| if (self.reader.buffer.len > 0) self.allocator.free(self.reader.buffer);
    // Deinit append list if present
    if (self.append_list) |*list| list.deinit(self.allocator);
}

// Bit-level operations
pub fn has(self: *BitReader, bit_count: usize) !bool {
    const available_bytes = if (self.reader.end >= self.reader.seek) self.reader.end - self.reader.seek else return false;
    const available_bits = (@as(usize, available_bytes) << 3) - self.bit_index;

    if (available_bits >= bit_count) return true;

    // Try to fill more data via std.Io.Reader; treat EndOfStream as "no more bytes"
    self.reader.fillMore() catch |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    };

    const new_available_bytes = self.reader.end - self.reader.seek;
    const new_available_bits = (new_available_bytes << 3) - self.bit_index;
    return new_available_bits >= bit_count;
}

pub fn readBits(self: *BitReader, bit_count: u5) !u32 {
    if (!try self.has(bit_count)) return error.EndOfStream;

    var value: u32 = 0;
    var remaining_bits = bit_count;

    while (remaining_bits > 0) {
        const current_byte: u8 = self.reader.buffer[self.reader.seek];

        const bit_offset: u4 = @intCast(self.bit_index & 7);
        const bits_in_byte: u4 = 8 - bit_offset;
        const bits_to_read_u4: u4 = @intCast(@min(bits_in_byte, remaining_bits));

        const mask_u16: u16 = if (bits_to_read_u4 == 8)
            0x00FF
        else
            (@as(u16, 0x00FF) >> (@as(u4, 8) - bits_to_read_u4));
        const mask: u8 = @intCast(mask_u16);
        const shift_amt_u3: u3 = @intCast(bits_in_byte - bits_to_read_u4);
        const part: u8 = (current_byte >> shift_amt_u3) & mask;

        value = (value << @as(u5, bits_to_read_u4)) | @as(u32, part);

        self.bit_index += @as(usize, bits_to_read_u4);
        remaining_bits -= @as(u5, bits_to_read_u4);

        // If we've consumed a full byte, advance
        if ((self.bit_index & 7) == 0) {
            self.reader.seek += 1;
            self.bit_index = 0;
        }
    }

    return value;
}

pub fn readBit(self: *BitReader) !bool {
    const v = try self.readBits(1);
    return v != 0;
}

pub fn alignToByte(self: *BitReader) void {
    if ((self.bit_index & 7) != 0) {
        self.reader.seek += 1;
        self.bit_index = 0;
    }
}

pub fn skip(self: *BitReader, bit_count: usize) void {
    if (self.has(bit_count) catch false) self.bit_index += bit_count;
}

pub fn tell(self: *BitReader) usize {
    return self.reader.seek;
}

pub fn seekTo(self: *BitReader, pos: usize) void {
    self.reader.seek = pos;
    self.bit_index = 0;
    if (self.append_list != null) {
        self.append_ended = false;
    }
}

pub fn signalEnd(self: *BitReader) void {
    if (self.append_list != null) {
        self.append_ended = true;
    }
}

pub fn hasEnded(self: *BitReader) bool {
    const has_more = self.has(1) catch false;
    if (self.append_list != null) {
        return self.append_ended and !has_more;
    }
    return !has_more;
}

pub fn skipBytes(self: *BitReader, value: u8) !usize {
    self.alignToByte();
    var skipped: usize = 0;
    while (try self.has(8) and self.reader.buffer[self.reader.seek] == value) {
        self.reader.seek += 1;
        skipped += 1;
    }
    return skipped;
}

pub fn peekBits(self: *BitReader, bit_count: u5) !u32 {
    if (!try self.has(bit_count)) return error.EndOfStream;
    const saved_seek = self.reader.seek;
    const saved_bit_index = self.bit_index;
    const v = try self.readBits(bit_count);
    self.reader.seek = saved_seek;
    self.bit_index = saved_bit_index;
    return v;
}

pub fn peekNonZero(self: *BitReader, bit_count: u5) !bool {
    if (!try self.has(bit_count)) return false;
    const saved_seek = self.reader.seek;
    const saved_bit_index = self.bit_index;
    const v = try self.readBits(bit_count);
    self.reader.seek = saved_seek;
    self.bit_index = saved_bit_index;
    return v != 0;
}

pub fn nextStartCode(self: *BitReader) ?u8 {
    self.alignToByte();
    while (self.has(5 << 3) catch false) {
        const idx = self.reader.seek;
        const buf = self.reader.buffer;
        if (buf[idx] == 0x00 and buf[idx + 1] == 0x00 and buf[idx + 2] == 0x01) {
            const code = buf[idx + 3];
            self.reader.seek = idx + 4;
            self.bit_index = 0;
            return code;
        }
        // advance by one byte
        self.reader.seek += 1;
    }
    return null;
}

pub fn findStartCode(self: *BitReader, code: u8) ?u8 {
    while (true) {
        const current = self.nextStartCode();
        if (current == null or current.? == code) return current;
    }
    return null;
}

pub fn hasStartCode(self: *BitReader, code: u8) bool {
    const saved_seek = self.reader.seek;
    const saved_bit_index = self.bit_index;
    const current = self.findStartCode(code);
    self.reader.seek = saved_seek;
    self.bit_index = saved_bit_index;
    return current != null and current.? == code;
}

pub fn totalSize(self: *BitReader) ?usize {
    return self.total_size;
}

// std.Io.Reader VTable implementation
const vtable = std.Io.Reader.VTable{
    .stream = stream,
    .discard = discard,
    .readVec = readVec,
    .rebase = rebase,
};

fn stream(r: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
    const self: *BitReader = @fieldParentPtr("reader", r);
    if (self.file) |file| {
        // File mode - read from file and write to writer
        var buffer: [4096]u8 = undefined;
        var total_written: usize = 0;
        while (total_written < @intFromEnum(limit)) {
            const bytes_read = file.read(buffer[0..]) catch |err| switch (err) {
                else => return error.ReadFailed,
            };
            if (bytes_read == 0) break;
            const to_write = @min(bytes_read, @intFromEnum(limit) - total_written);
            _ = w.write(buffer[0..to_write]) catch |err| switch (err) {
                else => return error.WriteFailed,
            };
            total_written += to_write;
        }
        return total_written;
    } else {
        // Memory mode - use r.buffer directly
        const available = r.end - r.seek;
        const to_stream = @min(available, @intFromEnum(limit));
        if (to_stream > 0) {
            _ = w.write(r.buffer[r.seek .. r.seek + to_stream]) catch |err| switch (err) {
                else => return error.WriteFailed,
            };
            r.seek += to_stream;
        }
        return to_stream;
    }
}

fn discard(r: *std.Io.Reader, limit: std.Io.Limit) std.Io.Reader.Error!usize {
    const self: *BitReader = @fieldParentPtr("reader", r);
    if (self.file) |file| {
        // File mode - seek forward
        _ = file.getPos() catch |err| switch (err) {
            else => return error.ReadFailed,
        };
        file.seekBy(@intCast(@intFromEnum(limit))) catch |err| switch (err) {
            else => return error.ReadFailed,
        };
        return @intFromEnum(limit);
    } else {
        // Memory mode - advance seek position in r
        const available = r.end - r.seek;
        const to_discard = @min(available, @intFromEnum(limit));
        r.seek += to_discard;
        return to_discard;
    }
}

fn readVec(r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
    const self: *BitReader = @fieldParentPtr("reader", r);
    if (self.file) |file| {
        // File mode - read from file
        var total_read: usize = 0;
        for (data) |slice| {
            const bytes_read = file.read(slice) catch |err| switch (err) {
                else => return error.ReadFailed,
            };
            total_read += bytes_read;
            if (bytes_read < slice.len) break;
        }
        return total_read;
    } else {
        // Memory mode - read from r.buffer
        var total_read: usize = 0;
        for (data) |slice| {
            const available = r.end - r.seek;
            if (available == 0) break;
            const to_read = @min(available, slice.len);
            @memcpy(slice[0..to_read], r.buffer[r.seek .. r.seek + to_read]);
            r.seek += to_read;
            total_read += to_read;
            if (to_read < slice.len) break;
        }
        return total_read;
    }
}

fn rebase(r: *std.Io.Reader, _: usize) std.Io.Reader.RebaseError!void {
    const self: *BitReader = @fieldParentPtr("reader", r);
    if (self.file) |_| {
        // File mode - no rebasing needed
        return;
    } else {
        // Memory mode - no rebasing needed for fixed data
        return;
    }
}

test "BitReader append: incremental bit reads across boundary" {
    const allocator = std.testing.allocator;
    var br = try BitReader.initAppend(allocator, 1);
    defer br.deinit();

    // Append first byte 0xAA = 1010_1010
    try br.append(&.{0xAA});
    try std.testing.expect(try br.has(4));
    const first4 = try br.readBits(4);
    try std.testing.expectEqual(@as(u32, 0xA), first4);

    // Not enough for 8 bits yet
    try std.testing.expect(!(try br.has(8)));

    // Append second byte 0xBC = 1011_1100
    try br.append(&.{0xBC});
    // Now we have enough bits for the next 8: remaining 4 of 0xAA + first 4 of 0xBC = 0xAB
    try std.testing.expect(try br.has(8));
    const cross8 = try br.readBits(8);
    try std.testing.expectEqual(@as(u32, 0xAB), cross8);

    // Remaining 4 bits of 0xBC -> 0xC
    const last4 = try br.readBits(4);
    try std.testing.expectEqual(@as(u32, 0xC), last4);

    // No more bits
    try std.testing.expect(!(try br.has(1)));
}

test "BitReader append: readVec after appends" {
    const allocator = std.testing.allocator;
    var br = try BitReader.initAppend(allocator, 2);
    defer br.deinit();

    try br.append(&.{0xDE});
    try br.append(&.{ 0xAD, 0xBE, 0xEF });

    var a: [2]u8 = undefined;
    var b: [3]u8 = undefined;
    var vec = [_][]u8{ a[0..], b[0..] };
    const n = try br.reader.readVec(vec[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(std.mem.eql(u8, a[0..], &.{ 0xDE, 0xAD }));
    const expect_tail = [_]u8{ 0xBE, 0xEF };
    try std.testing.expect(std.mem.eql(u8, b[0..2], expect_tail[0..]));
}

test "BitReader memory: readBits basic" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0xB3, 0x5C }; // 1011_0011, 0101_1100
    var br = BitReader.initFromMemory(allocator, data[0..]);

    // 3 bits: 101 = 5
    const a = try br.readBits(3);
    try std.testing.expectEqual(@as(u32, 5), a);

    // next 5 bits from first byte: 10011 = 19
    const b = try br.readBits(5);
    try std.testing.expectEqual(@as(u32, 19), b);

    // now exactly at byte boundary, next 8 bits should be second byte 0x5C
    const c = try br.readBits(8);
    try std.testing.expectEqual(@as(u32, 0x5C), c);
}

test "BitReader memory: has() near EOF" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0xFF, 0x00 };
    var br = BitReader.initFromMemory(allocator, data[0..]);

    try std.testing.expect(try br.has(16));
    try std.testing.expect(!(try br.has(17)));
}

test "BitReader memory: std.Io.Reader.readVec" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0xDE, 0xAD, 0xBE };
    var br = BitReader.initFromMemory(allocator, data[0..]);

    var out1: [2]u8 = undefined;
    var out2: [2]u8 = undefined;
    var vec = [_][]u8{ out1[0..], out2[0..] };
    const n = try br.reader.readVec(vec[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expect(std.mem.eql(u8, out1[0..], &.{ 0xDE, 0xAD }));
    try std.testing.expectEqual(@as(u8, 0xBE), out2[0]);
}

test "BitReader memory: peekBits and peekNonZero" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0b1010_1100, 0b1111_0000 };
    var br = BitReader.initFromMemory(allocator, data[0..]);

    // Peek first 4 bits = 0b1010 = 10, reader state unchanged
    const p = try br.peekBits(4);
    try std.testing.expectEqual(@as(u32, 10), p);

    // Now actually read 4 bits; should match
    const r = try br.readBits(4);
    try std.testing.expectEqual(@as(u32, 10), r);

    // Next 4 bits of first byte: 1100 = 12, and it's non-zero
    try std.testing.expect(try br.peekNonZero(4));
    const r2 = try br.readBits(4);
    try std.testing.expectEqual(@as(u32, 12), r2);

    // Next 4 bits from second byte: 1111 = 15, non-zero
    try std.testing.expect(try br.peekNonZero(4));
    const r3 = try br.readBits(4);
    try std.testing.expectEqual(@as(u32, 15), r3);

    // Remaining 4 bits: 0000 = 0, peekNonZero should be false
    try std.testing.expect(!(try br.peekNonZero(4)));
    const r4 = try br.readBits(4);
    try std.testing.expectEqual(@as(u32, 0), r4);
}

test "BitReader memory: nextStartCode and findStartCode" {
    const allocator = std.testing.allocator;
    // bytes: 00 00 01 B3 12 34 00 00 01 E0 FF
    const data = [_]u8{ 0x00, 0x00, 0x01, 0xB3, 0x12, 0x34, 0x00, 0x00, 0x01, 0xE0, 0xFF };
    var br = BitReader.initFromMemory(allocator, data[0..]);

    const code1 = br.nextStartCode();
    try std.testing.expect(code1 != null);
    try std.testing.expectEqual(@as(u8, 0xB3), code1.?);

    const code2 = br.findStartCode(0xE0);
    try std.testing.expect(code2 != null);
    try std.testing.expectEqual(@as(u8, 0xE0), code2.?);

    const none = br.nextStartCode();
    try std.testing.expect(none == null);
}

test "BitReader memory: hasStartCode mirrors findStartCode without consuming" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0x00, 0x00, 0x01, 0xB3, 0x7F, 0x00, 0x00, 0x01, 0xE0 };
    var br = BitReader.initFromMemory(allocator, data[0..]);

    // Should detect 0xB3 without consuming
    try std.testing.expect(br.hasStartCode(0xB3));
    // Now nextStartCode should still return 0xB3
    const code = br.nextStartCode();
    try std.testing.expect(code != null and code.? == 0xB3);
}

test "BitReader memory: skipBytes aligns and skips target byte" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0xFF, 0x00, 0x00, 0x00, 0x12, 0x00 };
    var br = BitReader.initFromMemory(allocator, data[0..]);

    // Consume 4 bits to force misalignment, then skipBytes should align
    _ = try br.readBits(4);
    const skipped = try br.skipBytes(0x00);
    try std.testing.expectEqual(@as(usize, 3), skipped);
    // Next byte should be 0x12
    const next = try br.readBits(8);
    try std.testing.expectEqual(@as(u32, 0x12), next);
}

test "BitReader memory: tell reflects byte position across bit reads" {
    const allocator = std.testing.allocator;
    const data = [_]u8{ 0xAA, 0xBB, 0xCC };
    var br = BitReader.initFromMemory(allocator, data[0..]);

    try std.testing.expectEqual(@as(usize, 0), br.tell());
    _ = try br.readBits(3); // not crossing byte
    try std.testing.expectEqual(@as(usize, 0), br.tell());
    _ = try br.readBits(5); // completes first byte
    try std.testing.expectEqual(@as(usize, 1), br.tell());
    _ = try br.readBits(8);
    try std.testing.expectEqual(@as(usize, 2), br.tell());
}

test "BitReader memory: hasEnded after consuming all bits" {
    const allocator = std.testing.allocator;
    const data = [_]u8{0x01};
    var br = BitReader.initFromMemory(allocator, data[0..]);

    try std.testing.expect(!br.hasEnded());
    _ = try br.readBits(8);
    try std.testing.expect(br.hasEnded());
}

test "BitReader append: signalEnd controls hasEnded" {
    const allocator = std.testing.allocator;
    var br = try BitReader.initAppend(allocator, 4);
    defer br.deinit();

    try br.append(&.{0xAA});
    try std.testing.expect(!br.hasEnded());
    br.signalEnd();
    _ = try br.readBits(8);
    try std.testing.expect(br.hasEnded());
}
