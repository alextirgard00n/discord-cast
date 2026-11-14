#!/usr/bin/env python3
"""
Phase 0 spike: can the TV's built-in Google Cast receiver play a live,
low-latency stream that we generate and serve from this machine?

Pipeline:  ffmpeg (test pattern or screen) -> HLS (fMP4 or TS) in a temp dir
           -> tiny HTTP server on the LAN -> Cast Default Media Receiver on the TV

This is throwaway test code. The real app will be native C++; this exists only
to answer "what codec / resolution / segment length does the TV accept, and how
much delay do we get" before we build on top of it.

Examples:
  python cast_test.py --list
  python cast_test.py --device "LG C5" --codec h264 --res 1080p
  python cast_test.py --device "LG C5" --codec hevc --res 4k --fps 60
  python cast_test.py --device "LG C5" --source screen --codec hevc --res 4k
"""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import platform
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

RES = {"720p": (1280, 720), "1080p": (1920, 1080), "1440p": (2560, 1440), "4k": (3840, 2160)}
DEFAULT_KBPS = {"720p": 6000, "1080p": 12000, "1440p": 20000, "4k": 35000}
IS_WIN = platform.system() == "Windows"
IS_MAC = platform.system() == "Darwin"


# ---------------------------------------------------------------- networking

def lan_ip() -> str:
    """IP of the interface that routes to the LAN (no packets are sent)."""
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class HLSHandler(http.server.SimpleHTTPRequestHandler):
    """Static file server with the headers a Cast receiver needs (CORS, no caching of the playlist)."""

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".m3u8": "application/vnd.apple.mpegurl",
        ".m4s": "video/iso.segment",
        ".mp4": "video/mp4",
        ".ts": "video/mp2t",
    }

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
        if self.path.split("?")[0].endswith(".m3u8"):
            self.send_header("Cache-Control", "no-cache, no-store")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *args):
        if self.server.verbose:  # type: ignore[attr-defined]
            sys.stderr.write("[http] " + (fmt % args) + "\n")


def start_http(root: Path, port: int, verbose: bool) -> http.server.ThreadingHTTPServer:
    handler = functools.partial(HLSHandler, directory=str(root))
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    srv.daemon_threads = True
    srv.verbose = verbose  # type: ignore[attr-defined]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# -------------------------------------------------------------------- ffmpeg

def pick_encoder(codec: str, force: str | None) -> str:
    if force:
        return force
    if IS_MAC:
        return f"{codec}_videotoolbox"
    if IS_WIN:
        return f"{codec}_nvenc"  # RTX; use --encoder for AMF/QSV/software
    return "libx264" if codec == "h264" else "libx265"


def encoder_args(enc: str, kbps: int, gop: int) -> list[str]:
    rate = ["-b:v", f"{kbps}k", "-maxrate", f"{int(kbps * 1.2)}k", "-bufsize", f"{kbps}k"]
    common = ["-g", str(gop), "-keyint_min", str(gop), "-bf", "0"]
    if "nvenc" in enc:
        return ["-c:v", enc, "-preset", "p4", "-tune", "ll", "-rc", "cbr", "-forced-idr", "1", "-pix_fmt", "yuv420p", *rate, *common]
    if "videotoolbox" in enc:
        return ["-c:v", enc, "-realtime", "1", "-prio_speed", "1", "-pix_fmt", "nv12", *rate, *common]
    if "amf" in enc:
        return ["-c:v", enc, "-usage", "lowlatency", "-pix_fmt", "yuv420p", *rate, *common]
    if "qsv" in enc:
        return ["-c:v", enc, "-preset", "veryfast", "-low_power", "1", "-pix_fmt", "nv12", *rate, *common]
    if enc == "libx265":
        return ["-c:v", enc, "-preset", "ultrafast", "-tune", "zerolatency", "-pix_fmt", "yuv420p", *rate, *common,
                "-x265-params", f"keyint={gop}:min-keyint={gop}:scenecut=0"]
    return ["-c:v", enc, "-preset", "veryfast", "-tune", "zerolatency", "-pix_fmt", "yuv420p", *rate, *common,
            "-sc_threshold", "0"]


@functools.lru_cache(maxsize=None)
def has_filter(ffmpeg: str, name: str) -> bool:
    """Some ffmpeg builds (e.g. current Homebrew) ship without drawtext."""
    try:
        out = subprocess.run([ffmpeg, "-hide_banner", "-filters"], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.SubprocessError):
        return False
    return any(line.split()[1:2] == [name] for line in out.splitlines() if line.strip())


