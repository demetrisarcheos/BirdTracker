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
    @Published private(set) var speciesAvailable = true

    let camera = CameraManager()
    private let motion = MotionProvider()
    private let tracker = MultiBirdTracker()
    private var cancellables = Set<AnyCancellable>()

    // Video-queue state
    private var detector: BirdDetector?
    private var detectorFailed = false
    private var speciesClassifier: SpeciesClassifier?
    private var speciesLoadAttempted = false
    private var lastFrameTime: Double?
    private var fpsAverage: Double = 0
    private let loadoutLock = NSLock()
    private var currentLoadout = Loadout.default

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

    /// Gun + cartridge + next barrel used for the aiming maths (set from the main thread).
    func setLoadout(_ loadout: Loadout) {
        loadoutLock.lock()
        currentLoadout = loadout
        loadoutLock.unlock()
    }

    /// Pauses only the camera (e.g. while Settings may use it to scan a cartridge box).
    func pauseCamera() { camera.stop() }

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
        if !speciesLoadAttempted {
            speciesLoadAttempted = true
            speciesClassifier = SpeciesClassifier()
            let available = speciesClassifier != nil
            DispatchQueue.main.async { self.speciesAvailable = available }
        }

        let defaults = UserDefaults.standard
        detector.confidenceThreshold = Float(defaults.double(forKey: AppSettings.confidenceKey))
        let birdSize = max(0.05, defaults.double(forKey: AppSettings.birdSizeKey))
        let identifySpecies = defaults.bool(forKey: AppSettings.identifySpeciesKey)

        loadoutLock.lock()
        let loadout = currentLoadout
        loadoutLock.unlock()

        let detections = detector.detect(in: buffer)

        // Buffers are landscape; the app works in portrait, so width/height swap.
        let size = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer))
        let geometry = CameraGeometry(imageSize: size, focalPx: focalPx,
                                      deviceToWorld: motion.deviceToWorld ?? matrix_identity_double3x3)
        let results = tracker.update(detections: detections, time: time, geometry: geometry,
                                     presetSizeMeters: birdSize, useSpeciesSize: identifySpecies,
                                     loadout: loadout)

        // Species: classify at most three birds per frame, each about five times a second.
        if identifySpecies, let classifier = speciesClassifier {
            for candidate in tracker.classificationCandidates(time: time, imageSize: size, limit: 3) {
                let guesses = classifier.classify(buffer, rect: candidate.rect, imageSize: size)
                tracker.addSpeciesGuesses(guesses, toTrack: candidate.id, time: time)
            }
        }

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
