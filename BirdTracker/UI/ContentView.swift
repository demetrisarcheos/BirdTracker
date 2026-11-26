import SwiftUI

struct ContentView: View {
    @StateObject private var engine = BirdTrackingEngine()
    @StateObject private var sound = SoundEngine()
    @StateObject private var haptics = RecoilHaptics()
    @AppStorage(AppSettings.shootVibrationKey) private var shootVibration = true
    @AppStorage(AppSettings.shotSoundKey) private var shotSound = true
    @AppStorage(AppSettings.aimBeepsKey) private var aimBeeps = true
    @AppStorage(AppSettings.speedUnitKey) private var speedUnitRaw = SpeedUnit.kmh.rawValue
    @AppStorage(AppSettings.identifySpeciesKey) private var identifySpecies = true
    @AppStorage(AppSettings.showLeadPointKey) private var showLeadPoint = true
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var shotResult: ShotResult?
    @State private var shots = 0
    @State private var hits = 0
    @AppStorage(GearStore.gunKey) private var gunJSON = ""
    @AppStorage(GearStore.cartridgesKey) private var cartridgesJSON = ""
    @AppStorage(GearStore.selectedCartridgeKey) private var selectedCartridgeID = ""
    /// Double guns fire barrel 1 then barrel 2; back to barrel 1 after a pause.
    @State private var nextBarrel = 1
    @State private var loadoutSummary = ""
    @AppStorage(AppSettings.cameraUpsideDownKey) private var cameraUpsideDown = false
    @State private var pocketLocked = false

    private var gunMode: Bool { engine.source == .gunCamera }

    /// Phone preview fills the screen; the landscape GoPro picture is letterboxed.
    private func onScreen(_ rect: CGRect, in size: CGSize) -> CGRect {
        imageRect(rect, imageSize: engine.imageSize, in: size, fill: !gunMode)
    }

    private var unit: SpeedUnit { SpeedUnit(rawValue: speedUnitRaw) ?? .kmh }
    private var loadoutKey: String { "\(gunJSON)|\(cartridgesJSON)|\(selectedCartridgeID)|\(nextBarrel)" }

    /// The bird in the sights: the one whose aiming point is closest to the reticle.
    /// Falls back to the largest box (usually the nearest) when no aiming point is available.
    private var primary: BirdReadout? { Self.primaryBird(engine.readouts) }

    static func primaryBird(_ readouts: [BirdReadout]) -> BirdReadout? {
        if let aimed = readouts.filter({ $0.lead != nil })
            .min(by: { $0.lead!.missInSigmas < $1.lead!.missInSigmas }) {
            return aimed
        }
        return readouts.max { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height }
    }

    private var onTarget: Bool { primary?.lead?.isHit ?? false }

    /// Parking-sensor rhythm for the aiming beeps (nil = silent, 0 = continuous).
    private var beepGap: Double? {
        guard aimBeeps, !showSettings else { return nil }
        return SoundEngine.beepGap(for: primary?.lead)
    }

    var body: some View {
        ZStack {
            if gunMode {
                GoProVideoView(camera: engine.gopro, upsideDown: cameraUpsideDown)
                    .ignoresSafeArea()
            } else {
                PhoneCameraPreview(camera: engine.camera)
                    .ignoresSafeArea()
            }

            GeometryReader { geo in
                // Faint square: the centre-zoom area searched at full resolution.
                if let zoom = engine.zoomRect {
                    let z = onScreen(zoom, in: geo.size)
                    Rectangle()
                        .stroke(.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [6, 6]))
                        .frame(width: z.width, height: z.height)
                        .position(x: z.midX, y: z.midY)
                }
                ForEach(engine.readouts) { bird in
                    let frame = onScreen(bird.rect, in: geo.size)
                    BirdBoxView(bird: bird, unit: unit, isPrimary: bird.id == primary?.id)
                        .frame(width: frame.width, height: frame.height)
                        .position(x: frame.midX, y: frame.midY)
                }
                if showLeadPoint, let bird = primary, let lead = bird.lead, lead.ready {
                    let box = onScreen(bird.rect, in: geo.size)
                    let aim = onScreen(CGRect(origin: lead.aimPoint, size: .zero), in: geo.size).origin
                    LeadMarkerView(from: CGPoint(x: box.midX, y: box.midY), to: aim, onTarget: lead.isHit)
                }
                // Aiming point: where the shot goes. Phone: the screen centre (= image centre, the optical
                // axis). Gun camera: the barrel point found in the alignment step.
                ReticleView()
                    .position(onScreen(CGRect(origin: engine.boresight, size: .zero), in: geo.size).origin)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 12) {
                topBar
                if gunMode {
                    GunSourceBanner(gopro: engine.gopro, sensor: engine.gunSensor)
                }
                Spacer()
                if let message = engine.errorMessage ?? (engine.cameraDenied && !gunMode
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
                        .background(resultColor(shotResult).opacity(0.75),
                                    in: RoundedRectangle(cornerRadius: 18))
                        .transition(.scale.combined(with: .opacity))
                }
                ShootButton(lead: primary?.lead, action: { shoot() })
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) {
                        if !gunMode {
                            ZoomPicker(camera: engine.camera) { engine.setZoom($0) }
                        }
                    }
                HUDView(bird: primary, unit: unit, compassAvailable: engine.compassAvailable,
                        speciesEnabled: identifySpecies && engine.speciesAvailable,
                        loadoutSummary: loadoutSummary)
            }
            .padding()

