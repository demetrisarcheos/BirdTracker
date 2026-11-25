import SwiftUI

struct ContentView: View {
    @StateObject private var engine = BirdTrackingEngine()
    @AppStorage(AppSettings.speedUnitKey) private var speedUnitRaw = SpeedUnit.kmh.rawValue
    @AppStorage(AppSettings.identifySpeciesKey) private var identifySpecies = true
    @AppStorage(AppSettings.showLeadPointKey) private var showLeadPoint = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var shotResult: ShotResult?
    @State private var shots = 0
    @State private var hits = 0

    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }

    /// The bird in the sights: the one whose aiming point is closest to the reticle.
    /// Falls back to the largest box (usually the nearest) when no aiming point is available.
    private var primary: BirdReadout? {
        if let aimed = engine.readouts.filter({ $0.lead != nil })
            .min(by: { $0.lead!.hitRatio < $1.lead!.hitRatio }) {
            return aimed
        }
        return engine.readouts.max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    private var onTarget: Bool { primary?.lead?.isHit ?? false }

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
                if showLeadPoint, let bird = primary, let lead = bird.lead, lead.ready {
                    let box = aspectFillRect(bird.rect, imageSize: engine.imageSize, in: geo.size)
                    let aim = aspectFillRect(CGRect(origin: lead.aimPoint, size: .zero),
                                             imageSize: engine.imageSize, in: geo.size).origin
                    LeadMarkerView(from: CGPoint(x: box.midX, y: box.midY), to: aim, onTarget: lead.isHit)
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            // Aiming point: centre of the full screen (same as the centre of the camera image).
            ReticleView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if let shotResult {
                    Text(shotResult.text)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background((shotResult.hit ? Color.green : Color.black).opacity(0.75),
                                    in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
                ShootButton(lead: primary?.lead, action: shoot)
                HUDView(bird: primary, unit: unit, compassAvailable: engine.compassAvailable,
                        speciesEnabled: identifySpecies && engine.speciesAvailable)
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
        .onChange(of: onTarget) { _, now in
            if now { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    /// Simulated shot: judged on the latest frame at the moment of the tap.
    private func shoot() {
        let result = ShotResult.evaluate(primary)
        if primary?.lead?.ready == true {
            shots += 1
            if result.hit { hits += 1 }
        }
        UINotificationFeedbackGenerator().notificationOccurred(result.hit ? .success : .error)
        withAnimation(.spring(duration: 0.25)) { shotResult = result }
        let id = result.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if shotResult?.id == id { withAnimation { shotResult = nil } }
        }
    }

    private var topBar: some View {
        HStack {
            Label("\(engine.readouts.count)", systemImage: "bird")
                .font(.headline)
            if shots > 0 {
                Label("\(hits)/\(shots)", systemImage: "scope")
                    .font(.headline.monospacedDigit())
                    .onLongPressGesture { shots = 0; hits = 0 }
            }
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
        var parts = [bird.species ?? "#\(bird.id)", Format.distance(bird.distance)]
        if let s = bird.speed { parts.append(Format.speed(s, unit: unit)) }
        if let b = bird.bearing { parts.append(Format.shortCompass(b)) }
        return parts.joined(separator: " · ")
    }
}
