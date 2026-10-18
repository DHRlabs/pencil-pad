import AppKit
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
@preconcurrency import ScreenCaptureKit

/// A captured frame travelling between queues.
private final class PixelBox: @unchecked Sendable {
    let buffer: CVPixelBuffer
    init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Keeps at most two frames in flight (encoding or sent and not yet acknowledged). While both slots are taken the
/// newest captured frame waits; the moment an ack frees a slot it is the one that goes out, so a screen that stops
/// changing still ends on its last picture.
private final class FrameFlow: @unchecked Sendable {
    private let lock = NSLock()
    private var inFlight = 0
    private var sent: [UInt32] = []
    private var pending: PixelBox?
    private var dropped = 0
    private var peak = 0

    /// Frames that had to wait and were replaced, and the most ever in flight, read under the lock.
    func counters() -> (dropped: Int, peak: Int) { lock.lock(); defer { lock.unlock() }; return (dropped, peak) }

    /// A new capture: the frame to encode now, or nil if it had to wait (it replaces any frame already waiting).
    func offer(_ box: PixelBox) -> PixelBox? {
        lock.lock(); defer { lock.unlock() }
        if inFlight < 2 { inFlight += 1; peak = max(peak, inFlight); return box }
        if pending != nil { dropped += 1 }
        pending = box
        return nil
    }

    /// An encoded frame got its number and went to the socket.
    func markSent(_ n: UInt32) { lock.lock(); sent.append(n); lock.unlock() }

    /// An encode that produced nothing frees its slot.
    func release() -> PixelBox? {
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
        return takePending()
    }

    /// The page drew frame `n` (and so every earlier one): their slots free up.
    func ack(_ n: UInt32) -> PixelBox? {
        lock.lock(); defer { lock.unlock() }
        let before = sent.count
        sent.removeAll { $0 <= n }
        inFlight = max(0, inFlight - (before - sent.count))
        return takePending()
    }

    private func takePending() -> PixelBox? {
        guard inFlight < 2, let box = pending else { return nil }
        pending = nil
        inFlight += 1
        peak = max(peak, inFlight)
        return box
    }
}

/// JPEG on the hardware path (VideoToolbox, the media engine on Apple Silicon); ImageIO only if that session cannot exist.
private final class JPEGEncoder: @unchecked Sendable {
    private var session: VTCompressionSession?
    private var size = (w: 0, h: 0)
    private var useImageIO = false
    private let nameLock = NSLock()
    private var pathName = "VideoToolbox"
    /// Which encoder is in use. Read from the sink's reporting thread, so it goes through a lock.
    var path: String { nameLock.lock(); defer { nameLock.unlock() }; return pathName }
    private func setPath(_ name: String) { nameLock.lock(); pathName = name; nameLock.unlock() }
    private var counter: Int64 = 0
    /// Encoded bytes and how long the encode took, in milliseconds. Called on any thread.
    private let finish: @Sendable (Data?, Double) -> Void

    init(finish: @escaping @Sendable (Data?, Double) -> Void) { self.finish = finish }

    deinit { drop() }

    func encode(_ pb: CVPixelBuffer) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if !useImageIO, session == nil || size != (w, h) { makeSession(w, h) }
        let started = DispatchTime.now().uptimeNanoseconds
        let finish = self.finish
        let ms: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
        guard let session, !useImageIO else {
            finish(Self.imageIO(pb), ms())
            return
        }
        counter += 1
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: CMTime(value: counter, timescale: 1000), duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { finish(nil, ms()); return }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { finish(nil, ms()); return }
            finish(Data(bytes: pointer, count: length), ms())
        }
        if status != noErr {
            log.error("projection: JPEG encode failed (OSStatus \(status)); falling back to ImageIO")
            drop(); useImageIO = true; setPath("ImageIO")
            finish(Self.imageIO(pb), ms())
        }
    }

    private func makeSession(_ w: Int, _ h: Int) {
        drop()
        // The media engine's JPEG encoder is asked for outright; the software one is only taken if that cannot be had.
        var made: VTCompressionSession?
        var status = OSStatus(0)
        var kind = ""
        for (key, name) in [(kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder, "VideoToolbox hardware"),
                            (kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder, "VideoToolbox")] {
            made = nil
            status = VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_JPEG,
                                                encoderSpecification: [key: true] as CFDictionary, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                outputCallback: nil, refcon: nil, compressionSessionOut: &made)
            if status == noErr, made != nil { kind = name; break }
        }
        guard status == noErr, let made else {
            log.error("projection: no JPEG session (OSStatus \(status)); using ImageIO")
            useImageIO = true; setPath("ImageIO")
            return
        }
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_Quality, value: 0.6 as CFNumber)
        VTSessionSetProperty(made, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTCompressionSessionPrepareToEncodeFrames(made)
        setPath(kind)  // this encoder has no "using hardware" property to read: the session that required it is the proof
        log.notice("projection: JPEG session \(w)x\(h), \(self.path, privacy: .public)")
        session = made
        size = (w, h)
    }

    private func drop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    private static func imageIO(_ pb: CVPixelBuffer) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pb, options: nil, imageOut: &image)
        guard let image else { return nil }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        return CGImageDestinationFinalize(out) ? data as Data : nil
    }
}

