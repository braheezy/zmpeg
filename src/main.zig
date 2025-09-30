const std = @import("std");
const builtin = @import("builtin");
const zmpeg = @import("zmpeg");

var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

const fnv_offset_basis: u64 = 1469598103934665603;
const fnv_prime: u64 = 1099511628211;

fn hashFrame(hash: u64, data: []const u8) u64 {
    var h = hash;
    for (data) |byte| {
        h ^= byte;
        h *%= fnv_prime;
    }
    return h;
}

fn clampToU8(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

fn frameToBgr(frame: *const zmpeg.Frame, dest: []u8, row_stride: usize) void {
    const width = @as(usize, frame.width);
    const height = @as(usize, frame.height);
    if (height == 0 or width == 0) return;
    if (dest.len < row_stride * height) return;

    const cols = width >> 1;
    const rows = height >> 1;
    const yw = @as(i32, @intCast(frame.y.width));
    const cw = @as(i32, @intCast(frame.cb.width));

    const y_data = frame.y.data;
    const cr_data = frame.cr.data;
    const cb_data = frame.cb.data;

    var row: usize = 0;
    while (row < rows) : (row += 1) {
        var c_index: usize = row * @as(usize, @intCast(cw));
        var y_index: usize = row * 2 * @as(usize, @intCast(yw));
        var d_index: usize = row * 2 * row_stride;

        var col: usize = 0;
        while (col < cols) : (col += 1) {
            const cr = @as(i32, cr_data[c_index]) - 128;
            const cb = @as(i32, cb_data[c_index]) - 128;
            const r = (cr * 104_597) >> 16;
            const g = (cb * 25_674 + cr * 53_278) >> 16;
            const b = (cb * 132_201) >> 16;

            const y_stride_usize = @as(usize, @intCast(yw));

            if (y_index < y_data.len) {
                const yy0 = ((@as(i32, y_data[y_index]) - 16) * 76_309) >> 16;
                if (d_index + 2 < dest.len) {
                    dest[d_index + 2] = clampToU8(yy0 + r);
                    dest[d_index + 1] = clampToU8(yy0 - g);
                    dest[d_index + 0] = clampToU8(yy0 + b);
                }
            }

            if (y_index + 1 < y_data.len) {
                const yy1 = ((@as(i32, y_data[y_index + 1]) - 16) * 76_309) >> 16;
                const dst1 = d_index + 3;
                if (dst1 + 2 < dest.len) {
                    dest[dst1 + 2] = clampToU8(yy1 + r);
                    dest[dst1 + 1] = clampToU8(yy1 - g);
                    dest[dst1 + 0] = clampToU8(yy1 + b);
                }
            }

            if (y_index + y_stride_usize < y_data.len) {
                const yy2 = ((@as(i32, y_data[y_index + y_stride_usize]) - 16) * 76_309) >> 16;
                const dst2 = d_index + row_stride;
                if (dst2 + 2 < dest.len) {
                    dest[dst2 + 2] = clampToU8(yy2 + r);
                    dest[dst2 + 1] = clampToU8(yy2 - g);
                    dest[dst2 + 0] = clampToU8(yy2 + b);
                }
            }

            if (y_index + y_stride_usize + 1 < y_data.len) {
                const yy3 = ((@as(i32, y_data[y_index + y_stride_usize + 1]) - 16) * 76_309) >> 16;
                const dst3 = d_index + row_stride + 3;
                if (dst3 + 2 < dest.len) {
                    dest[dst3 + 2] = clampToU8(yy3 + r);
                    dest[dst3 + 1] = clampToU8(yy3 - g);
                    dest[dst3 + 0] = clampToU8(yy3 + b);
                }
            }

            c_index += 1;
            y_index += 2;
            d_index += 6;
        }
    }
}

pub fn main() !void {
    const allocator, const is_debug = gpa: {
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var input_path: []const u8 = "trouble-pogo-5s.mpg";
    var debug_frame: ?usize = null;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--debug-frame=")) {
            const value = arg["--debug-frame=".len..];
            debug_frame = std.fmt.parseInt(usize, value, 10) catch {
                std.log.warn("Ignoring invalid debug frame index: {s}", .{value});
                continue;
            };
        } else if (arg.len > 0 and arg[0] != '-') {
            input_path = arg;
        }
    }

    var mpeg = try zmpeg.createFromFile(allocator, input_path);
    defer mpeg.deinit();

    mpeg.setAudio(false);

    const width = mpeg.getWidth();
    const height = mpeg.getHeight();

    std.debug.print("width: {d}, height: {d}\n", .{ width, height });
    if (width <= 0 or height <= 0) return;

    const row_stride = @as(usize, @intCast(width)) * 3;
    const frame_size = @as(usize, @intCast(height)) * row_stride;
    const frame_buffer = try allocator.alloc(u8, frame_size);
    defer allocator.free(frame_buffer);

    var hash: u64 = fnv_offset_basis;
    var frames_hashed: usize = 0;

    if (mpeg.video_decoder) |video_decoder| {
        const video_reader = mpeg.video_reader;
        const packet_type = mpeg.video_packet_type;

        var demux_done = false;
        while (true) {
            if (video_decoder.decode()) |frame| {
                const print_details = frames_hashed == 0 or (debug_frame != null and frames_hashed == debug_frame.?);

                if (print_details) {
                    var y_sum: u64 = 0;
                    for (frame.y.data) |val| y_sum += val;
                    std.debug.print("Y sum={d} len={} width={} height={}\n", .{ y_sum, frame.y.data.len, frame.y.width, frame.y.height });
                    const sample_y = @min(frame.y.data.len, @as(usize, 16));
                    std.debug.print("Y[0..{d}]:", .{sample_y});
                    for (frame.y.data[0..sample_y]) |byte| std.debug.print(" {x:0>2}", .{byte});
                    std.debug.print("\n", .{});
                    const sample_cr = @min(frame.cr.data.len, @as(usize, 8));
                    std.debug.print("Cr[0..{d}]:", .{sample_cr});
                    for (frame.cr.data[0..sample_cr]) |byte| std.debug.print(" {x:0>2}", .{byte});
                    std.debug.print("\n", .{});
                    const sample_cb = @min(frame.cb.data.len, @as(usize, 8));
                    std.debug.print("Cb[0..{d}]:", .{sample_cb});
                    for (frame.cb.data[0..sample_cb]) |byte| std.debug.print(" {x:0>2}", .{byte});
                    std.debug.print("\n", .{});
                }

                const frame_view: *const zmpeg.Frame = @ptrCast(frame);
                frameToBgr(frame_view, frame_buffer, row_stride);

                if (print_details) {
                    var byte_sum: u64 = 0;
                    for (frame_buffer[0..frame_size]) |b| byte_sum += b;
                    const sample_len = @min(frame_size, @as(usize, 16));
                    std.debug.print("byte_sum={d}\n", .{byte_sum});
                    std.debug.print("pixels[0..{d}]:", .{sample_len});
                    for (frame_buffer[0..sample_len]) |byte| std.debug.print(" {x:0>2}", .{byte});
                    std.debug.print("\n", .{});
                }

                const frame_hash = hashFrame(fnv_offset_basis, frame_buffer[0..frame_size]);
                std.debug.print(
                    "Z frame {d} type={d} time={d:.6} hash={x:0>16}\n",
                    .{ frames_hashed, video_decoder.picture_type, frame.time, frame_hash },
                );

                hash = hashFrame(hash, frame_buffer[0..frame_size]);
                frames_hashed += 1;

                if (debug_frame) |df| {
                    if (frames_hashed > df) break;
                }
                continue;
            }

            if (demux_done) break;
            const packet = mpeg.demux.decode() orelse {
                demux_done = true;
                if (video_reader) |reader| {
                    reader.signalEnd();
                }
                continue;
            };

            if (packet_type) |ptype| {
                if (packet.type == ptype) {
                    if (video_reader) |reader| {
                        reader.append(packet.data) catch break;
                    } else {
                        video_decoder.reader.append(packet.data) catch break;
                    }
                }
            }
        }
    }

    std.debug.print("frames hashed: {d}\n", .{frames_hashed});
    std.debug.print("{x:0>16}\n", .{hash});
}
