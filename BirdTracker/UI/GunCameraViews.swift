import AVFoundation
import Combine
import QuartzCore
import simd
import SwiftUI
import UIKit

/// Shows the GoPro's live video (aspect-fit by default).
struct GoProVideoView: UIViewRepresentable {
    let camera: GoProCamera
    var upsideDown: Bool
    var fill = false

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        camera.addDisplay(view.displayLayer)
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        view.upsideDown = upsideDown
        view.displayLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        view.setNeedsLayout()
    }

    final class VideoView: UIView {
        let displayLayer = AVSampleBufferDisplayLayer()
        var upsideDown = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            backgroundColor = .black
            clipsToBounds = true
            layer.addSublayer(displayLayer)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            displayLayer.setAffineTransform(.identity)
            displayLayer.frame = bounds
            displayLayer.setAffineTransform(upsideDown ? CGAffineTransform(rotationAngle: .pi) : .identity)
            CATransaction.commit()
        }
    }
}

/// Problems with the gun camera, shown on the main screen.
struct GunSourceBanner: View {
    @ObservedObject var gopro: GoProCamera
    @ObservedObject var sensor: GunSensor

    var body: some View {
        let issues = [
            gopro.status == .streaming ? nil : "GoPro: \(gopro.status.text)",
            sensor.status == .connected ? nil : "Gun sensor: \(sensor.statusText)",
        ].compactMap { $0 }
        if !issues.isEmpty {
            Text(issues.joined(separator: "\n"))
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(8)
                .background(.orange.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Black screen that ignores touches while the phone is in a pocket. Hold for 2 s to unlock.
struct PocketLockView: View {
    let unlock: () -> Void

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "lock.fill").font(.title)
                    Text("Pocket lock").font(.headline)
                    Text("Tracking and beeps keep running.\nHold anywhere for 2 seconds to unlock.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.gray.opacity(0.6))
            }
            .contentShape(Rectangle())
            .onLongPressGesture(minimumDuration: 2) { unlock() }
    }
}

// MARK: - Setup

struct GunCameraSetupView: View {
    @EnvironmentObject private var engine: BirdTrackingEngine

    var body: some View {
        GunCameraSetupContent(gopro: engine.gopro, bluetooth: engine.goproBluetooth, sensor: engine.gunSensor)
            .onAppear { engine.startGunHardware() }
    }
}

private struct GunCameraSetupContent: View {
    @ObservedObject var gopro: GoProCamera
    @ObservedObject var bluetooth: GoProBluetooth
    @ObservedObject var sensor: GunSensor

    @AppStorage(AppSettings.goproFOVKey) private var fov = 86.0
    @AppStorage(AppSettings.goproLatencyKey) private var latency = 0.25
    @AppStorage(AppSettings.cameraUpsideDownKey) private var upsideDown = false
    @AppStorage(AppSettings.boresightXKey) private var boresightX = 0.5
    @AppStorage(AppSettings.boresightYKey) private var boresightY = 0.5
    @AppStorage(AppSettings.sensorMountKey) private var mountRaw = SensorMount.topLabelUp.rawValue
    @AppStorage(AppSettings.headingOffsetKey) private var headingOffset = 0.0
    @AppStorage(AppSettings.recoilTriggerKey) private var recoilTrigger = true
    @AppStorage(AppSettings.recoilThresholdKey) private var recoilThreshold = 6.0

    private var videoSize: CGSize {
        gopro.resolution.width > 0 ? gopro.resolution : CGSize(width: 16, height: 9)
    }

    /// Gun camera orientation from the latest sensor reading.
    private var gunOrientation: simd_double3x3? {
        _ = mountRaw; _ = headingOffset          // re-evaluate when these change
        return sensor.latest.map { GunOrientation.cameraToWorld(sensorToWorld: $0) }
    }

    var body: some View {
        Form {
            Section {
                GeometryReader { geo in
                    ZStack {
                        GoProVideoView(camera: gopro, upsideDown: upsideDown)
                        let p = aspectFitRect(CGRect(x: boresightX, y: boresightY, width: 0, height: 0),
                                              imageSize: videoSize, in: geo.size).origin
                        ReticleView(size: 40).position(p)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .listRowInsets(EdgeInsets())
                LabeledContent("Status", value: gopro.status.text)
                if let api = gopro.api {
                    LabeledContent("Camera type", value: api.title)
                } else if gopro.status == .searching {
                    Text("The app looks for both new (HERO9+) and older (HERO5–HERO8) GoPros. If it never finds the camera, check iPhone Settings › Bird Tracker › Local Network is on.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if gopro.status == .streaming {
                    LabeledContent("Video",
                                   value: "\(Int(gopro.resolution.width))×\(Int(gopro.resolution.height)) · \(Int(gopro.fps.rounded())) fps")
                }
            } header: {
                Text("GoPro video")
            }

            Section {
                Text("1. Switch the GoPro on (Preferences › Connections › Wireless Connections: on; on a HERO7, also Connect Device › GoPro App).\n" +
                     "2. Tap the button below to switch on its Wi-Fi, or open the GoPro Quik app once.\n" +
                     "3. In iPhone Settings › Wi-Fi, join the GoPro's network, then come back.")
                    .font(.footnote)
                Button("Switch on GoPro Wi-Fi (Bluetooth)") { bluetooth.enableWiFi() }
                if !bluetooth.state.isEmpty {
                    Text(bluetooth.state).font(.footnote).foregroundStyle(.secondary)
                }
                if let ssid = bluetooth.ssid {
                    LabeledContent("Network", value: ssid).textSelection(.enabled)
                }
                if let password = bluetooth.password {
                    LabeledContent("Password", value: password).textSelection(.enabled)
                    Button("Copy password") { UIPasteboard.general.string = password }
                }
            } header: {
                Text("Connect the GoPro")
            }

            Section {
                Stepper(value: $fov, in: 30...150, step: 1) {
                    Text("Field of view: \(Int(fov))°")
                }
                Button("Use GoPro Linear lens (86°)") { fov = 86 }
                NavigationLink("Measure field of view") { FOVCalibrationView(gopro: gopro) }
                Toggle("Camera mounted upside down", isOn: $upsideDown)
            } header: {
                Text("Lens")
            } footer: {
                Text("Use the Linear lens: the distance maths needs straight lines (Wide/SuperView bend them). " +
                     "The app asks the GoPro for Linear and no HyperSmooth, but check it on the camera. " +
                     "Distance and speed scale directly with the field of view, so measuring it is worth it.")
            }

            Section {
                VStack(alignment: .leading) {
                    Text("Video delay: \(Int((latency * 1000).rounded())) ms")
                    Slider(value: $latency, in: 0...0.8, step: 0.01)
                }
                NavigationLink("Measure delay") { LatencyTestView(gopro: gopro) }
            } header: {
                Text("Video delay")
            } footer: {
                Text("Wi-Fi video arrives late (typically 200–300 ms). The app moves each bird forward by this " +
                     "much, so the shooting point matches where the bird is now.")
            }

            Section {
                LabeledContent("Barrel point",
                               value: String(format: "%.0f %% across, %.0f %% down", boresightX * 100, boresightY * 100))
                NavigationLink("Align camera with barrel") { BoresightView(gopro: gopro) }
                Button("Reset to picture centre") { boresightX = 0.5; boresightY = 0.5 }
            } header: {
                Text("Barrel alignment")
            } footer: {
                Text("The red reticle must sit exactly where the barrel points. Rest the gun, aim it at a distant " +
                     "point (50 m or more) and mark that point in the picture.")
            }

            sensorSection

            Section {
                Toggle("Count real shots (recoil)", isOn: $recoilTrigger)
                Stepper(value: $recoilThreshold, in: 3...15, step: 1) {
                    Text("Recoil threshold: \(Int(recoilThreshold)) g")
                }
            } header: {
                Text("Real shots")
            } footer: {
                Text("When the gun sensor feels recoil, the shot is judged with where the barrel pointed just " +
                     "before it. With the phone in your pocket, listen to the aiming beeps with earphones " +
                     "(silent mode off).")
            }
        }
        .navigationTitle("GoPro & gun sensor")
    }

    @ViewBuilder private var sensorSection: some View {
        Section {
            LabeledContent("Status", value: sensor.statusText)
            if let name = sensor.connectedName, sensor.status == .connected {
                LabeledContent("Sensor", value: "\(name) · \(Int(sensor.rateHz.rounded())) Hz")
            }
            Button("Search for sensors") { sensor.scan() }
            ForEach(sensor.found) { item in
                Button {
                    sensor.connect(item.id)
                } label: {
                    Label(item.name, systemImage: "dot.radiowaves.left.and.right")
                }
            }
            if sensor.connectedName != nil {
                Button("Forget this sensor", role: .destructive) { sensor.forget() }
            }

            Picker("Mounted", selection: $mountRaw) {
                ForEach(SensorMount.allCases) { Text($0.title).tag($0.rawValue) }
            }

            if sensor.conventionLearned {
                Label("Axis check done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Button("Redo axis check") { sensor.relearn() }
            } else if sensor.status == .connected {
                Label("Axis check: hold the gun still, then tilt it up and down, side to side, and swing it " +
                      "left and right a few times.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote)
            }

            if let c = gunOrientation {
                LabeledContent("Barrel elevation", value: String(format: "%+.0f°", GunOrientation.elevation(c)))
                LabeledContent("Cant", value: String(format: "%+.0f°", GunOrientation.cant(c)))
                LabeledContent("Heading", value: String(format: "%.0f° %@", GunOrientation.heading(c),
                                                          Format.shortCompass(GunOrientation.heading(c))))
                Button("The gun points north now") {
                    var offset = GunOrientation.heading(c) + headingOffset
                    offset = offset.truncatingRemainder(dividingBy: 360)
                    if offset < 0 { offset += 360 }
                    headingOffset = offset
                }
            }
        } header: {
            Text("Gun motion sensor")
        } footer: {
            Text("WitMotion WT901BLECL with its X arrow pointing to the muzzle. Check: raising the barrel must " +
                 "give a positive elevation. Heading only matters for the flight-direction display; set it by " +
                 "pointing the gun north.")
        }
    }
}

// MARK: - Delay test

/// Measures the GoPro's video delay: the phone screen flashes white and the app times how long the
/// flash takes to show up in the GoPro video.
struct LatencyTestView: View {
    @ObservedObject var gopro: GoProCamera
    @AppStorage(AppSettings.goproLatencyKey) private var latency = 0.25
    @State private var white = false
    @State private var running = false
    @State private var message = "Point the GoPro at this screen from about 20–30 cm, then tap Start."
    @State private var probe = LatencyProbe()

    var body: some View {
        ZStack {
            (white ? Color.white : Color.black).ignoresSafeArea()
            if !white {
                VStack(spacing: 16) {
                    Spacer()
                    Text(message)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Button(running ? "Measuring…" : "Start") { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(running)
                }
                .padding()
            }
        }
        .navigationTitle("Video delay")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            gopro.onBrightness = nil
            probe.cancelled = true
        }
    }

    private func start() {
        running = true
        probe = LatencyProbe()
        let probe = self.probe
        gopro.onBrightness = { time, brightness in
            DispatchQueue.main.async { probe.add(time: time, brightness: brightness) }
        }
        Task { @MainActor in
            var samples: [Double] = []
            for i in 0..<6 {
                guard !probe.cancelled else { return }
                white = false
                probe.beginBaseline()
                message = "Flash \(i + 1) of 6…"
                try? await Task.sleep(for: .seconds(1.2))
                white = true
                probe.beginFlash(at: CACurrentMediaTime() + 0.017)    // about one screen refresh
                try? await Task.sleep(for: .seconds(1.0))
                if let d = probe.detected { samples.append(d) }
            }
            white = false
            running = false
            gopro.onBrightness = nil
            if samples.count >= 3 {
                let median = samples.sorted()[samples.count / 2]
                latency = min(0.8, max(0, median))
                message = "Delay: \(Int((median * 1000).rounded())) ms (saved). Measured \(samples.count) of 6 flashes."
            } else {
                message = "The flashes could not be seen in the video. Hold the GoPro closer to the screen, " +
                          "make sure video is coming in, and try again."
            }
        }
    }
}

final class LatencyProbe {
    var cancelled = false
    private(set) var detected: Double?
    private var flashStart: Double?
    private var baselineSum = 0.0
    private var baselineCount = 0

    func beginBaseline() {
        flashStart = nil
        detected = nil
        baselineSum = 0
        baselineCount = 0
    }

    func beginFlash(at time: Double) { flashStart = time }

    func add(time: Double, brightness: Double) {
        guard let start = flashStart else {
            baselineSum += brightness
            baselineCount += 1
            return
        }
        let baseline = baselineCount > 0 ? baselineSum / Double(baselineCount) : 0
        if detected == nil, time > start, brightness > baseline + 0.12 {
            detected = time - start
        }
    }
}

// MARK: - Calibration pictures

/// A still from the GoPro where the user taps points.
private struct FrozenFrameView: View {
    let image: UIImage
    let points: [CGPoint]
    let onTap: (CGPoint) -> Void

    var body: some View {
        GeometryReader { geo in
            let rect = aspectFitRect(CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: image.size, in: geo.size)
            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geo.size.width, height: geo.size.height)
                ForEach(points.indices, id: \.self) { i in
                    ReticleView(size: 34)
                        .position(x: rect.minX + points[i].x * rect.width, y: rect.minY + points[i].y * rect.height)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                if let p = normalizedPointInFit(location, imageSize: image.size, in: geo.size) { onTap(p) }
            }
        }
        .aspectRatio(image.size.width / max(image.size.height, 1), contentMode: .fit)
    }
}

/// Field of view from an object of known width at a known distance.
struct FOVCalibrationView: View {
    @ObservedObject var gopro: GoProCamera
    @AppStorage(AppSettings.goproFOVKey) private var fov = 86.0
    @AppStorage(AppSettings.cameraUpsideDownKey) private var upsideDown = false
    @State private var image: UIImage?
    @State private var points: [CGPoint] = []
    @State private var width = 1.0
    @State private var distance = 10.0

    private var result: Double? {
        guard let image, points.count == 2, width > 0, distance > 0 else { return nil }
        let w = Double(image.size.width), h = Double(image.size.height)
        let px = hypot(Double(points[1].x - points[0].x) * w, Double(points[1].y - points[0].y) * h)
        guard px > 5 else { return nil }
        let focal = px * distance / width
        return 2 * atan(w / 2 / focal) * 180 / .pi
    }

    var body: some View {
        Form {
            Section {
                Text("1. Put an object of known width (e.g. a 1 m board) at a measured distance of 5–20 m, " +
                     "square to the camera, near the middle of the picture.\n2. Tap Freeze.\n" +
                     "3. Tap its left edge, then its right edge.")
                    .font(.footnote)
                if let image {
                    FrozenFrameView(image: image, points: points) { p in
                        points = points.count >= 2 ? [p] : points + [p]
                    }
                    .listRowInsets(EdgeInsets())
                }
                Button(image == nil ? "Freeze picture" : "Take a new picture") {
                    image = gopro.snapshot(upsideDown: upsideDown)
                    points = []
                }
            }
            Section("Object") {
                LabeledContent("Width (m)") {
                    TextField("Width", value: $width, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Distance (m)") {
                    TextField("Distance", value: $distance, format: .number)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let result {
                Section {
                    LabeledContent("Field of view", value: String(format: "%.1f°", result))
                    Button("Save") { fov = (result * 10).rounded() / 10 }
                } footer: {
                    Text("Currently saved: \(String(format: "%.1f", fov))°")
                }
            }
        }
        .navigationTitle("Field of view")
    }
}

/// Marks where the barrel points in the GoPro picture.
struct BoresightView: View {
    @ObservedObject var gopro: GoProCamera
    @AppStorage(AppSettings.cameraUpsideDownKey) private var upsideDown = false
    @AppStorage(AppSettings.boresightXKey) private var boresightX = 0.5
    @AppStorage(AppSettings.boresightYKey) private var boresightY = 0.5
    @State private var image: UIImage?

    var body: some View {
        Form {
            Section {
                Text("1. Rest the gun so it cannot move and aim the barrel exactly at a small, distant mark " +
                     "(50 m or more).\n2. Tap Freeze.\n3. Tap the mark in the picture.")
                    .font(.footnote)
                if let image {
                    FrozenFrameView(image: image, points: [CGPoint(x: boresightX, y: boresightY)]) { p in
                        boresightX = Double(p.x)
                        boresightY = Double(p.y)
                    }
                    .listRowInsets(EdgeInsets())
                }
                Button(image == nil ? "Freeze picture" : "Take a new picture") {
                    image = gopro.snapshot(upsideDown: upsideDown)
                }
            } footer: {
                Text("Saved as soon as you tap. The reticle on the main screen moves to this point.")
            }
        }
        .navigationTitle("Barrel alignment")
    }
}
