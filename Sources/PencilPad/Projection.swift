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
    /// The epoch (see `Projection.accepted`) whose window and crop it was captured under; it keeps this through buffering and encoding.
    let tag: Int
    init(_ buffer: CVPixelBuffer, tag: Int) { self.buffer = buffer; self.tag = tag }
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

    /// What waits for a slot is of a configuration that is gone. What is in flight keeps its slot until it is acknowledged or
    /// finds out it is stale, so the page's two-frame limit holds across a restart.
    func dropPending() { lock.lock(); pending = nil; lock.unlock() }

    /// What waits for a slot is of a configuration that is still in force, now under another tag.
    func retagPending(_ tag: Int) {
        lock.lock(); if let box = pending { pending = PixelBox(box.buffer, tag: tag) }; lock.unlock()
    }

    var hasPending: Bool { lock.lock(); defer { lock.unlock() }; return pending != nil }

    /// A slot for a frame that needs no encode (the last picture sent again); false when both are taken.
    func reserve() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard inFlight < 2 else { return false }
        inFlight += 1; peak = max(peak, inFlight)
        return true
    }

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
    private let finish: @Sendable (Data?, Double, Int) -> Void

    init(finish: @escaping @Sendable (Data?, Double, Int) -> Void) { self.finish = finish }

    deinit { drop() }

    func encode(_ pb: CVPixelBuffer, tag: Int) {
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        if !useImageIO, session == nil || size != (w, h) { makeSession(w, h) }
        let started = DispatchTime.now().uptimeNanoseconds
        let finish = self.finish
        let ms: @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6 }
        guard let session, !useImageIO else {
            finish(Self.imageIO(pb), ms(), tag)
            return
        }
        counter += 1
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: CMTime(value: counter, timescale: 1000), duration: .invalid,
            frameProperties: nil, infoFlagsOut: nil
        ) { status, _, sample in
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { finish(nil, ms(), tag); return }
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
                  let pointer else { finish(nil, ms(), tag); return }
            finish(Data(bytes: pointer, count: length), ms(), tag)
        }
        if status != noErr {
            log.error("projection: JPEG encode failed (OSStatus \(status)); falling back to ImageIO")
            drop(); useImageIO = true; setPath("ImageIO")
            finish(Self.imageIO(pb), ms(), tag)
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
///
/// Every sample is tagged, when it arrives, with the epoch whose configuration the stream is known to be running: the tag is
/// set only once a window and crop have been applied (`resume`), and samples are dropped while a request is being applied
/// (`pause`) and, after a reconfiguration, until the first one the stream made under the new configuration. The tag then stays
/// with the pixels through the two-in-flight window and the encoder; a result under any other tag is dropped.
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "pencilpad.capture", qos: .userInteractive)
    let flow = FrameFlow()
    private let lock = NSLock()
    private var closed = false
    private var encoder: JPEGEncoder!
    private let onFrame: @Sendable (Data, Int) -> Void
    private let onStopped: @Sendable (String) -> Void
    /// The epoch new samples are made under; nil while a request is being applied (samples are dropped).
    private var tag: Int?
    /// Host-clock seconds: a sample stamped earlier was made before the new configuration was in force.
    private var notBefore: Double?
    private var frames = 0, bytes = 0, encodeMs = 0.0, captured = 0
    private var windowStart = DispatchTime.now().uptimeNanoseconds

    init(onFrame: @escaping @Sendable (Data, Int) -> Void, onStopped: @escaping @Sendable (String) -> Void) {
        self.onFrame = onFrame
        self.onStopped = onStopped
        super.init()
        encoder = JPEGEncoder { [weak self] data, ms, tag in self?.encoded(data, ms, tag) }
    }

    /// A request is being applied: what is captured, waiting or encoding for the configuration in force is never sent.
    func pause() {
        lock.lock(); tag = nil; lock.unlock()
        flow.dropPending()
    }

    /// The configuration for `tag` is in force: samples are tagged with it from now on. `notBefore` (host-clock seconds) is when the
    /// last reconfiguration finished: a sample stamped before it was made under the crop before.
    func resume(tag: Int, notBefore: Double?) {
        lock.lock(); self.tag = tag; self.notBefore = notBefore; lock.unlock()
        flow.retagPending(tag)  // only ever waiting when the window and crop did not change (a pause drops it)
    }

    /// The epoch samples are being tagged with now, if any.
    var liveTag: Int? { lock.lock(); defer { lock.unlock() }; return tag }

    func close() { lock.lock(); closed = true; lock.unlock() }
    private var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, !isClosed,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let stamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        lock.lock()
        captured += 1
        guard let tag, notBefore.map({ !stamp.isFinite || stamp >= $0 }) ?? true else { lock.unlock(); return }
        lock.unlock()
        run(flow.offer(PixelBox(pixels, tag: tag)))
    }

    /// One picture made on request (see `Projection.captureStill`), under the epoch it was asked for.
    func inject(_ pixels: CVPixelBuffer, tag: Int) {
        guard liveTag == tag else { return }
        let box = PixelBox(pixels, tag: tag)
        queue.async { [self] in run(flow.offer(box)) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        if !isClosed { onStopped(error.localizedDescription) }
    }

    /// The main actor numbered and sent a frame; the page drew `n`.
    func sent(_ n: UInt32) { flow.markSent(n) }
    func acked(_ n: UInt32) { queue.async { [self] in run(flow.ack(n)) } }
    /// A frame that was encoded was not sent: its slot is free again.
    func abandoned() { queue.async { [self] in run(flow.release()) } }

    /// Encodes `box` if it is still of the epoch in force; one that is not frees its slot and the next waiting one is tried.
    private func run(_ first: PixelBox?) {
        var box = first
        while let b = box {
            if !isClosed, liveTag == b.tag { encoder.encode(b.buffer, tag: b.tag); return }
            box = flow.release()
        }
    }

    private func encoded(_ data: Data?, _ ms: Double, _ tag: Int) {
        guard let data, !isClosed, tag == liveTag else {  // failed, or made under a configuration that has been replaced
            queue.async { [self] in run(flow.release()) }
            return
        }
        report(data.count, ms)
        onFrame(data, tag)
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
///
/// Which picture a frame belongs to travels with its pixels. The page numbers what it wants to see (`rev`) and sends the number
/// with every `show` and `region`. Each accepted request starts an epoch here; samples are tagged with the epoch whose window
/// and crop were actually applied when they were made (see `FrameSink`), and a frame goes out with the page's `rev` for that
/// epoch, so the page can tell a picture of what it has moved away from and not draw it. Requests are coalesced while one is
/// being applied, and every accepted request gets at least one frame, even from a window that has stopped changing.
@MainActor
final class Projection {
    private let targets: Targets
    private let outline: RegionOutline
    /// Both are told which client asked, so nothing is ever sent to a page that did not.
    private let reply: (Int, Bool, String?) -> Void
    private let sendFrame: (Int, Data) -> Void

    private var owner: Int?
    /// The owner's page tags what it asks for (hello `v` 2); main's page does not, and gets main's frames.
    private var tagged = false
    private var want: (w: Int, h: Int)?
    private var stream: SCStream?
    private var sink: FrameSink?
    /// What the running stream is capturing: one window (counted by the Targets' window serial) or one screen.
    private var runningIdentity = ""
    private var applied = ""
    private var runningFilter: SCContentFilter?
    private var runningConfig: SCStreamConfiguration?
    private var busy = false, dirty = false
    private var soon: Task<Void, Never>?
    private var still: Task<Void, Never>?
    private var announced = false
    private var nextFrame: UInt32 = 1
    private var askedForAccess = false
    private var restarts = 0
    /// Counts streams, so a frame or a stop that arrives late from an earlier one is ignored.
    private var generation = 0
    /// Moves with every accepted request (and every change the Mac makes to what it captures). Samples are tagged with it.
    private var epoch = 0
    /// The newest `rev` the page asked for (16 bits), and the one the epoch now in force answers.
    private var wantRev: UInt16 = 0
    private var liveRev: UInt16 = 0
    /// Host-clock seconds at which the running stream last finished being retuned (nil: it has not been): earlier samples are of the old crop.
    private var appliedAt: Double?
    /// The last picture delivered under the configuration in force (nil once that changes), and the last epoch that got a frame.
    private var lastGood: Data?
    private var deliveredEpoch = -1
    /// Moves on every request, stop and window choice, so a lookup, stop or start that finishes after a newer one can tell and is dropped.
    private var request = 0
    /// Configurations applied to the running stream (logged, so a burst of requests can be seen to have been coalesced).
    private var configurations = 0

    /// Samples taken for a rev that has none within this long of its configuration being applied are replaced by one still capture.
    private static let stillAfter = 70

    init(targets: Targets, outline: RegionOutline, reply: @escaping (Int, Bool, String?) -> Void, sendFrame: @escaping (Int, Data) -> Void) {
        self.targets = targets
        self.outline = outline
        self.reply = reply
        self.sendFrame = sendFrame
    }

    /// `show` on: start, or re-fit a running stream to a new size.
    func show(owner: Int, w: Int, h: Int, rev: UInt16, tagged: Bool) {
        if self.owner != owner { retireStream() }  // another page's frames never carry over
        self.owner = owner
        self.tagged = tagged
        want = (min(max(w, 64), 8192), min(max(h, 64), 8192))
        // Screen Recording: ask once. After that the answer can stay "no" until PencilPad is relaunched, so the
        // stream is simply tried and ScreenCaptureKit's own refusal is what gets reported.
        if !askedForAccess, !CGPreflightScreenCaptureAccess() {
            askedForAccess = true
            _ = CGRequestScreenCaptureAccess()
            fail("Allow PencilPad under Screen Recording in System Settings, then tap Show again")
            return
        }
        accepted(rev)
    }

    /// `show` off, or the client is gone. Frames already on their way stop mattering at once.
    func hide() {
        want = nil
        owner = nil
        request += 1
        retireStream()
        reconcileSoon(delay: 0)
    }

    /// The page moved the zoomed region.
    func region(rev: UInt16) {
        if want != nil { accepted(rev) }
    }

    /// The target or its size changed on the Mac's side (a window moved or was resized). Nothing happens if what is captured stays the same.
    func retarget() {
        guard want != nil else { return }
        if !changesCapture() { return }
        accepted(wantRev)
    }

    /// A window choice: what was captured is of another window now. The old stream sends nothing more and a new one is made,
    /// so even a window that never changes sends its first frame; this also supersedes any lookup still out.
    func choose() {
        request += 1
        epoch += 1
        retireStream()
        if want != nil { reconcileSoon() }
    }

    func ack(_ n: UInt32) { sink?.acked(n) }

    /// A request for a picture under `rev` is in. Whatever was captured for the configuration in force stops being sent; when the
    /// window and crop turn out to be the same it goes on at once under the new tag, else once the new configuration is applied.
    private func accepted(_ rev: UInt16) {
        request += 1
        epoch += 1
        wantRev = rev
        still?.cancel()
        if !busy, stream != nil, !changesCapture() {
            goLive()
            return
        }
        sink?.pause()
        reconcileSoon()
    }

    /// Whether the stream running now would have to be retuned or replaced to capture what the target and the zoom say.
    private func changesCapture() -> Bool {
        guard let want, stream != nil else { return true }
        let (identity, key) = Self.describe(targets: targets, outline: outline, want: want)
        return identity != runningIdentity || key != applied
    }

    /// The configuration for the epoch in force is applied: its samples go out under `wantRev`. A picture of the same window and
    /// crop (`lastGood` survives only while they are unchanged) is sent again under the new tag at once; a new one waits for its
    /// first sample, or a still capture.
    private func goLive() {
        guard let sink else { return }
        liveRev = wantRev
        sink.resume(tag: epoch, notBefore: appliedAt)
        if deliveredEpoch != epoch, !sink.flow.hasPending, let data = lastGood, sink.flow.reserve() { send(data, tag: epoch) }
        armStill()
    }

    /// If this epoch has had no frame a moment after its configuration was applied (a window that has stopped changing gives
    /// ScreenCaptureKit nothing to send), one still capture with the same window and crop takes its place.
    private func armStill() {
        still?.cancel()
        let mine = epoch, gen = generation
        still = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.stillAfter))
            guard !Task.isCancelled, let self, mine == epoch, gen == generation, deliveredEpoch != mine else { return }
            await captureStill(epoch: mine, generation: gen)
        }
    }

    private func captureStill(epoch mine: Int, generation gen: Int) async {
        guard let filter = runningFilter, let config = runningConfig else { return }
        do {
            let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
            guard mine == epoch, gen == generation, deliveredEpoch != mine, let sink, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            log.notice("projection: no sample for epoch \(mine) after \(Self.stillAfter) ms; one still capture")
            sink.inject(pixels, tag: mine)
        } catch {
            log.error("projection: still capture failed: \(error.localizedDescription, privacy: .public)")
        }
    }

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
        config.ignoreGlobalClipSingleWindow = true  // a window half past the screen's edge is captured whole, as the ink spans all of it
        return (config, "\(width)x\(height) \(Int(source.minX.rounded())),\(Int(source.minY.rounded())) \(Int(source.width.rounded()))x\(Int(source.height.rounded()))")
    }

    /// What the target and the zoom ask the stream to capture: the window or screen (by identity), and the configuration key.
    private static func describe(targets: Targets, outline: RegionOutline, want: (w: Int, h: Int)) -> (identity: String, key: String) {
        let target = targets.current, region = outline.region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let identity = target.id == "window" ? "window #\(targets.windowSerial) pid \(targets.windowPID ?? 0) id \(targets.windowID ?? 0)" : "display \(target.id)"
        return (identity, configuration(base: target.rect.size, region: region, want: want).1)
    }

    /// Applies the newest request. Every wait below (the lookup, the stop, the start, a retune) can be overtaken: the request
    /// is looked at again after each, and an overtaken one installs and starts nothing, so only the newest is ever served.
    private func reconcileOnce() async {
        guard let want else { await stopStream(); return }
        let mine = request
        let target = targets.current, region = outline.region ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let pid = targets.windowPID, windowID = targets.windowID
        let identity = target.id == "window" ? "window #\(targets.windowSerial) pid \(targets.windowPID ?? 0) id \(targets.windowID ?? 0)" : "display \(target.id)"
        do {
            let (config, key) = Self.configuration(base: target.rect.size, region: region, want: want)
            // The same window or screen, only its size or the zoomed region changed: retune the stream, look nothing up.
            if let stream, identity == runningIdentity {
                guard key != applied else { goLive(); return }
                sink?.pause()
                lastGood = nil  // pictures of the old crop are no use under the new one
                try await stream.updateConfiguration(config)
                applied = key
                appliedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
                runningConfig = config
                configurations += 1
                log.notice("projection: reconfigured \(identity, privacy: .public) \(key, privacy: .public) (#\(self.configurations))")
                guard mine == request else { return }  // a newer request is waiting; the sink stays closed until it is applied
                goLive()
                return
            }
            log.notice("projection: looking up capturable windows and screens")
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: target.id != "window")
            guard mine == request else { return }  // a newer show or choice came in while this looked: its answer is the one that counts
            let filter: SCContentFilter
            if target.id == "window" {
                guard let pid, let window = Self.match(content.windows, id: windowID, pid: pid, rect: target.rect) else {
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
            guard mine == request else { return }  // the stop was a suspension too: a newer choice may have come in during it
            try await startStream(filter: filter, config: config, identity: identity, key: key, what: target.name)
            if mine == request { armStill() }
        } catch {
            guard mine == request else { return }
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
            onFrame: { [weak self] data, tag in DispatchQueue.main.async { MainActor.assumeIsolated { self?.deliver(data, tag: tag, from: mine) } } },
            onStopped: { [weak self] why in DispatchQueue.main.async { MainActor.assumeIsolated { self?.streamStopped(why, from: mine) } } })
        let stream = SCStream(filter: filter, configuration: config, delegate: sink)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
        announced = false
        // Set before starting: the first samples can reach the main queue before startCapture returns, and they are already
        // of this window and crop, so they are tagged with the epoch that asked for it.
        self.sink = sink
        self.stream = stream
        runningIdentity = identity
        applied = key
        runningFilter = filter
        runningConfig = config
        lastGood = nil
        appliedAt = nil
        liveRev = wantRev
        sink.resume(tag: epoch, notBefore: nil)
        do { try await stream.startCapture() } catch {
            sink.close()
            self.sink = nil
            self.stream = nil
            runningIdentity = ""
            applied = ""
            runningFilter = nil
            runningConfig = nil
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
        still?.cancel()
        runningIdentity = ""
        applied = ""
        appliedAt = nil
        lastGood = nil
    }

    private func stopStream() async {
        guard let stream else { return }
        retireStream()
        self.stream = nil
        self.sink = nil
        runningFilter = nil
        runningConfig = nil
        do { try await stream.stopCapture() } catch { log.error("projection: stopCapture: \(error.localizedDescription, privacy: .public)") }
        log.notice("projection: SCStream stopped")
    }

    /// A frame is encoded: number it and send it. The first one also tells the page the stream is up.
    private func deliver(_ data: Data, tag: Int, from mine: Int) {
        guard mine == generation, let sink else { return }
        guard tag == sink.liveTag, let owner, stream != nil else { sink.abandoned(); return }  // of a configuration since replaced
        if !announced { announced = true; reply(owner, true, nil) }
        send(data, tag: tag)
        lastGood = data
    }

    /// Numbers a picture and sends it to the owner, with the 6-byte header (number, then the page's `rev` for this epoch) a
    /// v2 page expects, or main's 4-byte one. It holds a slot of the sink's two in flight until the page acknowledges it.
    private func send(_ data: Data, tag: Int) {
        guard let owner, let sink else { return }
        deliveredEpoch = tag
        let n = nextFrame
        nextFrame &+= 1
        sink.sent(n)
        var frame = Data(capacity: data.count + 6)
        frame.append(contentsOf: [UInt8(n >> 24 & 0xff), UInt8(n >> 16 & 0xff), UInt8(n >> 8 & 0xff), UInt8(n & 0xff)])
        if tagged { frame.append(contentsOf: [UInt8(liveRev >> 8), UInt8(liveRev & 0xff)]) }
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
        runningFilter = nil
        runningConfig = nil
        restarts += 1
        if restarts <= 2, want != nil { reconcileSoon(delay: 300) } else { fail("The picture stopped: \(String(why.prefix(60)))") }
    }

    /// Stops, remembers nothing, and tells the page why.
    private func fail(_ why: String) {
        want = nil
        request += 1
        if let owner { reply(owner, false, why) }
        owner = nil
        retireStream()
        reconcileSoon(delay: 0)
    }

    /// The SCWindow that is the target: the one with the window server's number the pick recorded, else (when that number
    /// could not be read) the same app's window nearest the frame the Accessibility API reported.
    private static func match(_ windows: [SCWindow], id: CGWindowID?, pid: pid_t, rect: CGRect) -> SCWindow? {
        if let id { return windows.first { $0.windowID == id && $0.owningApplication?.processID == pid } }
        func gap(_ w: SCWindow) -> CGFloat {
            abs(w.frame.minX - rect.minX) + abs(w.frame.minY - rect.minY) + abs(w.frame.width - rect.width) + abs(w.frame.height - rect.height)
        }
        return windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            .min { gap($0) < gap($1) }
            .flatMap { gap($0) < 12 ? $0 : nil }
    }
}
