import AVFoundation
import Combine
import CoreImage
import CoreMedia
import Darwin
import QuartzCore
import UIKit
import VideoToolbox

/// Live video from a GoPro over the GoPro's own Wi-Fi network (Open GoPro API).
///
/// The phone joins the GoPro's Wi-Fi. The app asks the camera (HTTP, 10.5.5.9:8080) to start its
/// preview stream, which arrives as H.264 inside MPEG-TS over UDP port 8554 and is decoded with
/// VideoToolbox into BGRA frames for the detector.
final class GoProCamera: ObservableObject {
    enum Status: Equatable {
        case off, searching, waitingForVideo, streaming

        var text: String {
            switch self {
            case .off:             return "Off"
            case .searching:       return "Looking for the GoPro – is the phone on its Wi-Fi?"
            case .waitingForVideo: return "GoPro found, starting video…"
            case .streaming:       return "Receiving video"
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var fps: Double = 0
    @Published private(set) var resolution: CGSize = .zero

    /// Decoded frame and the host time (CACurrentMediaTime) it arrived.
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// Mean brightness (0…1) of the centre of each frame, with its arrival time (for the delay test).
    var onBrightness: ((Double, Double) -> Void)?

    private let host = "10.5.5.9:8080"
    private let streamPort: UInt16 = 8554
    private let http: URLSession
    private let controlQueue = DispatchQueue(label: "gopro.control")
    private let lock = NSLock()
    private var generation = 0
    private var running = false
    private var timer: DispatchSourceTimer?
    private var lastPacket: Double = 0
    private var lastHTTPOK: Double = 0
    private var configured = false
    private var restarting = false
    private var frameCount = 0
    private var rateStart: Double = 0
    private var _latest: CVPixelBuffer?
    private let displays = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()

    private let demuxer = TSDemuxer()
    private let decoder = H264Decoder()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 2
        config.waitsForConnectivity = false
        http = URLSession(configuration: config)
        demuxer.onAccessUnit = { [weak self] unit in self?.decoder.decode(unit) }
        decoder.onFrame = { [weak self] buffer in self?.handleFrame(buffer) }
    }

    /// Most recent decoded frame (for calibration pictures).
    var latestFrame: CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    func addDisplay(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock(); displays.add(layer); lock.unlock()
    }

    func start() {
        lock.lock()
        if running { lock.unlock(); return }
        running = true
        generation += 1
        let gen = generation
        lock.unlock()

        openSocket(generation: gen)
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now(), repeating: 2.0)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        publish(.searching)
    }

    func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        generation += 1          // the receive thread notices and closes its socket
        lock.unlock()
        timer?.cancel()
        timer = nil
        get("/gopro/camera/stream/stop")
        controlQueue.async { self.configured = false }
        decoder.reset()
        publish(.off)
    }

    // MARK: - Camera control (HTTP)

    private func get(_ path: String, completion: ((Bool) -> Void)? = nil) {
        guard let url = URL(string: "http://\(host)\(path)") else { return }
        http.dataTask(with: URLRequest(url: url, timeoutInterval: 2)) { _, response, _ in
            completion?((response as? HTTPURLResponse)?.statusCode == 200)
        }.resume()
    }

    private func tick() {
        get("/gopro/camera/keep_alive") { [weak self] ok in
            self?.controlQueue.async { self?.afterKeepAlive(ok) }
        }
    }

    private func afterKeepAlive(_ ok: Bool) {
        let now = CACurrentMediaTime()
        if ok { lastHTTPOK = now }
        lock.lock()
        let packetAge = now - lastPacket
        let isRunning = running
        lock.unlock()
        guard isRunning else { return }

        if packetAge > 2.5, ok, !restarting {
            if !configured {
                configured = true
                // Linear lens (straight lines, no fisheye) and no stabilisation crop/warp.
                get("/gopro/camera/presets/set_group?id=1000")
                get("/gopro/camera/setting?setting=121&option=4")
                get("/gopro/camera/setting?setting=135&option=0")
            }
            restarting = true
            get("/gopro/camera/stream/stop") { [weak self] _ in
                self?.get("/gopro/camera/stream/start?port=8554") { _ in
                    self?.controlQueue.async { self?.restarting = false }
                }
            }
        }

        let status: Status = packetAge < 1.5 ? .streaming : (now - lastHTTPOK < 5 ? .waitingForVideo : .searching)
        publish(status)
    }

    private func publish(_ status: Status) {
        DispatchQueue.main.async { if self.status != status { self.status = status } }
    }

