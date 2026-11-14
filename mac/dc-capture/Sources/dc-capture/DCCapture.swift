// dc-capture: captures one window (the popped-out Discord stream) plus its app's
// audio with ScreenCaptureKit and writes them, paced to a fixed frame rate, to two
// pipes that ffmpeg reads:
//   video: raw NV12 (video range, BT.709), width x height, `fps` frames per second
//   audio: raw float32 little-endian, 48 kHz, stereo interleaved, 48000/fps samples per frame
//
// Video and audio are written in lockstep from one clock, so they stay in sync
// even when the window stops updating (the last frame is repeated) or Discord
// goes quiet (silence is written).
//
// Usage:
//   dc-capture list [--all]
//   dc-capture capture --window ID --video PATH --audio PATH [--width 1920] [--height 1080] [--fps 60] [--no-crop]

import Accelerate
import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

@main
struct DCCapture {
    @MainActor
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        signal(SIGTERM) { _ in exit(0) }
        signal(SIGINT) { _ in exit(0) }

        // A command-line tool has no WindowServer connection by default, and SCStream
        // asserts on that (CGS_REQUIRE_INIT). Creating the shared NSApplication sets it
        // up; .prohibited keeps the helper out of the Dock and app switcher.
        NSApplication.shared.setActivationPolicy(.prohibited)
        _ = CGMainDisplayID()

        let args = Array(CommandLine.arguments.dropFirst())
        guard let cmd = args.first else { usage(); exit(2) }

        if !CGPreflightScreenCaptureAccess() {
            CGRequestScreenCaptureAccess()
            fputs("""
                dc-capture: Screen Recording permission is needed.
                Turn on Terminal in System Settings > Privacy & Security > Screen & System Audio Recording,
                then quit and reopen Terminal.\n
                """, stderr)
            exit(3)
        }

        do {
            switch cmd {
            case "list":
                try await listWindows(all: args.contains("--all"))
            case "capture":
                let opts = try Options(Array(args.dropFirst()))
                try await runCapture(opts)
            default:
                usage()
                exit(2)
            }
        } catch {
            fputs("dc-capture: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func usage() {
        fputs("""
            usage: dc-capture list [--all]
                   dc-capture capture --window ID --video PATH --audio PATH [--width W] [--height H] [--fps N]\n
            """, stderr)
    }
}

// MARK: - Options

struct CaptureError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

struct Options {
    var windowID: CGWindowID = 0
    var videoPath = ""
    var audioPath = ""
    var width = 1920
    var height = 1080
    var fps = 60
    var crop = true

    init(_ args: [String]) throws {
        var i = 0
        func value() throws -> String {
            guard i + 1 < args.count else { throw CaptureError("missing value for \(args[i])") }
            i += 1
            return args[i]
        }
        while i < args.count {
            let key = args[i]
            guard key.hasPrefix("--") else { throw CaptureError("unexpected argument \(key)") }
            if key == "--no-crop" {
                crop = false
                i += 1
                continue
            }
            let v = try value()
            switch key {
            case "--window": windowID = CGWindowID(v) ?? 0
            case "--video": videoPath = v
            case "--audio": audioPath = v
            case "--width": width = Int(v) ?? width
            case "--height": height = Int(v) ?? height
            case "--fps": fps = Int(v) ?? fps
            default: throw CaptureError("unknown option \(key)")
            }
            i += 1
        }
        guard windowID != 0 else { throw CaptureError("--window is required (see: dc-capture list)") }
        guard !videoPath.isEmpty, !audioPath.isEmpty else { throw CaptureError("--video and --audio are required") }
        guard width % 2 == 0, height % 2 == 0 else { throw CaptureError("width and height must be even") }
        guard fps > 0, 48000 % fps == 0 else { throw CaptureError("fps must divide 48000 (e.g. 24, 30, 50, 60)") }
    }
}

// MARK: - list

func isDiscord(_ app: SCRunningApplication) -> Bool {
    app.bundleIdentifier.hasPrefix("com.hnc.Discord")
        || app.applicationName.localizedCaseInsensitiveContains("discord")
}

/// One line per window: "<id>\t<description>". Read by the launcher's menu.
func listWindows(all: Bool) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    let windows = content.windows
        .filter { w in
            guard let app = w.owningApplication else { return false }
            return (all || isDiscord(app)) && w.windowLayer == 0
                && w.frame.width >= 200 && w.frame.height >= 150
        }
        .sorted { ($0.frame.width * $0.frame.height) > ($1.frame.width * $1.frame.height) }

