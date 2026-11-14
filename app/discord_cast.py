#!/usr/bin/env python3
"""
discord-cast (Phase 1, macOS): cast one window (the popped-out Discord stream)
plus Discord's audio to a Google Cast TV.

  dc-capture (ScreenCaptureKit)  --NV12 + f32le over two FIFOs-->  ffmpeg
  ffmpeg (VideoToolbox HEVC)     --1 s fMP4 HLS in a temp dir-->   HTTP server on the LAN
  Cast Default Media Receiver on the TV plays the HLS URL.

Settings come from the Phase 0 tests on the LG C5: HEVC, fMP4, 1 s segments, 60 fps
(0.5 s segments stuttered and rebuffered).

  python discord_cast.py --windows                     # list capturable Discord windows
  python discord_cast.py --tvs                         # list Cast devices
  python discord_cast.py --window 1234 --device "TV"   # go
"""

from __future__ import annotations

import argparse
import functools
import http.server
import os
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_CAPTURE = HERE.parent / "mac" / "dc-capture" / ".build" / "release" / "dc-capture"


# ---------------------------------------------------------------- networking

def lan_ip() -> str:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


class HLSHandler(http.server.SimpleHTTPRequestHandler):
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".m3u8": "application/vnd.apple.mpegurl",
        ".m4s": "video/iso.segment",
        ".mp4": "video/mp4",
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

    def do_GET(self):
        # Serve the playlist with an EXT-X-START tag so the TV starts a few seconds
        # behind the newest segment. Without it the LG's Cast player starts at the
        # live edge, plays ~2 s, runs dry and rebuffers every few seconds.
        if self.path.split("?")[0].endswith("index.m3u8"):
            try:
                text = Path(self.directory, "index.m3u8").read_text()
            except OSError:
                self.send_error(404)
                return
            tag = f"#EXT-X-START:TIME-OFFSET=-{self.server.start_offset:.1f},PRECISE=YES\n"  # type: ignore[attr-defined]
            text = text.replace("#EXTM3U\n", "#EXTM3U\n" + tag, 1)
            body = text.encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def log_message(self, fmt, *args):
        if self.server.verbose:  # type: ignore[attr-defined]
            sys.stderr.write("[http] " + (fmt % args) + "\n")


def start_http(root: Path, port: int, verbose: bool, start_offset: float) -> http.server.ThreadingHTTPServer:
    handler = functools.partial(HLSHandler, directory=str(root))
    srv = http.server.ThreadingHTTPServer(("0.0.0.0", port), handler)
    srv.daemon_threads = True
    srv.verbose = verbose  # type: ignore[attr-defined]
    srv.start_offset = start_offset  # type: ignore[attr-defined]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv


# -------------------------------------------------------------------- ffmpeg

def build_ffmpeg(a, tmp: Path, vfifo: Path, afifo: Path) -> list[str]:
    gop = max(1, round(a.fps * a.segment))
    kbps = a.kbps
    return [
        a.ffmpeg, "-hide_banner", "-loglevel", "warning", "-stats",
        # Raw input from dc-capture, which paces it (no -re). Audio must be the first
        # input: see the pipe-order note in dc-capture's writer loop.
        "-thread_queue_size", "512", "-probesize", "32", "-analyzeduration", "0",
        "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", str(afifo),
        "-thread_queue_size", "512", "-probesize", "32", "-analyzeduration", "0",
        "-f", "rawvideo", "-pix_fmt", "nv12", "-video_size", f"{a.width}x{a.height}",
        "-framerate", str(a.fps), "-i", str(vfifo),
        "-map", "1:v", "-map", "0:a",
        "-c:v", a.encoder,
        *(["-realtime", "1", "-prio_speed", "1"] if "videotoolbox" in a.encoder else
          ["-preset", "ultrafast", "-tune", "zerolatency"] if a.encoder.startswith("libx") else []),
        "-b:v", f"{kbps}k", "-maxrate", f"{int(kbps * 1.2)}k", "-bufsize", f"{kbps}k",
        "-g", str(gop), "-keyint_min", str(gop), "-bf", "0",
        "-force_key_frames", f"expr:gte(t,n_forced*{a.segment})",
        "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
        "-tag:v", "hvc1",
        "-c:a", "aac", "-b:a", "192k", "-ar", "48000",
        "-f", "hls", "-hls_time", str(a.segment), "-hls_list_size", "10",
        "-hls_flags", "delete_segments+independent_segments+omit_endlist+program_date_time",
        "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
        "-hls_segment_filename", str(tmp / "seg_%05d.m4s"), str(tmp / "index.m3u8"),
    ]


