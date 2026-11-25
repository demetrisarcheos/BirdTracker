import AVFoundation
import Combine
import CoreGraphics
import QuartzCore
import simd

/// Glues camera → YOLO26 → tracker together and publishes results to SwiftUI.
///
/// Two video sources:
///  • the phone camera, oriented by the phone's own motion sensors;
///  • a GoPro on the gun, oriented by a Bluetooth motion sensor on the gun (phone in a pocket).
/// Heavy work happens on background queues; only results hop to the main thread.
final class BirdTrackingEngine: ObservableObject {
    @Published private(set) var readouts: [BirdReadout] = []
    @Published private(set) var imageSize = CGSize(width: 1080, height: 1920)
    @Published private(set) var fps: Double = 0
    /// Average time the phone needs to analyse one frame (detector + species), milliseconds.
    @Published private(set) var processingMs: Double = 0
    @Published private(set) var errorMessage: String?
    @Published private(set) var compassAvailable = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var speciesAvailable = true
    @Published private(set) var source: CameraSource = .phone
    /// Where the barrel points in the image (normalised). Centre for the phone camera.
    @Published private(set) var boresight = CGPoint(x: 0.5, y: 0.5)

    let camera = CameraManager()
    let gopro = GoProCamera()
    let goproBluetooth = GoProBluetooth()
    let gunSensor = GunSensor()
    /// A real shot (recoil felt by the gun sensor): the birds as they were at that instant.
    let realShot = PassthroughSubject<[BirdReadout], Never>()

    private let motion = MotionProvider()
    private let tracker = MultiBirdTracker()
    private var cancellables = Set<AnyCancellable>()

    // Processing state (guarded by processingLock: the two sources run on different queues)
    private let processingLock = NSLock()
    private var detector: BirdDetector?
    private var detectorFailed = false
    private var speciesClassifier: SpeciesClassifier?
    private var speciesLoadAttempted = false
    private var lastFrameTime: Double?
    private var fpsAverage: Double = 0
    private var processingAverage: Double = 0
    private let loadoutLock = NSLock()
    private var currentLoadout = Loadout.default

    // Gun camera
    private let gunQueue = DispatchQueue(label: "bird.gun.video", qos: .userInitiated)
    private let busyLock = NSLock()
    private var gunBusy = false
    private struct GunContext {
        let captureTime: Double
        let geometry: CameraGeometry
        let birdSize: Double
        let loadout: Loadout
    }
    private var lastGunContext: GunContext?         // gunQueue only