/// Receives frames from one SCStream on its own queue, encodes them off the main thread, and hands the JPEG to the
/// main actor. Counts what it did and logs it every few seconds.
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "pencilpad.capture", qos: .userInteractive)
    let flow = FrameFlow()
    private let lock = NSLock()
    private var closed = false
    private var encoder: JPEGEncoder!
    private let onFrame: @Sendable (Data) -> Void
    private let onStopped: @Sendable (String) -> Void
    private var frames = 0, bytes = 0, encodeMs = 0.0, captured = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    init(onFrame: @escaping @Sendable (Data) -> Void, onStopped: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onStopped = onStopped
        super.init()
        encoder = JPEGEncoder { [weak self] data, ms in self?.encoded(data, ms) }
    }

    func close() { lock.lock(); closed = true; lock.unlock() }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !isClosed,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        lock.lock(); captured += 1; lock.unlock()
        if let box = flow.offer(PixelBox(pixels)) { encoder.encode(box.buffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if !isClosed { onStopped(error.localizedDescription) }
    }

    /// The main actor numbered and sent a frame; the page drew `n`.
    func sent(_ n: UInt32) { flow.markSent(n) }
    func acked(_ n: UInt32) {
        if let next = flow.ack(n) { queue.async { [self] in if !isClosed { encoder.encode(next.buffer) } } }
    }

    private func encoded(_ data: Data?, _ ms: Double) {
        guard let data, !isClosed else {
            if let next = flow.release() { queue.async { [self] in if !isClosed { encoder.encode(next.buffer) } } }
            return
        }
        report(data.count, ms)
        onFrame(data)
    }

    private func report(_ size: Int, _ ms: Double) {
        lock.lock()
        frames += 1; bytes += size; encodeMs += ms
        let now = DispatchTime.now().uptimeNanoseconds
        let span = Double(now - windowStart) / 1e9
        guard span >= 5 else { lock.unlock(); return }
        let counts = flow.counters()
        let line = String(format: "%.1f fps sent, %.0f KB/frame, encode avg %.1f ms, %d captured, %d dropped for waiting, peak in flight %d",
                          Double(frames) / span, Double(bytes) / Double(frames) / 1024, encodeMs / Double(frames), captured, counts.dropped, counts.peak)
        frames = 0; bytes = 0; encodeMs = 0; captured = 0; windowStart = now
        lock.unlock()
        log.notice("projection: \(line, privacy: .public) (\(self.encoder.path, privacy: .public))")
    }
}

/// Streams what is under the current target area to the iPad: a window (by itself, even when covered) or the zoomed
/// part of a screen, captured with ScreenCaptureKit, JPEG-encoded on the hardware encoder, one binary frame each.
@MainActor
final class Projection {
    private let targets: Targets
    private let outline: RegionOutline
    /// Both are told which client asked, so nothing is ever sent to a page that did not.
    private let reply: (Int, Bool, String?) -> Void
    private let sendFrame: (Int, Data) -> Void

    private var owner: Int?
    private var want: (w: Int, h: Int)?
    private var stream: SCStream?
    private var sink: FrameSink?
    /// What the running stream is capturing: one window (counted by the Targets' window serial) or one screen.
    private var runningIdentity = ""
    private var applied = ""
    private var busy = false, dirty = false
    private var soon: Task<Void, Never>?
    private var announced = false
    private var nextFrame: UInt32 = 1
    private var askedForAccess = false
    private var restarts = 0
    /// Counts streams, so a frame or a stop that arrives late from an earlier one is ignored.
    private var generation = 0