            if pocketLocked {
                PocketLockView { pocketLocked = false }
            }
        }
        .onReceive(engine.realShot) { readouts in shoot(realShot: readouts) }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            updateLoadout()
            engine.start()
            sound.start()
        }
        .onChange(of: beepGap) { _, gap in sound.setBeepGap(gap) }
        .onChange(of: loadoutKey) { _, _ in updateLoadout() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                engine.start()
                sound.start()
            } else if phase == .background {
                engine.stop()
                sound.stop()
            }
        }
        .onChange(of: onTarget) { _, now in
            if now { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
        }
        // The camera is paused while Settings is open, so it is free for scanning a cartridge box.
        .sheet(isPresented: $showSettings, onDismiss: { engine.start() }) {
            SettingsView().environmentObject(engine)
        }
    }

    private func updateLoadout() {
        let loadout = GearStore.loadout(barrel: nextBarrel)
        engine.setLoadout(loadout)
        loadoutSummary = "\(loadout.gun.title) · \(loadout.summary)"
    }

    private func resultColor(_ result: ShotResult) -> Color {
        switch result.outcome {
        case .kill:    return .green
        case .wounded: return .orange
        default:       return .black
        }
    }

    /// Simulated shot (Shoot button): judged on the latest frame at the moment of the tap.
    /// Real shot (recoil from the gun sensor): judged on the birds and barrel at the moment of firing;
    /// no fake bang or vibration.
    private func shoot(realShot readouts: [BirdReadout]? = nil) {
        let gun = GearStore.gun(gunJSON)
        let barrelNote = gun.action.isDouble ? "Barrel \(nextBarrel)" : ""
        let bird = readouts.map { Self.primaryBird($0) } ?? primary
        let result = ShotResult.simulate(bird, barrelNote: barrelNote)
        let real = readouts != nil
        if shotSound && !real { sound.playShot() }
        if result.counts {
            shots += 1
            if result.hit { hits += 1 }
            if gun.action.isDouble {
                // Second barrel next; after 4 s without shooting, assume the gun was reloaded.
                nextBarrel = nextBarrel == 1 ? 2 : 1
                let shotCount = shots
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if shots == shotCount { nextBarrel = 1 }
                }
            }
        }
        // Recoil: 1 s vibration, only when enabled in Settings.
        if shootVibration && !real { haptics.playRecoil() }
        withAnimation(.spring(duration: 0.25)) { shotResult = result }
        let id = result.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
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
            if gunMode {
                Button {
                    pocketLocked = true
                } label: {
                    Image(systemName: "lock").font(.title3)
                }
            }
            // Frames analysed per second · phone time per frame (under ~16 ms = it could do 60 fps).
            Text(String(format: "%.0f fps · %.0f ms", engine.fps, engine.processingMs))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                engine.pauseCamera()
                showSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3").font(.title3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

/// Phone camera preview that follows lens switches.
private struct PhoneCameraPreview: View {
    @ObservedObject var camera: CameraManager

    var body: some View {
        CameraPreview(session: camera.session, configurationID: camera.configurationID)
    }
}

/// 1× / 2× / 5× buttons (real camera zoom; distance maths follows it).
private struct ZoomPicker: View {
    @ObservedObject var camera: CameraManager
    let select: (Double) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomOptions, id: \.self) { level in
                let active = abs(level - camera.zoom) < 0.01
                Button {
                    select(level)
                } label: {
                    Text(level == level.rounded() ? String(format: "%.0f×", level) : String(format: "%.1f×", level))
                        .font(.caption.bold().monospacedDigit())
                        .frame(width: 34, height: 34)
                        .foregroundStyle(active ? .black : .white)
                        .background(active ? Color.yellow : Color.black.opacity(0.45), in: Circle())
                }
            }
        }
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
        if bird.perched {
            parts.append("perched")
        } else if let s = bird.speed {
            parts.append(Format.speed(s, unit: unit))
        }
        if let b = bird.bearing { parts.append(Format.shortCompass(b)) }
        return parts.joined(separator: " · ")
    }
}