    for w in windows {
        let app = w.owningApplication?.applicationName ?? "?"
        let title = (w.title?.isEmpty == false) ? w.title! : "(untitled)"
        let size = "\(Int(w.frame.width))x\(Int(w.frame.height))"
        let hidden = w.isOnScreen ? "" : "  (not on screen)"
        print("\(w.windowID)\t\(app): \(title)  [\(size)]\(hidden)")
    }
}

// MARK: - capture

func runCapture(_ o: Options) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
    guard let window = content.windows.first(where: { $0.windowID == o.windowID }) else {
        throw CaptureError("window \(o.windowID) not found (closed?). Run `dc-capture list` again.")
    }

    let capturer = Capturer(o)
    try await capturer.start(window: window, content: content)

    let writer = Thread { capturer.writerLoop() }
    writer.qualityOfService = .userInteractive
    writer.name = "dc-capture.writer"
    writer.start()

    // Stay alive until the writer stops (ffmpeg closed the pipes) or a signal arrives.
    while !capturer.finished {
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    await capturer.stop()
    exit(capturer.exitCode)
}

final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let o: Options
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var audio: [Float] = []          // interleaved stereo, guarded by lock
    private var audioPrimed = false
    private var sawAudio = false
    private var scStream: SCStream?
    private var audioStream: SCStream?
    private var srcWidth = 0
    private var srcHeight = 0
    private var audioPeak: Float = 0          // since last report, guarded by lock
    private var detections: [(time: Double, box: Box)] = []
    private var currentCrop: Box?
    private let videoQueue = DispatchQueue(label: "dc-capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dc-capture.audio", qos: .userInteractive)

    private(set) var finished = false
    private(set) var exitCode: Int32 = 0

    init(_ o: Options) { self.o = o }

    func start(window: SCWindow, content: SCShareableContent) async throws {
        // Capture the window at its own pixel size (Retina), not squeezed into the output
        // size. The writer crops away black borders / window chrome and scales to fit.
        let wf = window.frame
        let scale = await MainActor.run {
            NSScreen.screens.first(where: { $0.frame.intersects(wf) })?.backingScaleFactor ?? 2
        }
        srcWidth = max(2, Int(window.frame.width * scale) & ~1)
        srcHeight = max(2, Int(window.frame.height * scale) & ~1)

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width = srcWidth
        cfg.height = srcHeight
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorSpaceName = CGColorSpace.itur_709
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        cfg.queueDepth = 5
        cfg.showsCursor = false
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        // No backgroundColor: the property doesn't retain its CGColor, so a temporary
        // one is freed before SCStream copies the config (crash). The default is black.

        // Audio. Discord (Electron) plays sound from helper processes, not the process
        // that owns the window, so a window-only capture hears nothing. Capture audio
        // separately from every Discord process.
        let discordApps = content.applications.filter { isDiscord($0) }
        let display = content.displays.first(where: { $0.frame.intersects(window.frame) }) ?? content.displays.first
        let separateAudio = !discordApps.isEmpty && display != nil
        cfg.capturesAudio = !separateAudio
        if !separateAudio {
            cfg.sampleRate = 48000
            cfg.channelCount = 2
        }

        logLine("creating stream (\(srcWidth)x\(srcHeight) source)")
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        if !separateAudio {
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        }
        logLine("starting capture")
        try await s.startCapture()
        scStream = s

        if separateAudio, let display {
            let names = discordApps.map { $0.applicationName }.joined(separator: ", ")
            logLine("audio from: \(names)")
            let afilter = SCContentFilter(display: display, including: discordApps, exceptingWindows: [])
            let acfg = SCStreamConfiguration()
            acfg.width = 2
            acfg.height = 2
            acfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            acfg.queueDepth = 3
            acfg.showsCursor = false
            acfg.capturesAudio = true
            acfg.sampleRate = 48000
            acfg.channelCount = 2
            acfg.excludesCurrentProcessAudio = true
            let a = SCStream(filter: afilter, configuration: acfg, delegate: self)
            try a.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            try await a.startCapture()
            audioStream = a
        }
        logLine("capturing window \(o.windowID) -> \(o.width)x\(o.height)@\(o.fps)")
    }

    func stop() async {
        try? await scStream?.stopCapture()
        try? await audioStream?.stopCapture()
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if stream === audioStream {
            logLine("audio capture stopped: \(error.localizedDescription) (continuing without audio)")
            return
        }
        fputs("dc-capture: capture stopped: \(error.localizedDescription)\n", stderr)
        exitCode = 1
        finished = true
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sb) else { return }
        switch type {
        case .screen:
            guard
                let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false)
                    as? [[SCStreamFrameInfo: Any]],
                let raw = attachments.first?[.status] as? Int,
                SCFrameStatus(rawValue: raw) == .complete,
                let pb = CMSampleBufferGetImageBuffer(sb)
            else { return }
            lock.lock()
            if latest == nil { logLine("first video frame \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))") }
            latest = pb
            lock.unlock()
        case .audio:
            appendAudio(sb)
        default:
            break
        }
    }

    private func appendAudio(_ sb: CMSampleBuffer) {
        guard
            let fmt = CMSampleBufferGetFormatDescription(sb),
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee,
            asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32
        else { return }

        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        let channels = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        guard needed > 0 else { return }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var block: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &block)
        guard status == noErr else { return }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)

        // Convert to interleaved stereo.
        var out = [Float](repeating: 0, count: frames * 2)
        if nonInterleaved {
            let l = abl.count > 0 ? abl[0].mData?.assumingMemoryBound(to: Float.self) : nil
            let r = abl.count > 1 ? abl[1].mData?.assumingMemoryBound(to: Float.self) : l
            guard let l, let r else { return }
            for i in 0..<frames {
                out[2 * i] = l[i]
                out[2 * i + 1] = r[i]
            }
        } else {
            guard abl.count > 0, channels > 0,
                  let p = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<frames {
                out[2 * i] = p[i * channels]
                out[2 * i + 1] = p[i * channels + (channels > 1 ? 1 : 0)]
            }
        }

        var peak: Float = 0
        for v in out { peak = max(peak, abs(v)) }
        lock.lock()
        audioPeak = max(audioPeak, peak)
        if !sawAudio { logLine("first audio: \(frames) frames, \(channels) ch, \(nonInterleaved ? "planar" : "interleaved")") }
        audio.append(contentsOf: out)
        sawAudio = true
        lock.unlock()
    }

    // MARK: Writer

    /// Writes one video frame and 48000/fps audio frames per tick, paced by the system clock.
    func writerLoop() {
        // Pipe order matters. ffmpeg opens its inputs one at a time and reads a little
        // from each before opening the next, and a video frame is bigger than a pipe
        // buffer. So audio is ffmpeg's first input: open it, write one tick of audio
        // (fits in the pipe buffer), then open video. After that, every tick writes
        // audio then video.
        let afd = open(o.audioPath, O_WRONLY)   // blocks until ffmpeg opens it
        guard afd >= 0 else {
            fputs("dc-capture: couldn't open the audio pipe\n", stderr)
            exitCode = 1
            finished = true
            return
        }
        logLine("audio pipe open")
        var vfd: Int32 = -1
        defer {
            close(afd)
            if vfd >= 0 { close(vfd) }
            finished = true
        }

        let w = o.width, h = o.height
        // Start on a black frame (video range: Y=16, Cb=Cr=128) until the first capture arrives.
        var frame = [UInt8](repeating: 128, count: w * h * 3 / 2)
        frame.withUnsafeMutableBytes { _ = memset($0.baseAddress!, 16, w * h) }

        let samplesPerTick = 48000 / o.fps
        let floatsPerTick = samplesPerTick * 2
        let primeFloats = floatsPerTick + 48000 / 25 * 2   // ~40 ms jitter buffer
        let maxFloats = 48000 / 8 * 2                        // cap at ~125 ms to bound delay
        var audioOut = [Float](repeating: 0, count: floatsPerTick)

        let period = 1.0 / Double(o.fps)
        var start = Date().timeIntervalSinceReferenceDate
        var n = 0
        var warnedNoAudio = false
        var lastBuffer: CVPixelBuffer?

        while !finished {
            // Video: copy the newest captured frame if it changed.
            lock.lock()
            let pb = latest
            lock.unlock()
            if let pb, pb !== lastBuffer {
                renderFrame(pb, into: &frame)
                lastBuffer = pb
            }

            // Audio: take one tick's worth, or silence while (re)filling the jitter buffer.
            lock.lock()
            if audio.count > maxFloats { audio.removeFirst(audio.count - maxFloats) }
            if !audioPrimed && audio.count >= primeFloats { audioPrimed = true }
            if audioPrimed && audio.count >= floatsPerTick {
                audio.withUnsafeBufferPointer { src in
                    audioOut.withUnsafeMutableBufferPointer { dst in
                        _ = memcpy(dst.baseAddress!, src.baseAddress!, floatsPerTick * MemoryLayout<Float>.size)
                    }
                }
                audio.removeFirst(floatsPerTick)
            } else {
                audioPrimed = false
                for i in 0..<floatsPerTick { audioOut[i] = 0 }
            }
            let gotAudio = sawAudio
            lock.unlock()

            if !audioOut.withUnsafeBytes({ writeAll(afd, $0.baseAddress!, $0.count) }) { return }  // ffmpeg went away
            if vfd < 0 {
                vfd = open(o.videoPath, O_WRONLY)   // blocks until ffmpeg has probed audio and opens video
                guard vfd >= 0 else {
                    fputs("dc-capture: couldn't open the video pipe\n", stderr)
                    exitCode = 1
                    return
                }
                logLine("video pipe open; streaming")
            }
            if !frame.withUnsafeBytes({ writeAll(vfd, $0.baseAddress!, $0.count) }) { return }

            n += 1
            if n % (o.fps * 5) == 0 {
                lock.lock()
                let p = audioPeak
                audioPeak = 0
                lock.unlock()
                let db = p > 0 ? 20 * log10(p) : -120
                logLine(String(format: "audio peak %.0f dBFS%@", db, db < -60 ? " (silent)" : ""))
            }
            if !warnedNoAudio && !gotAudio && n == o.fps * 5 {
                fputs("dc-capture: no audio from Discord yet (sending silence)\n", stderr)
                warnedNoAudio = true
            }

            let now = Date().timeIntervalSinceReferenceDate
            let wait = start + Double(n) * period - now
            if wait > 0 {
                Thread.sleep(forTimeInterval: wait)
            } else if wait < -0.25 {
                start = now - Double(n) * period   // fell far behind; don't burst to catch up
            }
        }
    }

    // MARK: Crop + scale

    /// Copies the captured frame into the output frame: crops away black borders and
    /// dark window chrome around the video, then scales it to fill the output while
    /// keeping its aspect ratio.
    private func renderFrame(_ pb: CVPixelBuffer, into frame: inout [UInt8]) {
        let w = o.width, h = o.height
        guard CVPixelBufferGetPlaneCount(pb) == 2 else { return }
        let sw = CVPixelBufferGetWidth(pb) & ~1, sh = CVPixelBufferGetHeight(pb) & ~1
        guard sw >= 2, sh >= 2 else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)

        let crop = o.crop ? updateCrop(y: y, stride: yStride, width: sw, height: sh)
                          : Box(x0: 0, y0: 0, x1: sw, y1: sh)
        let cw = crop.x1 - crop.x0, ch = crop.y1 - crop.y0

        // Fit the crop into w x h, centered, even-aligned.
        let s = min(Double(w) / Double(cw), Double(h) / Double(ch))
        let dw = min(w, max(2, Int(Double(cw) * s) & ~1))
        let dh = min(h, max(2, Int(Double(ch) * s) & ~1))
        let dx = ((w - dw) / 2) & ~1, dy = ((h - dh) / 2) & ~1

        let layout = Box(x0: dx, y0: dy, x1: dx + dw, y1: dy + dh)
        if layout != lastLayout {
            // Letterbox areas changed: clear to black.
            frame.withUnsafeMutableBytes { b in
                memset(b.baseAddress!, 16, w * h)
                memset(b.baseAddress! + w * h, 128, w * h / 2)
            }
            lastLayout = layout
        }

        frame.withUnsafeMutableBytes { b in
            let base = b.baseAddress!
            var srcY = vImage_Buffer(data: y + crop.y0 * yStride + crop.x0,
                                     height: vImagePixelCount(ch), width: vImagePixelCount(cw), rowBytes: yStride)
            var dstY = vImage_Buffer(data: base + dy * w + dx,
                                     height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: w)
            vImageScale_Planar8(&srcY, &dstY, nil, vImage_Flags(kvImageHighQualityResampling))

            var srcUV = vImage_Buffer(data: uv + (crop.y0 / 2) * uvStride + crop.x0,
                                      height: vImagePixelCount(ch / 2), width: vImagePixelCount(cw / 2), rowBytes: uvStride)
            var dstUV = vImage_Buffer(data: base + w * h + (dy / 2) * w + dx,
                                      height: vImagePixelCount(dh / 2), width: vImagePixelCount(dw / 2), rowBytes: w)
            vImageScale_CbCr8(&srcUV, &dstUV, nil, vImage_Flags(kvImageHighQualityResampling))
        }
    }

    private var lastLayout: Box?
    private var framesSinceDetect = 0

    /// Returns the crop box, re-detecting the video area about twice a second. The box is
    /// the union of detections from the last 10 s, so a dark scene doesn't shrink it and
    /// hovering Discord's controls only widens it briefly.
    private func updateCrop(y: UnsafeMutableRawPointer, stride: Int, width: Int, height: Int) -> Box {
        let full = Box(x0: 0, y0: 0, x1: width, y1: height)
        framesSinceDetect += 1
        let now = Date().timeIntervalSinceReferenceDate
        if currentCrop == nil || framesSinceDetect >= max(1, o.fps / 4) {
            framesSinceDetect = 0
            if let b = detectContent(y: y.assumingMemoryBound(to: UInt8.self), stride: stride, width: width, height: height) {
                detections.append((time: now, box: b))
            }
            detections.removeAll { now - $0.time > 10 }
            var u: Box? = nil
            for d in detections { u = u.map { $0.union(d.box) } ?? d.box }
            let next = (u ?? full).clamped(to: full).evenAligned()
            // Small wobble (hover controls, compression noise) shouldn't re-layout the frame.
            if currentCrop == nil || !currentCrop!.nearlyEqual(next) {
                logLine("video area \(next.x1 - next.x0)x\(next.y1 - next.y0) at \(next.x0),\(next.y0) of \(width)x\(height)")
                currentCrop = next
            }
        }
        return (currentCrop ?? full).clamped(to: full).evenAligned()
    }

    /// Bounding box of rows/columns that aren't (nearly) black or dark-gray chrome.
    /// Returns nil when the frame is mostly dark (can't tell where the video is).
    private func detectContent(y: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int) -> Box? {
        let threshold: UInt8 = 52      // video-range luma; Discord's dark chrome sits below this
        let step = 4
        func rowHasContent(_ r: Int) -> Bool {
            var hits = 0, total = 0
            var x = 0
            while x < width { total += 1; if y[r * stride + x] > threshold { hits += 1 }; x += step }
            return hits * 50 > total   // > 2% of the row
        }
        func colHasContent(_ c: Int, _ r0: Int, _ r1: Int) -> Bool {
            var hits = 0, total = 0
            var r = r0
            while r < r1 { total += 1; if y[r * stride + c] > threshold { hits += 1 }; r += step }
            return total > 0 && hits * 50 > total
        }
        var top = 0
        while top < height && !rowHasContent(top) { top += 2 }
        var bottom = height - 1
        while bottom > top && !rowHasContent(bottom) { bottom -= 2 }
        guard bottom > top else { return nil }
        var left = 0
        while left < width && !colHasContent(left, top, bottom) { left += 2 }
        var right = width - 1
        while right > left && !colHasContent(right, top, bottom) { right -= 2 }
        guard right > left else { return nil }
        let box = Box(x0: left, y0: top, x1: right + 1, y1: bottom + 1)
        // Too small to be the video (dark scene, or just a few bright UI bits).
        if (box.x1 - box.x0) * (box.y1 - box.y0) * 4 < width * height { return nil }
        return box
    }
}