class StartError(Exception):
    pass


def wait_for_segments(tmp: Path, n: int, procs: dict[str, subprocess.Popen], timeout: float = 30.0) -> None:
    t0 = time.time()
    while time.time() - t0 < timeout:
        for name, p in procs.items():
            if p.poll() is not None:
                raise StartError(f"{name} exited early (code {p.returncode}); see its output above.")
        pl = tmp / "index.m3u8"
        if pl.exists() and pl.read_text(errors="ignore").count("#EXTINF") >= n:
            return
        time.sleep(0.1)
    raise StartError("Timed out waiting for the stream to start.")


# ---------------------------------------------------------------------- cast

def import_pychromecast():
    try:
        import pychromecast
        return pychromecast
    except ImportError:
        raise SystemExit("pychromecast is missing. Run:  pip install -r requirements.txt")


def list_tvs() -> None:
    pc = import_pychromecast()
    casts, browser = pc.get_chromecasts(timeout=5)
    pc.discovery.stop_discovery(browser)
    for c in casts:
        print(c.cast_info.friendly_name)


def start_cast(device: str, url: str):
    pc = import_pychromecast()
    casts, browser = pc.get_listed_chromecasts(friendly_names=[device], discovery_timeout=8)
    if not casts:
        pc.discovery.stop_discovery(browser)
        raise SystemExit(f"Cast device {device!r} not found.")
    cast = casts[0]
    cast.wait()
    mc = cast.media_controller
    hints = {"hlsSegmentFormat": "fmp4", "hlsVideoSegmentFormat": "fmp4"}
    try:
        mc.play_media(url, "application/x-mpegurl", title="Discord", stream_type="LIVE", media_info=hints)
    except TypeError:
        mc.play_media(url, "application/x-mpegurl", title="Discord", stream_type="LIVE")
    mc.block_until_active(timeout=15)
    return cast, browser


# ---------------------------------------------------------------------- main

