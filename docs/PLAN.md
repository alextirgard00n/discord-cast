# Plan

## Goals

- Cast a Discord Go Live stream to a Google Cast TV from Windows and macOS.
- Optional 2x frame generation (Discord streams are usually 30 fps).
- Optional upscale to 4K with a scaler that beats the TV's own (LS1 first).
- Low CPU use: capture → process → encode stays on the GPU with no CPU copies.

## Non-goals

- Pulling the stream from Discord's servers or automating a Discord account
  (against Discord's ToS). We only capture what's already on screen.

## Architecture

Shared C++20 core (CMake) with per-platform backends.

| Layer | Windows | macOS |
|-------|---------|-------|
| Window capture | Windows.Graphics.Capture | ScreenCaptureKit |
| Audio | WASAPI process loopback (Discord.exe) | ScreenCaptureKit app audio |
| GPU processing | D3D11 compute | Metal compute |
| Frame gen | NVIDIA Optical Flow FRUC (RTX), RIFE fallback | RIFE on Metal |
| Upscale | LS1 (HLSL), FSR1 EASU+RCAS | LS1 (ported to MSL), MetalFX spatial, FSR1 |
| Encode | NVENC HEVC (AMF/QSV fallback) | VideoToolbox HEVC |

Shared core: pipeline/frame pacing, fMP4 HLS muxer + HTTP server, Cast
discovery (mDNS) and CASTV2 control, and a small control window (pick
window, pick TV, toggles for frame gen and upscale, stats).

Pipeline order: capture → frame gen (native res) → upscale → encode.
Interpolating before upscaling costs about a quarter of the work.

Audio note: Discord plays voice chat and stream audio from the same process,
so the TV gets both unless voice is deafened or routed to another device.
We'll look into separating them later.

## Phases

0. **Receiver test** (`spike/`): find which codec, resolution, fps and segment
   length the TV's Cast receiver accepts, and how much delay it adds.
1. **Native capture → cast**, no processing, on both platforms.
2. **Upscaler**: LS1, then FSR1 / MetalFX. Compare against the TV's own scaling.
3. **Frame gen**: compare against the TV's TruMotion.
4. **Polish**: auto-detect the popped-out Discord stream window, skip frame gen
   when the source is already 60 fps, presets, tray icon.

Later option: a custom Cast receiver (WebRTC) for sub-second delay. It needs
a Google Cast developer registration and an HTTPS-hosted receiver page.

## Licensing note

LS1 comes from Lossless Scaling (a paid app). That's fine in a build that's
only run privately; any build that's shared or sold should default to
FSR1/MetalFX instead.