def source_args(a, w: int, h: int) -> tuple[list[str], list[str]]:
    """Returns (input args, video filter chain)."""
    if a.source == "pattern":
        # Moving test pattern + a white flash and a 1 kHz beep at the start of every
        # second, so A/V sync and judder are easy to see. Elapsed time is drawn big.
        vin = ["-re", "-f", "lavfi", "-i", f"testsrc2=size={w}x{h}:rate={a.fps}"]
        ain = ["-re", "-f", "lavfi", "-i",
               "aevalsrc=0.4*sin(2*PI*1000*t)*lt(mod(t\\,1)\\,0.1):s=48000:c=stereo"]
        fs = max(24, h // 10)
        font = ""
        for f in ("/System/Library/Fonts/Supplemental/Arial.ttf", "/Library/Fonts/Arial.ttf",
                  "C:/Windows/Fonts/arial.ttf"):
            if os.path.exists(f):
                font = "fontfile='" + f.replace(":", "\\:") + "':"
                break
        vf = [f"drawbox=x=0:y=0:w=iw:h=ih:color=white:t=fill:enable='lt(mod(t,1),0.1)'"]
        if has_filter(a.ffmpeg, "drawtext"):
            vf.append(f"drawtext={font}text='%{{pts\\:hms}}':fontsize={fs}:fontcolor=white:box=1:boxcolor=black@0.7:"
                      f"boxborderw={fs // 4}:x=(w-tw)/2:y=h-th-{fs}")
        else:
            print("! this ffmpeg has no drawtext filter; the on-screen timer is skipped (flash + beep still work)")
        return vin + ain, vf

    # Screen capture. The real app captures just the Discord window with WGC /
    # ScreenCaptureKit; for this test the whole display is fine.
    if IS_WIN:
        vin = ["-f", "gdigrab", "-framerate", str(a.fps), "-draw_mouse", "1", "-i", "desktop"]
    elif IS_MAC:
        vin = ["-f", "avfoundation", "-capture_cursor", "1", "-framerate", str(a.fps),
               "-pixel_format", "nv12", "-i", f"{a.mac_screen}:none"]
    else:
        vin = ["-f", "x11grab", "-framerate", str(a.fps), "-i", os.environ.get("DISPLAY", ":0")]
    ain = ["-f", "lavfi", "-i", "anullsrc=r=48000:cl=stereo"]
    return vin + ain, [f"scale={w}:{h}:flags=lanczos"]


def build_ffmpeg(a, outdir: Path) -> list[str]:
    w, h = RES[a.res]
    kbps = a.kbps or DEFAULT_KBPS[a.res]
    gop = max(1, round(a.fps * a.segment))
    enc = pick_encoder(a.codec, a.encoder)
    inputs, vf = source_args(a, w, h)
    seg_ext = "m4s" if a.container == "fmp4" else "ts"

    cmd = [a.ffmpeg, "-hide_banner", "-loglevel", "warning", "-stats", *inputs,
           "-map", "0:v", "-map", "1:a", "-vf", ",".join(vf),
           *encoder_args(enc, kbps, gop),
           "-force_key_frames", f"expr:gte(t,n_forced*{a.segment})"]
    if a.codec == "hevc":
        cmd += ["-tag:v", "hvc1"]  # required for HEVC in fMP4 on most players
    cmd += ["-c:a", "aac", "-b:a", "160k", "-ar", "48000",
            "-f", "hls", "-hls_time", str(a.segment), "-hls_list_size", "6",
            "-hls_flags", "delete_segments+independent_segments+omit_endlist+program_date_time",
            "-hls_segment_type", "fmp4" if a.container == "fmp4" else "mpegts"]
    if a.container == "fmp4":
        cmd += ["-hls_fmp4_init_filename", "init.mp4"]
    cmd += ["-hls_segment_filename", str(outdir / f"seg_%05d.{seg_ext}"), str(outdir / "index.m3u8")]
    return cmd


def wait_for_segments(outdir: Path, n: int, proc: subprocess.Popen, timeout: float = 20.0) -> None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        if proc.poll() is not None:
            raise SystemExit(f"ffmpeg exited early (code {proc.returncode}); see its output above.")
        pl = outdir / "index.m3u8"
        if pl.exists() and pl.read_text(errors="ignore").count("#EXTINF") >= n:
            return
        time.sleep(0.1)
    raise SystemExit("Timed out waiting for HLS segments. Is the encoder available? Try --encoder libx264.")


# ---------------------------------------------------------------------- cast

def import_pychromecast():
    try:
        import pychromecast  # noqa: F401
        return pychromecast
    except ImportError:
        raise SystemExit("pychromecast is missing. Run:  pip install -r requirements.txt")


def list_devices(names_only: bool = False) -> None:
    pc = import_pychromecast()
    if not names_only:
        print("Looking for Cast devices (5 s)...")
    casts, browser = pc.get_chromecasts(timeout=5)
    pc.discovery.stop_discovery(browser)
    if names_only:
        for c in casts:
            print(c.cast_info.friendly_name)
        return
    if not casts:
        print("None found. Same network/VLAN? Firewall allowing mDNS (UDP 5353)?")
    for c in casts:
        ci = c.cast_info
        print(f"  {ci.friendly_name!r:30} model={ci.model_name!r} host={ci.host}")


def cast_stream(a, url: str):
    pc = import_pychromecast()
    casts, browser = pc.get_listed_chromecasts(friendly_names=[a.device], discovery_timeout=8)
    if not casts:
        pc.discovery.stop_discovery(browser)
        raise SystemExit(f"Cast device {a.device!r} not found. Run with --list to see names.")
    cast = casts[0]
    cast.wait()
    mc = cast.media_controller

    seg_fmt = "fmp4" if a.container == "fmp4" else "ts_aac"
    extra = {"hlsSegmentFormat": seg_fmt,
             "hlsVideoSegmentFormat": "fmp4" if a.container == "fmp4" else "mpeg2_ts"}
    title = f"discord-cast test {a.codec.upper()} {a.res}{a.fps}"
    try:
        mc.play_media(url, "application/x-mpegurl", title=title, stream_type="LIVE", media_info=extra)
    except TypeError:
        print("! this pychromecast version has no media_info; casting without HLS segment hints")
        mc.play_media(url, "application/x-mpegurl", title=title, stream_type="LIVE")
    mc.block_until_active(timeout=15)
    return cast, browser


# ---------------------------------------------------------------------- main

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--list", action="store_true", help="list Cast devices and exit")
    p.add_argument("--list-names", action="store_true", help="print Cast device names only, one per line")
    p.add_argument("--device", help="Cast device friendly name (see --list)")
    p.add_argument("--source", choices=["pattern", "screen"], default="pattern")
    p.add_argument("--codec", choices=["h264", "hevc"], default="h264")
    p.add_argument("--res", choices=list(RES), default="1080p")
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--kbps", type=int, help="video bitrate (default depends on --res)")
    p.add_argument("--segment", type=float, default=1.0, help="HLS segment length in seconds")
    p.add_argument("--container", choices=["fmp4", "ts"], default="fmp4",
                   help="HLS segment container (HEVC generally needs fmp4)")
    p.add_argument("--encoder", help="override ffmpeg encoder, e.g. h264_amf, hevc_qsv, libx264")
    p.add_argument("--mac-screen", default="1",
                   help="avfoundation screen index on macOS (see: ffmpeg -f avfoundation -list_devices true -i \"\")")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "ffmpeg")
    p.add_argument("--no-cast", action="store_true",
                   help="only serve the stream; open the printed URL in VLC/Safari to check it")
    p.add_argument("--verbose", action="store_true", help="log every HTTP request")
    a = p.parse_args()

    if a.list or a.list_names:
        list_devices(names_only=a.list_names)
        return
    if not a.device and not a.no_cast:
        p.error("--device is required (or use --list / --no-cast)")
    if a.codec == "hevc" and a.container == "ts":
        print("! HEVC in TS is poorly supported by Cast receivers; expect failure (that's a valid test result).")

    outdir = Path(tempfile.mkdtemp(prefix="discord-cast-"))
    srv = start_http(outdir, a.port, a.verbose)
    url = f"http://{lan_ip()}:{a.port}/index.m3u8"

    cmd = build_ffmpeg(a, outdir)
    print("ffmpeg:", subprocess.list2cmdline(cmd))
    ff = subprocess.Popen(cmd, stdin=subprocess.DEVNULL)

    cast = browser = None

    def shutdown(*_):
        print("\nStopping...")
        if cast is not None:
            try:
                cast.media_controller.stop()
                cast.quit_app()
            except Exception:
                pass
        if browser is not None:
            try:
                import pychromecast
                pychromecast.discovery.stop_discovery(browser)
            except Exception:
                pass
        if ff.poll() is None:
            ff.terminate()
            try:
                ff.wait(5)
            except subprocess.TimeoutExpired:
                ff.kill()
        srv.shutdown()
        shutil.rmtree(outdir, ignore_errors=True)
        sys.exit(0)

    signal.signal(signal.SIGINT, shutdown)
    if hasattr(signal, "SIGTERM"):
        signal.signal(signal.SIGTERM, shutdown)

    wait_for_segments(outdir, 3, ff)
    print(f"\nServing: {url}")

    if a.no_cast:
        print("Open that URL in VLC or Safari. Ctrl+C to stop.")
    else:
        print(f"Casting to {a.device!r}...")
        cast, browser = cast_stream(a, url)
        print("Cast started. Ctrl+C to stop.\n")
        print("Delay check: --source pattern shows elapsed time on the TV; compare against the 'time=' in")
        print("ffmpeg's stats line. Best: --source screen with a stopwatch on your monitor, photograph both.\n")

    last = None
    while True:
        time.sleep(1)
        if ff.poll() is not None:
            print(f"ffmpeg exited (code {ff.returncode}).")
            shutdown()
        if cast is not None:
            st = cast.media_controller.status
            state = (st.player_state, getattr(st, "idle_reason", None))
            if state != last:
                print(f"[tv] player_state={state[0]} idle_reason={state[1]}")
                last = state


if __name__ == "__main__":
    main()
