import AVFoundation
import CoreMedia
import simd

/// Owns the AVCaptureSession and delivers raw frames (landscape sensor orientation)
/// together with a timestamp and the focal length in pixels.
final class CameraManager: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var authorizationDenied = false

    /// (pixelBuffer, timestamp in seconds, focal length in pixels for that buffer)
    var onFrame: ((CVPixelBuffer, Double, Double) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "bird.camera.session")
    private let videoQueue = DispatchQueue(label: "bird.camera.video", qos: .userInitiated)
    private var configured = false
    private var horizontalFOVDegrees: Double = 65
    private var device: AVCaptureDevice?
    private var thermalObserver: NSObjectProtocol?

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

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)
        self.device = device

        if let format = Self.highFrameRateFormat(for: device), (try? device.lockForConfiguration()) != nil {
            device.activeFormat = format
            device.unlockForConfiguration()
        }

        // Fallback focal length if per-frame intrinsics are not delivered.
        horizontalFOVDegrees = Double(device.activeFormat.videoFieldOfView)

        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            // Keep zoom at 1x: the distance maths relies on a known focal length.
            device.videoZoomFactor = 1.0
            device.unlockForConfiguration()
        }

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true   // drop frames while the model is busy
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { return }
        session.addOutput(videoOutput)

        if let connection = videoOutput.connection(with: .video) {
            if connection.isCameraIntrinsicMatrixDeliverySupported {
                connection.isCameraIntrinsicMatrixDeliveryEnabled = true
            }
            // Stabilisation crops/warps the frame and would break the pinhole geometry.
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

        var focalPx: Double
        if let data = CMGetAttachment(sampleBuffer,
                                      key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
                                      attachmentModeOut: nil) as? Data,
           data.count >= MemoryLayout<matrix_float3x3>.size {
            let k = data.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
            focalPx = Double(k.columns.0.x)            // fx, in pixels of this buffer
        } else {
            let width = Double(CVPixelBufferGetWidth(pixelBuffer))
            focalPx = (width / 2) / tan(horizontalFOVDegrees * .pi / 360)
        }
        if !focalPx.isFinite || focalPx <= 0 { focalPx = 1500 }

        onFrame?(pixelBuffer, time, focalPx)
    }
}