    // MARK: - UDP receive

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return running && generation == gen
    }

    private func openSocket(generation gen: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, Int32(IPPROTO_UDP))
        guard fd >= 0 else { return }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var bufferSize: Int32 = 4 * 1024 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = __uint8_t(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(streamPort).bigEndian
        addr.sin_addr = in_addr(s_addr: 0)          // any interface
        let bound = withUnsafePointer(to: addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { Darwin.close(fd); return }

        let thread = Thread { [weak self] in self?.receiveLoop(fd, generation: gen) }
        thread.qualityOfService = .userInteractive
        thread.name = "gopro.udp"
        thread.start()
    }

    private func receiveLoop(_ fd: Int32, generation gen: Int) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while isCurrent(gen) {
            let n = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            guard n > 0 else { continue }
            lock.lock(); lastPacket = CACurrentMediaTime(); lock.unlock()
            buffer.withUnsafeBufferPointer { demuxer.feed($0.baseAddress!, count: n) }
        }
        Darwin.close(fd)
    }

    // MARK: - Frames

    private func handleFrame(_ buffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        _latest = buffer
        let layers = displays.allObjects
        lock.unlock()

        onFrame?(buffer, now)
        if let onBrightness { onBrightness(now, Self.brightness(of: buffer)) }

        frameCount += 1
        if now - rateStart >= 1 {
            let fps = Double(frameCount) / (now - rateStart)
            let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
            frameCount = 0
            rateStart = now
            DispatchQueue.main.async {
                self.fps = fps
                if self.resolution != size { self.resolution = size }
            }
        }

        if !layers.isEmpty, let sample = Self.displaySample(buffer) {
            DispatchQueue.main.async {
                for layer in layers {
                    if layer.status == .failed { layer.flush() }
                    layer.enqueue(sample)
                }
            }
        }
    }

    private static func displaySample(_ buffer: CVPixelBuffer) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                           formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(),
                                                                      preferredTimescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Mean brightness of the central half of a BGRA frame.
    static func brightness(of buffer: CVPixelBuffer) -> Double {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else { return 0 }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let row = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for gy in 0..<16 {
            let y = h / 4 + gy * (h / 2) / 16
            for gx in 0..<16 {
                let o = y * row + (w / 4 + gx * (w / 2) / 16) * 4
                sum += 0.114 * Double(p[o]) + 0.587 * Double(p[o + 1]) + 0.299 * Double(p[o + 2])
            }
        }
        return sum / 256 / 255
    }

    /// Upright still picture of the latest frame.
    func snapshot(upsideDown: Bool) -> UIImage? {
        guard let buffer = latestFrame else { return nil }
        var image = CIImage(cvPixelBuffer: buffer)
        if upsideDown { image = image.oriented(.down) }
        guard let cg = CIContext().createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - MPEG-TS

/// Minimal MPEG transport-stream demuxer: finds the H.264 stream and hands out one PES
/// payload (one access unit) at a time.
final class TSDemuxer {
    var onAccessUnit: (([UInt8]) -> Void)?

    private var pmtPID: Int?
    private var videoPID: Int?
    private var pes: [UInt8] = []
    private var pesStarted = false

    func feed(_ p: UnsafePointer<UInt8>, count: Int) {
        var i = 0
        while i + 188 <= count {
            if p[i] == 0x47 {
                packet(p + i)
                i += 188
            } else {
                i += 1                  // resync
            }
        }
    }

    private func packet(_ p: UnsafePointer<UInt8>) {
        let unitStart = p[1] & 0x40 != 0
        let pid = (Int(p[1] & 0x1F) << 8) | Int(p[2])
        let adaptation = (p[3] >> 4) & 0x3
        var offset = 4
        if adaptation == 0 || adaptation == 2 { return }         // no payload
        if adaptation == 3 { offset += 1 + Int(p[4]) }
        guard offset < 188 else { return }
        let payload = UnsafeBufferPointer(start: p + offset, count: 188 - offset)

        if pid == 0 {
            if unitStart { parsePAT(payload) }
        } else if pid == pmtPID {
            if unitStart { parsePMT(payload) }
        } else if pid == videoPID {
            if unitStart {
                flush()
                pes.removeAll(keepingCapacity: true)
                pes.append(contentsOf: payload)
                pesStarted = true
            } else if pesStarted {
                pes.append(contentsOf: payload)
            }
            // When the PES length is given, hand the frame over as soon as it is complete.
            if pesStarted, pes.count >= 6 {
                let declared = (Int(pes[4]) << 8) | Int(pes[5])
                if declared > 0, pes.count >= 6 + declared {
                    flush()
                    pesStarted = false
                }
            }
        }
    }

    private func section(_ payload: UnsafeBufferPointer<UInt8>) -> ArraySlice<UInt8>? {
        guard let pointer = payload.first else { return nil }
        let start = 1 + Int(pointer)
        guard start < payload.count else { return nil }
        return Array(payload)[start...]
    }

    private func parsePAT(_ payload: UnsafeBufferPointer<UInt8>) {
        guard let s = section(payload).map(Array.init), s.count >= 12, s[0] == 0x00 else { return }
        let length = (Int(s[1] & 0x0F) << 8) | Int(s[2])
        let end = min(s.count, 3 + length - 4)
        var i = 8
        while i + 4 <= end {
            let program = (Int(s[i]) << 8) | Int(s[i + 1])
            let pid = (Int(s[i + 2] & 0x1F) << 8) | Int(s[i + 3])
            if program != 0 { pmtPID = pid; return }
            i += 4
        }
    }

    private func parsePMT(_ payload: UnsafeBufferPointer<UInt8>) {
        guard let s = section(payload).map(Array.init), s.count >= 16, s[0] == 0x02 else { return }
        let length = (Int(s[1] & 0x0F) << 8) | Int(s[2])
        let end = min(s.count, 3 + length - 4)
        let infoLength = (Int(s[10] & 0x0F) << 8) | Int(s[11])
        var i = 12 + infoLength
        while i + 5 <= end {
            let type = s[i]
            let pid = (Int(s[i + 1] & 0x1F) << 8) | Int(s[i + 2])
            let esInfo = (Int(s[i + 3] & 0x0F) << 8) | Int(s[i + 4])
            if type == 0x1B { videoPID = pid; return }           // H.264
            i += 5 + esInfo
        }
    }

    private func flush() {
        guard pesStarted, pes.count > 9, pes[0] == 0, pes[1] == 0, pes[2] == 1 else { return }
        let start = 9 + Int(pes[8])
        guard start < pes.count else { return }
        onAccessUnit?(Array(pes[start...]))
    }
}

// MARK: - H.264

/// Annex-B H.264 → VideoToolbox → BGRA pixel buffers.
final class H264Decoder {
    var onFrame: ((CVPixelBuffer) -> Void)?

    private let lock = NSLock()
    private var sps: [UInt8]?
    private var pps: [UInt8]?
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?

    func reset() {
        lock.lock(); defer { lock.unlock() }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        sps = nil
        pps = nil
    }

    func decode(_ data: [UInt8]) {
        lock.lock(); defer { lock.unlock() }
        var sample: [UInt8] = []
        var hasPicture = false
        var newParameters = false
        for nal in Self.nalUnits(data) {
            guard let first = nal.first else { continue }
            let type = first & 0x1F
            switch type {
            case 7:
                let value = Array(nal)
                if value != sps { sps = value; newParameters = true }
            case 8:
                let value = Array(nal)
                if value != pps { pps = value; newParameters = true }
            case 9:
                continue                                   // access-unit delimiter
            default:
                if type == 1 || type == 5 { hasPicture = true }
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
                sample.append(contentsOf: nal)
            }
        }
        if newParameters || session == nil { makeSession() }
        guard hasPicture, let session, let format else { return }

        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: sample.count, blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil, offsetToData: 0,
                                                 dataLength: sample.count, flags: 0,
                                                 blockBufferOut: &block) == kCMBlockBufferNoErr,
              let block else { return }
        let copied = sample.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: sample.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var sampleBuffer: CMSampleBuffer?
        var sizes = [sample.count]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                        formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return }

        let onFrame = self.onFrame
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sampleBuffer, flags: [],
                                                       infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
            if status == noErr, let imageBuffer { onFrame?(imageBuffer) }
        }
        if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr {
            VTDecompressionSessionInvalidate(session)
            self.session = nil                  // rebuilt on the next frame (e.g. after the app was in the background)
        }
    }

    private func makeSession() {
        guard let sps, let pps else { return }
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil

        var newFormat: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBufferPointer { s in
            pps.withUnsafeBufferPointer { p in
                let pointers: [UnsafePointer<UInt8>] = [s.baseAddress!, p.baseAddress!]
                let sizes: [Int] = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else { return }

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var newSession: VTDecompressionSession?
        let created = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: newFormat,
                                                   decoderSpecification: nil,
                                                   imageBufferAttributes: attributes as CFDictionary,
                                                   outputCallback: nil, decompressionSessionOut: &newSession)
        guard created == noErr, let newSession else { return }
        VTSessionSetProperty(newSession, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = newSession
        format = newFormat
    }

    /// Splits an Annex-B byte stream at its 00 00 01 start codes.
    static func nalUnits(_ d: [UInt8]) -> [ArraySlice<UInt8>] {
        var units: [ArraySlice<UInt8>] = []
        var i = 0
        var start = -1
        let n = d.count
        while i + 2 < n {
            if d[i] == 0, d[i + 1] == 0, d[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    while end > start, d[end - 1] == 0 { end -= 1 }
                    if end > start { units.append(d[start..<end]) }
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if start >= 0, start < n { units.append(d[start..<n]) }
        return units
    }
}
