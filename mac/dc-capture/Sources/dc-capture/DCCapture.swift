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
//   dc-capture capture --window ID --video PATH --audio PATH [--width 1920] [--height 1080] [--fps 60]

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
    try await capturer.start(window: window)

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
    private let videoQueue = DispatchQueue(label: "dc-capture.video", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "dc-capture.audio", qos: .userInteractive)

    private(set) var finished = false
    private(set) var exitCode: Int32 = 0

    init(_ o: Options) { self.o = o }

    func start(window: SCWindow) async throws {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let cfg = SCStreamConfiguration()
        cfg.width = o.width
        cfg.height = o.height
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.colorSpaceName = CGColorSpace.itur_709
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(o.fps))
        cfg.queueDepth = 5
        cfg.showsCursor = false
        cfg.scalesToFit = true
        cfg.preservesAspectRatio = true
        // No backgroundColor: the property doesn't retain its CGColor, so a temporary
        // one is freed before SCStream copies the config (crash). The default is black.
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true

        logLine("creating stream")
        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        logLine("starting capture")
        try await s.startCapture()
        scStream = s
        fputs("dc-capture: capturing window \(o.windowID) at \(o.width)x\(o.height)@\(o.fps)\n", stderr)
    }

    func stop() async {
        try? await scStream?.stopCapture()
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
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

        lock.lock()
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
                copyNV12(pb, into: &frame)
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

    private func copyNV12(_ pb: CVPixelBuffer, into frame: inout [UInt8]) {
        let w = o.width, h = o.height
        guard CVPixelBufferGetWidth(pb) == w, CVPixelBufferGetHeight(pb) == h,
              CVPixelBufferGetPlaneCount(pb) == 2 else { return }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) else { return }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        frame.withUnsafeMutableBytes { dst in
            let base = dst.baseAddress!
            for row in 0..<h {
                memcpy(base + row * w, y + row * yStride, w)
            }
            let uvBase = base + w * h
            for row in 0..<(h / 2) {
                memcpy(uvBase + row * w, uv + row * uvStride, w)
            }
        }
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
