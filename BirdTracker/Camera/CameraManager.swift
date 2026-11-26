import AVFoundation
import CoreMedia
import simd

/// Owns the AVCaptureSession and delivers raw frames (landscape sensor orientation)
/// together with a timestamp and the focal length in pixels.
///
/// Zoom: 1× and 2× use the main camera (2× is a sensor crop); the telephoto step switches to the
/// telephoto lens (5× on Pro iPhones). The focal length passed on always matches the lens and zoom,
/// so distance, speed and the lead stay correct at every zoom.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationDenied = false
    /// Zoom steps this phone offers (e.g. [1, 2, 5]) and the one in use.
    @Published private(set) var zoomOptions: [Double] = [1, 2]
    @Published private(set) var zoom: Double = 1
    /// Changes whenever the lens is switched (the preview re-applies its rotation).
    @Published private(set) var configurationID = 0

    /// (pixelBuffer, timestamp in seconds, focal length in pixels for that buffer)
    var onFrame: ((CVPixelBuffer, Double, Double) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "bird.camera.session")
    private let videoQueue = DispatchQueue(label: "bird.camera.video", qos: .userInitiated)
    private var configured = false
    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var wide: AVCaptureDevice?
    private var tele: AVCaptureDevice?
    private var teleFactor: Double?
    private var thermalObserver: NSObjectProtocol?

    // Read on the video queue.
    private let lensLock = NSLock()
    private var lensFOVDegrees: Double = 65          // horizontal FOV of the active lens at zoom 1
    private var digitalZoom: Double = 1

    override init() {
        super.init()
        // Drop back to 30 fps when the phone gets hot.
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.sessionQueue.async { self?.applyFrameRate() }
        }
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted { self.configureAndRun() }
                else { DispatchQueue.main.async { self.authorizationDenied = true } }
            }
        default:
            DispatchQueue.main.async { self.authorizationDenied = true }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    /// Switch zoom (one of `zoomOptions`); remembered for the next launch.
    func setZoom(_ level: Double) {
        UserDefaults.standard.set(level, forKey: AppSettings.cameraZoomKey)
        sessionQueue.async {
            guard self.configured else { return }
            self.applyZoom(level)
        }
    }

    private func configureAndRun() {
        sessionQueue.async {
            if !self.configured {
                self.configure()
                self.configured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            self.applyFrameRate()            // picks up a changed setting
        }
    }

    // MARK: - Configuration

    private func configure() {
        wide = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        tele = AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
        guard let wide else { return }

        if let tele {
            let wideFOV = Double((Self.highFrameRateFormat(for: wide) ?? wide.activeFormat).videoFieldOfView)
            let teleFOV = Double((Self.highFrameRateFormat(for: tele) ?? tele.activeFormat).videoFieldOfView)
            let factor = tan(wideFOV * .pi / 360) / tan(teleFOV * .pi / 360)
            if factor.isFinite, factor > 2.5 { teleFactor = (factor * 2).rounded() / 2 }   // e.g. 5×
        }
        let options = [1.0, 2.0] + (teleFactor.map { [$0] } ?? [3.0])
        DispatchQueue.main.async { self.zoomOptions = options }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true   // drop frames while the model is busy
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)

        let saved = UserDefaults.standard.double(forKey: AppSettings.cameraZoomKey)
        let start = options.min { abs($0 - saved) < abs($1 - saved) } ?? 1
        applyZoom(start)
    }

    /// Puts the right lens in the session and sets its zoom.
    private func applyZoom(_ level: Double) {
        let useTele = teleFactor.map { level >= $0 - 0.01 } ?? false
        guard let lens = useTele ? tele : wide else { return }
        let digital = useTele ? max(1, level / (teleFactor ?? level)) : level

        if lens != device {
            session.beginConfiguration()
            session.sessionPreset = .hd1920x1080
            if let input { session.removeInput(input) }
            guard let newInput = try? AVCaptureDeviceInput(device: lens), session.canAddInput(newInput) else {
                if let input { session.addInput(input) }
                session.commitConfiguration()
                return
            }
            session.addInput(newInput)
            input = newInput
            device = lens
            if !session.outputs.contains(videoOutput), session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }
            if let format = Self.highFrameRateFormat(for: lens), (try? lens.lockForConfiguration()) != nil {
                lens.activeFormat = format
                lens.unlockForConfiguration()
            }
            if (try? lens.lockForConfiguration()) != nil {
                if lens.isFocusModeSupported(.continuousAutoFocus) { lens.focusMode = .continuousAutoFocus }
                if lens.isExposureModeSupported(.continuousAutoExposure) { lens.exposureMode = .continuousAutoExposure }
                lens.unlockForConfiguration()
            }
            if let connection = videoOutput.connection(with: .video) {
                if connection.isCameraIntrinsicMatrixDeliverySupported {
                    connection.isCameraIntrinsicMatrixDeliveryEnabled = true
                }
                // Stabilisation crops/warps the frame and would break the pinhole geometry.
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
            session.commitConfiguration()
            applyFrameRate()
        }

        let clamped = min(max(1, digital), lens.activeFormat.videoMaxZoomFactor)
        if (try? lens.lockForConfiguration()) != nil {
            lens.videoZoomFactor = clamped
            lens.unlockForConfiguration()
        }

        lensLock.lock()
        lensFOVDegrees = Double(lens.activeFormat.videoFieldOfView)
        digitalZoom = clamped
        lensLock.unlock()

        DispatchQueue.main.async {
            self.zoom = level
            self.configurationID += 1
        }
    }

    /// Up to 60 fps when enabled and the phone is not hot. The detector skips frames it cannot keep up
    /// with, so the app always processes as many as the phone can. In poor light the camera may slow
    /// down to 30 fps to keep exposures long enough.
    private func applyFrameRate() {
        guard let device else { return }
        let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let want = UserDefaults.standard.bool(forKey: AppSettings.highFrameRateKey) && !hot ? 60.0 : 30.0
        let maxRate = device.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        let rate = min(want, maxRate)
        guard (try? device.lockForConfiguration()) != nil else { return }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(rate.rounded()))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
        device.unlockForConfiguration()
    }

    /// 1920×1080 8-bit format that can run at 60 fps; the widest field of view (full sensor width) wins.
    private static func highFrameRateFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let subtypes: Set<FourCharCode> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        return device.formats
            .filter { format in
                let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                return d.width == 1920 && d.height == 1080
                    && subtypes.contains(CMFormatDescriptionGetMediaSubType(format.formatDescription))
                    && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 59.9 }
            }
            .max { $0.videoFieldOfView < $1.videoFieldOfView }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        lensLock.lock()
        let fov = lensFOVDegrees
        let zoom = digitalZoom
        lensLock.unlock()

        // Expected focal length from the lens's field of view and the zoom.
        let width = Double(CVPixelBufferGetWidth(pixelBuffer))
        let expected = (width / 2) / tan(fov * .pi / 360) * zoom
        var focalPx = expected

        // Prefer the calibrated per-frame intrinsics, whether or not they already include the zoom.
        if let data = CMGetAttachment(sampleBuffer,
                                      key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            let k = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            let fx = Double(k.columns.0.x)            // fx, in pixels of this buffer
            if abs(fx / expected - 1) < 0.15 {
                focalPx = fx
            } else if abs(fx * zoom / expected - 1) < 0.15 {
                focalPx = fx * zoom
            }
        }
        if !focalPx.isFinite || focalPx <= 0 { focalPx = 1500 }

        onFrame?(pixelBuffer, time, focalPx)
    }
}
