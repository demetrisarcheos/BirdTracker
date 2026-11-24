import SwiftUI

struct ContentView: View {
    @StateObject private var engine = BirdTrackingEngine()
    @AppStorage(AppSettings.speedUnitKey) private var speedUnitRaw = SpeedUnit.kmh.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }

    /// The bird shown in the big panel: the one with the largest box (usually the nearest).
    private var primary: BirdReadout? {
        engine.readouts.max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    var body: some View {
        ZStack {
            CameraPreview(session: engine.camera.session)
                .ignoresSafeArea()

            GeometryReader { geo in
                ForEach(engine.readouts) { bird in
                    let frame = aspectFillRect(bird.rect, imageSize: engine.imageSize, in: geo.size)
                    BirdBoxView(bird: bird, unit: unit, isPrimary: bird.id == primary?.id)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                topBar
                Spacer()
                if let message = engine.errorMessage ?? (engine.cameraDenied
                    ? "Camera access is off. Enable it in Settings › Bird Tracker." : nil) {
                    Text(message)
                        .font(.callout)
                        .padding()
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
                }
                HUDView(bird: primary, unit: unit, compassAvailable: engine.compassAvailable)
            }
            .padding()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            engine.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { engine.start() } else if phase == .background { engine.stop() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private var topBar: some View {
        HStack {
            Label("\(engine.readouts.count)", systemImage: "bird")
                .font(.headline)
            Spacer()
            Text(String(format: "%.0f fps", engine.fps))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { showSettings = true } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Bounding box + compact label drawn over each bird.
struct BirdBoxView: View {
    let bird: BirdReadout
    let unit: SpeedUnit
    let isPrimary: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .stroke(isPrimary ? Color.yellow : Color.green, lineWidth: isPrimary ? 3 : 2)
            .overlay(alignment: .topLeading) {
                Text(label)
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .offset(y: -22)
            }
    }

    private var label: String {
        var parts = ["#\(bird.id)", Format.distance(bird.distance)]
        if let s = bird.speed { parts.append(Format.speed(s, unit: unit)) }
        if let b = bird.bearing { parts.append(Format.shortCompass(b)) }
        return parts.joined(separator: " · ")
    }
}
