import AVFoundation
import Combine
import CoreGraphics
import simd

/// Glues camera → YOLO26 → tracker together and publishes results to SwiftUI.
/// All heavy work happens on the camera's video queue; only results hop to the main thread.
final class BirdTrackingEngine: ObservableObject {
    @Published private(set) var readouts: [BirdReadout] = []
    @Published private(set) var imageSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var fps: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var compassAvailable = false
    @Published private(set) var cameraDenied = false

    let camera = CameraManager()
    private let motion = MotionProvider()
    private let tracker = MultiBirdTracker()
    private var cancellables = Set<AnyCancellable>()

    // Video-queue state
    private var detector: BirdDetector?
    private var detectorFailed = false
    private var lastFrameTime: Double?
    private var fpsAverage: Double = 0

    init() {
        camera.onFrame = { [weak self] buffer, time, focal in
            self?.process(buffer, time: time, focalPx: focal)
        }
        camera.$authorizationDenied
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.cameraDenied = $0 }
            .store(in: &cancellables)
    }

    func start() {
        motion.start()
        compassAvailable = motion.hasCompass
        camera.start()
    }

    func stop() {
        camera.stop()
        motion.stop()
    }

    private func process(_ buffer: CVPixelBuffer, time: Double, focalPx: Double) {
        if detector == nil && !detectorFailed {
            do {
                detector = try BirdDetector(preferredModelName: AppSettings.modelName)
            } catch {
                detectorFailed = true
                let message = error.localizedDescription
                DispatchQueue.main.async { self.errorMessage = message }
            }
        }
        guard let detector else { return }

        let defaults = UserDefaults.standard
        detector.confidenceThreshold = Float(defaults.double(forKey: AppSettings.confidenceKey))
        let birdSize = max(0.05, defaults.double(forKey: AppSettings.birdSizeKey))

        let detections = detector.detect(in: buffer)

        // Buffers are landscape; the app works in portrait, so width/height swap.
        let size = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer))
        let geometry = CameraGeometry(imageSize: size, focalPx: focalPx,
                                      deviceToWorld: motion.deviceToWorld ?? matrix_identity_double3x3)
        let results = tracker.update(detections: detections, time: time,
                                     geometry: geometry, birdSizeMeters: birdSize)

        if let last = lastFrameTime, time > last {
            let instant = 1 / (time - last)
            fpsAverage = fpsAverage == 0 ? instant : fpsAverage * 0.9 + instant * 0.1
        }
        lastFrameTime = time
        let fps = fpsAverage

        DispatchQueue.main.async {
            self.readouts = results
            self.imageSize = size
            self.fps = fps
        }
    }
}
