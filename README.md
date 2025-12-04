# zmpeg

MPEG-1 Video decoder, MP2 Audio decoder, MPEG-PS demuxer in Zig. Port of [pl_mpeg](https://github.com/phoboslab/pl_mpeg).

## Quick Start

```bash
zig build run -- trouble-pogo.mp4
```

## Library Usage

### High-Level API (Recommended)

```zig
const zmpeg = @import("zmpeg");

var mpeg = try zmpeg.createFromFile(allocator, "video.mpg");
defer mpeg.deinit();

var player = zmpeg.Player.init(mpeg);
player.setVideoCallback(onVideo, userdata);
player.setAudioCallback(onAudio, userdata);

// In your loop:
try player.decode(elapsed_seconds, audio_queued_seconds);
```

### Low-Level API

```zig
// Decode video manually
if (mpeg.video_decoder) |video| {
    while (video.decode()) |frame| {
        // frame.y, frame.cb, frame.cr
    }
}

// Decode audio manually
if (mpeg.audio_decoder) |audio| {
    while (try audio.decode()) |samples| {
        // samples.interleaved
    }
}
```

### Input Methods

```zig
// From file
const mpeg = try zmpeg.createFromFile(allocator, "video.mpg");

// From memory
const mpeg = try zmpeg.createFromMemory(allocator, data);

// Custom reader (streaming)
var reader = try zmpeg.BitReader.initAppend(allocator, 1024);
const mpeg = try zmpeg.createWithReader(allocator, &reader);
```

See `src/main.zig` for a complete SDL2 player example.
