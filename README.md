## zmpeg

MPEG1 Video decoder, MP2 Audio decoder, MPEG-PS demuxer. Based on [`pl_mpeg`](https://github.com/phoboslab/pl_mpeg).

Try it out:

```bash
git clone https://github.com/braheezy/zmpeg
cd zmpeg
zig build -Doptimize=ReleaseFast
ffmpeg -i trouble-pogo.mp4 -q:v 2 -q:a 2 -f mpeg trouble-pogo.mpg
./zig-out/bin/player trouble-pogo.mpg
```