    init(targets: Targets, outline: RegionOutline, reply: @escaping (Int, Bool, String?) -> Void, sendFrame: @escaping (Int, Data) -> Void) {
        self.targets = targets
        self.outline = outline
        self.reply = reply
        self.sendFrame = sendFrame
    }

    /// `show` on: start, or re-fit a running stream to a new size.
    func show(owner: Int, w: Int, h: Int) {
        if self.owner != owner { retireStream() }  // another page's frames never carry over
        self.owner = owner
        want = (min(max(w, 64), 8192), min(max(h, 64), 8192))
        // Screen Recording: ask once. After that the answer can stay "no" until PencilPad is relaunched, so the
        // stream is simply tried and ScreenCaptureKit's own refusal is what gets reported.
        if !askedForAccess, !CGPreflightScreenCaptureAccess() {
            askedForAccess = true
            _ = CGRequestScreenCaptureAccess()
            fail("Allow PencilPad under Screen Recording in System Settings, then tap Show again")
            return
        }
        reconcileSoon()
    }

    /// `show` off, or the client is gone. Frames already on their way stop mattering at once.
    func hide() {
        want = nil
        owner = nil
        retireStream()
        reconcileSoon(delay: 0)
    }

    /// The target, its size, or the zoomed region changed.
    func retarget() {
        if want != nil { reconcileSoon() }
    }

    func ack(_ n: UInt32) { sink?.acked(n) }

    // MARK: Keeping the stream matched