struct Box: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int
    func union(_ b: Box) -> Box {
        Box(x0: min(x0, b.x0), y0: min(y0, b.y0), x1: max(x1, b.x1), y1: max(y1, b.y1))
    }
    func clamped(to f: Box) -> Box {
        Box(x0: max(x0, f.x0), y0: max(y0, f.y0), x1: min(x1, f.x1), y1: min(y1, f.y1))
    }
    func evenAligned() -> Box {
        var b = Box(x0: x0 & ~1, y0: y0 & ~1, x1: (x1 + 1) & ~1, y1: (y1 + 1) & ~1)
        if b.x1 - b.x0 < 2 { b.x1 = b.x0 + 2 }
        if b.y1 - b.y0 < 2 { b.y1 = b.y0 + 2 }
        return b
    }
    func nearlyEqual(_ b: Box) -> Bool {
        let tol = max(8, (x1 - x0) / 100)
        return abs(x0 - b.x0) <= tol && abs(y0 - b.y0) <= tol && abs(x1 - b.x1) <= tol && abs(y1 - b.y1) <= tol
    }
}

func logLine(_ msg: String) {
    fputs("dc-capture: \(msg)\n", stderr)
}

func writeAll(_ fd: Int32, _ ptr: UnsafeRawPointer, _ count: Int) -> Bool {
    var off = 0
    while off < count {
        let r = write(fd, ptr + off, count - off)
        if r < 0 {
            if errno == EINTR { continue }
            return false
        }
        off += r
    }
    return true
}