def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--windows", action="store_true", help="list Discord windows (id<TAB>description) and exit")
    p.add_argument("--all-windows", action="store_true", help="with --windows: include every app's windows")
    p.add_argument("--tvs", action="store_true", help="list Cast device names and exit")
    p.add_argument("--window", type=int, help="window id from --windows")
    p.add_argument("--device", help="Cast device name from --tvs")
    p.add_argument("--width", type=int, default=1920)
    p.add_argument("--height", type=int, default=1080)
    p.add_argument("--fps", type=int, default=60)
    p.add_argument("--kbps", type=int, default=16000, help="video bitrate")
    p.add_argument("--segment", type=float, default=1.0, help="HLS segment seconds (0.5 rebuffers on the LG C5)")
    p.add_argument("--buffer", type=float, default=4.0,
                   help="seconds behind the newest segment the TV starts playing (more = smoother, more delay)")
    p.add_argument("--encoder", default="hevc_videotoolbox")
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--ffmpeg", default=shutil.which("ffmpeg") or "ffmpeg")
    p.add_argument("--capture-bin", default=str(DEFAULT_CAPTURE))
    p.add_argument("--no-cast", action="store_true", help="serve only; open the URL in Safari/VLC")
    p.add_argument("--verbose", action="store_true")
    a = p.parse_args()

    if a.windows:
        cmd = [a.capture_bin, "list"] + (["--all"] if a.all_windows else [])
        sys.exit(subprocess.call(cmd))
    if a.tvs:
        list_tvs()
        return
    if a.window is None or (not a.device and not a.no_cast):
        p.error("--window and --device are required (see --windows / --tvs)")
    if not Path(a.capture_bin).exists():
        raise SystemExit(f"dc-capture not built: {a.capture_bin}\nRun: swift build -c release --package-path mac/dc-capture")

    tmp = Path(tempfile.mkdtemp(prefix="discord-cast-"))
    vfifo, afifo = tmp / "video.fifo", tmp / "audio.fifo"
    os.mkfifo(vfifo)
    os.mkfifo(afifo)
    srv = start_http(tmp, a.port, a.verbose, a.buffer)
    url = f"http://{lan_ip()}:{a.port}/index.m3u8"

    # ffmpeg first; it and dc-capture both open the audio FIFO, then the video FIFO.
    ff_cmd = build_ffmpeg(a, tmp, vfifo, afifo)
    if a.verbose:
        print("ffmpeg:", subprocess.list2cmdline(ff_cmd))
    ff = subprocess.Popen(ff_cmd, stdin=subprocess.DEVNULL)
    cap = subprocess.Popen([a.capture_bin, "capture", "--window", str(a.window),
                            "--video", str(vfifo), "--audio", str(afifo),
                            "--width", str(a.width), "--height", str(a.height), "--fps", str(a.fps)],
                           stdin=subprocess.DEVNULL)

    state = {"cast": None, "browser": None, "done": False}

    def shutdown(*_, code: int = 0):
        if state["done"]:
            return
        state["done"] = True
        print("\nStopping...", flush=True)
        cast = state["cast"]
        if cast is not None:
            try:
                cast.media_controller.stop()
                cast.quit_app()
            except Exception:
                pass
        if state["browser"] is not None:
            try:
                import pychromecast
                pychromecast.discovery.stop_discovery(state["browser"])
            except Exception:
                pass
        for proc in (cap, ff):
            if proc.poll() is None:
                # On a failed start ffmpeg is still waiting on its input pipes; kill it
                # outright so it doesn't print a confusing "Interrupted system call".
                proc.kill() if code else proc.terminate()
        for proc in (cap, ff):
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                proc.kill()
        srv.shutdown()
        shutil.rmtree(tmp, ignore_errors=True)
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(code)

    signal.signal(signal.SIGINT, shutdown)
    signal.signal(signal.SIGTERM, shutdown)

    try:
        # Enough segments for the TV to start --buffer seconds back.
        wait_for_segments(tmp, int(a.buffer / a.segment) + 2, {"dc-capture": cap, "ffmpeg": ff})
    except StartError as e:
        print(e, flush=True)
        shutdown(code=1)

    print(f"\nServing: {url}")
    if a.no_cast:
        print("Open that URL in Safari or VLC. Ctrl+C to stop.")
    else:
        print(f"Casting to {a.device!r}...")
        try:
            state["cast"], state["browser"] = start_cast(a.device, url)
        except SystemExit as e:
            print(e, flush=True)
            shutdown(code=1)
        print("Casting. Ctrl+C to stop.")

    last = None
    while True:
        time.sleep(1)
        if cap.poll() is not None:
            print("Capture stopped (window closed?).")
            shutdown(code=1)
        if ff.poll() is not None:
            print(f"ffmpeg exited (code {ff.returncode}).")
            shutdown(code=1)
        cast = state["cast"]
        if cast is not None:
            st = cast.media_controller.status
            cur = (st.player_state, getattr(st, "idle_reason", None))
            if cur != last:
                print(f"[tv] {cur[0]}" + (f" ({cur[1]})" if cur[1] else ""))
                last = cur


if __name__ == "__main__":
    main()