    init() {
        camera.onFrame = { [weak self] buffer, time, focal in
            self?.processPhoneFrame(buffer, time: time, focalPx: focal)
        }
        gopro.onFrame = { [weak self] buffer, arrival in
            self?.enqueueGunFrame(buffer, arrival: arrival)
        }
        gunSensor.onRecoil = { [weak self] time in
            self?.handleRecoil(at: time)
        }
        camera.$authorizationDenied
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.cameraDenied = $0 }
            .store(in: &cancellables)
    }

    /// Starts the source chosen in Settings (and stops the other one).
    func start() {
        let defaults = UserDefaults.standard
        let chosen = CameraSource(rawValue: defaults.string(forKey: AppSettings.cameraSourceKey) ?? "") ?? .phone
        if chosen != source {
            processingLock.lock()
            tracker.reset()
            lastFrameTime = nil
            fpsAverage = 0
            processingLock.unlock()
            readouts = []
        }
        source = chosen
        boresight = chosen == .phone ? CGPoint(x: 0.5, y: 0.5) : AppSettings.boresight

        switch chosen {
        case .phone:
            gopro.stop()
            gunSensor.stop()
            motion.start()
            compassAvailable = motion.hasCompass
            camera.start()
        case .gunCamera:
            camera.stop()
            motion.stop()
            startGunHardware()
            compassAvailable = true
        }
    }

    /// GoPro + gun sensor on (also used by the setup screen while the phone camera is selected).
    func startGunHardware() {
        gopro.start()
        gunSensor.start()
    }

    /// Gun + cartridge + next barrel used for the aiming maths (set from the main thread).
    func setLoadout(_ loadout: Loadout) {
        loadoutLock.lock()
        currentLoadout = loadout
        loadoutLock.unlock()
    }

    /// Pauses only the phone camera (e.g. while Settings may use it to scan a cartridge box).
    func pauseCamera() { camera.stop() }

    func stop() {
        camera.stop()
        motion.stop()
        gopro.stop()
        gunSensor.stop()
    }

    // MARK: - Phone camera

    private func processPhoneFrame(_ buffer: CVPixelBuffer, time: Double, focalPx: Double) {
        // Buffers are landscape; the app works in portrait, so width/height swap.
        let size = CGSize(width: CVPixelBufferGetHeight(buffer), height: CVPixelBufferGetWidth(buffer))
        let geometry = CameraGeometry(imageSize: size, focalPx: focalPx,
                                      deviceToWorld: motion.deviceToWorld ?? matrix_identity_double3x3)
        let settings = currentSettings()
        run(buffer, orientation: .right, time: time, size: size, geometry: geometry,
            leadGeometry: nil, leadAhead: 0, settings: settings)
    }

    // MARK: - Gun camera

    private func enqueueGunFrame(_ buffer: CVPixelBuffer, arrival: Double) {
        busyLock.lock()
        if gunBusy { busyLock.unlock(); return }      // drop frames while the model is busy
        gunBusy = true
        busyLock.unlock()
        gunQueue.async {
            self.processGunFrame(buffer, arrival: arrival)
            self.busyLock.lock()
            self.gunBusy = false
            self.busyLock.unlock()
        }
    }

    private func processGunFrame(_ buffer: CVPixelBuffer, arrival: Double) {
        let defaults = UserDefaults.standard
        let capture = arrival - defaults.double(forKey: AppSettings.goproLatencyKey)
        let upsideDown = defaults.bool(forKey: AppSettings.cameraUpsideDownKey)
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let fov = min(170, max(20, defaults.double(forKey: AppSettings.goproFOVKey)))
        let focal = (Double(size.width) / 2) / tan(fov * .pi / 360)

        let then = gunCameraToWorld(at: capture) ?? matrix_identity_double3x3
        let now = CACurrentMediaTime()
        let current = gunCameraToWorld(at: now) ?? then
        var geometry = CameraGeometry(imageSize: size, focalPx: focal, cameraToWorld: then)
        geometry.barrelAxis = geometry.axis(throughNormalized: AppSettings.boresight)

        let settings = currentSettings()
        run(buffer, orientation: upsideDown ? .down : .up, time: capture, size: size, geometry: geometry,
            leadGeometry: geometry.with(cameraToWorld: current), leadAhead: max(0, now - capture),
            settings: settings)
        lastGunContext = GunContext(captureTime: capture, geometry: geometry,
                                    birdSize: settings.birdSize, loadout: settings.loadout)
    }

    private func gunCameraToWorld(at time: Double) -> simd_double3x3? {
        gunSensor.sensorToWorld(at: time).map { GunOrientation.cameraToWorld(sensorToWorld: $0) }
    }

    /// Real shot: judge it with the barrel's orientation just before the recoil and the birds
    /// moved forward to that instant.
    private func handleRecoil(at time: Double) {
        guard UserDefaults.standard.bool(forKey: AppSettings.recoilTriggerKey) else { return }
        gunQueue.async {
            var result: [BirdReadout] = []
            if let ctx = self.lastGunContext, time - ctx.captureTime < 1.5 {
                let barrel = self.gunCameraToWorld(at: time).map { ctx.geometry.with(cameraToWorld: $0) }
                self.processingLock.lock()
                result = self.tracker.snapshot(captureTime: ctx.captureTime, geometry: ctx.geometry,
                                               leadGeometry: barrel ?? ctx.geometry,
                                               leadAhead: max(0, time - ctx.captureTime),
                                               presetSize: ctx.birdSize, loadout: ctx.loadout)
                self.processingLock.unlock()
            }
            DispatchQueue.main.async { self.realShot.send(result) }
        }
    }

    // MARK: - Shared pipeline

    private struct FrameSettings {
        let confidence: Float
        let birdSize: Double
        let identifySpecies: Bool
        let loadout: Loadout
    }

    private func currentSettings() -> FrameSettings {
        let defaults = UserDefaults.standard
        loadoutLock.lock()
        let loadout = currentLoadout
        loadoutLock.unlock()
        return FrameSettings(confidence: Float(defaults.double(forKey: AppSettings.confidenceKey)),
                             birdSize: max(0.05, defaults.double(forKey: AppSettings.birdSizeKey)),
                             identifySpecies: defaults.bool(forKey: AppSettings.identifySpeciesKey),
                             loadout: loadout)
    }

    private func run(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, time: Double,
                     size: CGSize, geometry: CameraGeometry, leadGeometry: CameraGeometry?,
                     leadAhead: Double, settings: FrameSettings) {
        processingLock.lock()
        defer { processingLock.unlock() }

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

        let startedAt = CACurrentMediaTime()
        detector.confidenceThreshold = settings.confidence
        let detections = detector.detect(in: buffer, orientation: orientation)
        let results = tracker.update(detections: detections, time: time, geometry: geometry,
                                     presetSizeMeters: settings.birdSize,
                                     useSpeciesSize: settings.identifySpecies,
                                     loadout: settings.loadout,
                                     leadGeometry: leadGeometry, leadAhead: leadAhead)

        // Species: classify at most three birds per frame, each about five times a second.
        if settings.identifySpecies, let classifier = speciesClassifier {
            for candidate in tracker.classificationCandidates(time: time, imageSize: size, limit: 3) {
                let guesses = classifier.classify(buffer, rect: candidate.rect, imageSize: size,
                                                  orientation: orientation)
                tracker.addSpeciesGuesses(guesses, toTrack: candidate.id, time: time)
            }
        }

        if let last = lastFrameTime, time > last {
            let instant = 1 / (time - last)
            fpsAverage = fpsAverage == 0 ? instant : fpsAverage * 0.9 + instant * 0.1
        }
        lastFrameTime = time
        let fps = fpsAverage
        let busy = (CACurrentMediaTime() - startedAt) * 1000
        processingAverage = processingAverage == 0 ? busy : processingAverage * 0.9 + busy * 0.1
        let processing = processingAverage

        DispatchQueue.main.async {
            self.readouts = results
            self.imageSize = size
            self.fps = fps
            self.processingMs = processing
        }
    }
}