    private func reconcileSoon(delay: Int = 40) {
        guard soon == nil else { dirty = true; return }
        soon = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(delay))
            guard let self else { return }
            soon = nil
            await reconcile()
        }
    }

    private func reconcile() async {
        if busy { dirty = true; return }
        busy = true
        repeat {
            dirty = false
            await reconcileOnce()
        } while dirty
        busy = false
    }

    /// The configuration for a stream of `base` points (a window or screen) showing `region` of it, in at most `want` pixels.
    private static func configuration(base: CGSize, region: CGRect, want: (w: Int, h: Int)) -> (SCStreamConfiguration, String) {
        let source = CGRect(x: region.minX * base.width, y: region.minY * base.height, width: region.width * base.width, height: region.height * base.height)
        let fit = min(Double(want.w) / source.width, Double(want.h) / source.height)
        var out = CGSize(width: source.width * fit, height: source.height * fit)
        let longSide = max(out.width, out.height)
        if longSide > 2560 { out = CGSize(width: out.width * 2560 / longSide, height: out.height * 2560 / longSide) }
        let width = max(16, Int(out.width.rounded()) & ~1), height = max(16, Int(out.height.rounded()) & ~1)
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.sourceRect = source
        config.scalesToFit = true
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = true
        config.queueDepth = 3
        config.ignoreShadowsSingleWindow = true
        return (config, "\(width)x\(height) \(Int(source.minX.rounded())),\(Int(source.minY.rounded())) \(Int(source.width.rounded()))x\(Int(source.height.rounded()))")
    }

    private func reconcileOnce() async {
        guard let want else { await stopStream(); return }
        let target = targets.current, region = outline.region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let identity = target.id == "window" ? "window #\(targets.windowSerial) pid \(targets.windowPID ?? 0)" : "display \(target.id)"
        do {
            let (config, key) = Self.configuration(base: target.rect.size, region: region, want: want)
            // The same window or screen, only its size or the zoomed region changed: retune the stream, look nothing up.
            if let stream, identity == runningIdentity {
                if key != applied {
                    try await stream.updateConfiguration(config)
                    applied = key
                    log.notice("projection: reconfigured \(identity, privacy: .public) \(key, privacy: .public)")
                }
                return
            }
            log.notice("projection: looking up capturable windows and screens")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: target.id != "window")
            let filter: SCContentFilter
            if target.id == "window" {
                guard let pid = targets.windowPID, let window = Self.match(content.windows, pid: pid, rect: target.rect) else {
                    fail("That window can't be shown right now"); return
                }
                filter = SCContentFilter(desktopIndependentWindow: window)
            } else {
                guard let display = content.displays.first(where: { abs($0.frame.minX - target.rect.minX) < 1 && abs($0.frame.minY - target.rect.minY) < 1
                                                                      && abs($0.frame.width - target.rect.width) < 1 }) else {
                    fail("That screen can't be shown right now"); return
                }
                let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
            }
            await stopStream()
            try await startStream(filter: filter, config: config, identity: identity, key: key, what: target.name)
        } catch {
            if Self.isPermissionRefusal(error) {
                log.error("projection: Screen Recording is not allowed for PencilPad")
                fail("Allow PencilPad under Screen Recording in System Settings, then quit and reopen PencilPad")
            } else {
                log.error("projection: capture failed: \(error.localizedDescription, privacy: .public)")
                fail("Screen capture failed: \(String(error.localizedDescription.prefix(80)))")
            }
        }
    }

    /// ScreenCaptureKit saying the user has not allowed (or has declined) screen recording.
    private static func isPermissionRefusal(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == SCStreamErrorDomain && e.code == SCStreamError.Code.userDeclined.rawValue
    }

    private func startStream(filter: SCContentFilter, config: SCStreamConfiguration, identity: String, key: String, what: String) async throws {
        generation += 1
        let mine = generation
        let sink = FrameSink(
            onFrame: { [weak self] data in DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(data, from: mine) } } },
            onStopped: { [weak self] why in DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamStopped(why, from: mine) } } })
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        announced = false
        nextFrame = 1
        // Set before starting: the first frames can reach the main queue before startCapture returns.
        self.sink = sink
        self.stream = stream
        runningIdentity = identity
        applied = key
        do { try await stream.startCapture() } catch {
            sink.close()
            self.sink = nil
            self.stream = nil
            runningIdentity = ""
            applied = ""
            throw error
        }
        restarts = 0
        log.notice("projection: SCStream started: \(identity, privacy: .public) (\(what, privacy: .public)) \(key, privacy: .public)")
    }

    /// Cuts the running stream off from the socket, right now: its frame queue is closed and the stream counter moves
    /// on, so nothing already encoded or queued can reach whoever connects next. The capture itself is stopped after.
    private func retireStream() {
        generation += 1
        sink?.close()
        runningIdentity = ""
        applied = ""
    }

    private func stopStream() async {
        guard let stream else { return }
        retireStream()
        self.stream = nil
        self.sink = nil
        do { try await stream.stopCapture() } catch { log.error("projection: stopCapture: \(error.localizedDescription, privacy: .public)") }
        log.notice("projection: SCStream stopped")
    }

    /// A frame is encoded: number it and send it. The first one also tells the page the stream is up.
    private func deliver(_ data: Data, from mine: Int) {
        guard mine == generation, let owner, let sink, stream != nil else { return }
        if !announced { announced = true; reply(owner, true, nil) }
        let n = nextFrame
        nextFrame &+= 1
        sink.sent(n)
        var frame = Data(capacity: data.count + 4)
        frame.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        frame.append(data)
        sendFrame(owner, frame)
    }

    /// The stream ended without being asked to (the window closed, the display went away): try once more, else say so.
    private func streamStopped(_ why: String, from mine: Int) {
        guard mine == generation, stream != nil else { return }
        log.notice("projection: SCStream stopped by the system: \(why, privacy: .public)")
        retireStream()
        stream = nil
        sink = nil
        restarts += 1
        if restarts <= 2, want != nil { reconcileSoon(delay: 300) } else { fail("The picture stopped: \(String(why.prefix(60)))") }
    }

    /// Stops, remembers nothing, and tells the page why.
    private func fail(_ why: String) {
        want = nil
        if let owner { reply(owner, false, why) }
        owner = nil
        retireStream()
        reconcileSoon(delay: 0)
    }

    /// The SCWindow that is the target: same app, and the frame the Accessibility API reported.
    private static func match(_ windows: [SCWindow], pid: pid_t, rect: CGRect) -> SCWindow? {
        func gap(_ w: SCWindow) -> CGFloat {
            abs(w.frame.minX - rect.minX) + abs(w.frame.minY - rect.minY) + abs(w.frame.width - rect.width) + abs(w.frame.height - rect.height)
        }
        return windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            .min { gap($0) < gap($1) }
            .flatMap { gap($0) < 12 ? $0 : nil }
    }
}
