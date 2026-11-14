# discord-cast

Watch a Discord Go Live stream on a TV over Google Cast, with optional
upscaling to 4K and 2x frame generation (30 → 60 fps).

Discord has no casting and no stream URL (Go Live is WebRTC straight into the
client), so discord-cast captures the popped-out stream window on your computer,
processes it on the GPU and serves it to the TV as a live stream.

```
Discord stream window
  → capture (WGC on Windows / ScreenCaptureKit on macOS) + Discord audio
  → frame gen 2x at native res (optional)
  → upscale to 4K (LS1 / FSR1 / MetalFX, optional)
  → hardware encode (NVENC / VideoToolbox, HEVC)
  → low-latency HLS on the LAN
  → Google Cast receiver on the TV
```

Targets: Windows (RTX) and macOS (Apple silicon). Tested receiver: LG C5 (Google Cast built in).

## Status

**Phase 0: receiver test.** Before building the native app, `spike/cast_test.py`
checks what the TV's Cast receiver accepts (H.264 vs HEVC, 1080p vs 4K, 30 vs 60 fps)
and how much delay it adds. See [docs/PLAN.md](docs/PLAN.md) for the full roadmap.

## Running the Phase 0 test

**macOS, one click:** double-click `Run Cast Test (Mac).command` in Finder. It
installs ffmpeg, Python and pychromecast through Homebrew if they're missing, asks
which TV to use (and remembers it), then shows a menu with every test in the table
below. Allow **Local Network** access when macOS asks, and **Screen Recording** for
the screen test. Requires [Homebrew](https://brew.sh).

**Manual:** Python 3.10+, ffmpeg on PATH (with NVENC on Windows, VideoToolbox on macOS).

```sh
cd spike
pip install -r requirements.txt

python cast_test.py --list                      # find the TV's Cast name
python cast_test.py --device "<TV name>"        # H.264 1080p60 test pattern
```

Windows will ask to allow Python through the firewall the first time. Allow it on
private networks, since the TV has to download the stream from your PC.

The test pattern shows elapsed time, flashes white and beeps once per second (to
check judder and A/V sync). Ctrl+C stops it and closes the stream on the TV.

### Test matrix

Run each, note whether it plays, whether it's smooth, and the delay:

| # | Command | Plays? | Smooth? | Delay |
|---|---------|--------|---------|-------|
| 1 | `--codec h264 --res 1080p --fps 30` | | | |
| 2 | `--codec h264 --res 1080p --fps 60` | | | |
| 3 | `--codec hevc --res 1080p --fps 60` | | | |
| 4 | `--codec hevc --res 4k --fps 60` | | | |
| 5 | `--codec h264 --res 4k --fps 60` | | | |
| 6 | #4 with `--segment 0.5` | | | |
| 7 | #4 with `--source screen` | | | |

**Measuring delay:** use `--source screen`, open a stopwatch with milliseconds on
your monitor, and take one photo with both the monitor and TV in frame. The
difference between the two readings is the delay.

Useful flags: `--kbps` (bitrate), `--container ts` (TS segments instead of fMP4),
`--encoder` (e.g. `h264_amf`, `hevc_qsv`, `libx264`), `--mac-screen` (macOS display
index), `--no-cast` (just serve the stream; open the URL in VLC/Safari to check it).
