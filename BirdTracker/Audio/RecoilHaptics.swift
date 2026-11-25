import Combine
import CoreHaptics

/// One-second "recoil" vibration for the Shoot button (Core Haptics: a hard kick followed by a
/// rumble that fades over 1 s). Standard UIKit haptics are too short for this.
final class RecoilHaptics: ObservableObject {
    static let duration: TimeInterval = 1.0

    private var engine: CHHapticEngine?
    private var pattern: CHHapticPattern?

    init() {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let engine = try CHHapticEngine()
            engine.isAutoShutdownEnabled = true      // sleeps between shots to save battery
            engine.resetHandler = { [weak engine] in try? engine?.start() }
            self.engine = engine
            pattern = try Self.makePattern()
        } catch {
            engine = nil
        }
    }

    func playRecoil() {
        guard let engine, let pattern else { return }
        do {
            try engine.start()                       // no-op when already running
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Haptics are optional.
        }
    }

    private static func makePattern() throws -> CHHapticPattern {
        let kick = CHHapticEvent(eventType: .hapticTransient,
                                 parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                              CHHapticEventParameter(parameterID: .hapticSharpness, value: 1)],
                                 relativeTime: 0)
        let rumble = CHHapticEvent(eventType: .hapticContinuous,
                                   parameters: [CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                                                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.35)],
                                   relativeTime: 0, duration: duration)
        let fade = CHHapticParameterCurve(
            parameterID: .hapticIntensityControl,
            controlPoints: [CHHapticParameterCurve.ControlPoint(relativeTime: 0, value: 1),
                            CHHapticParameterCurve.ControlPoint(relativeTime: 0.25, value: 0.8),
                            CHHapticParameterCurve.ControlPoint(relativeTime: duration, value: 0.4)],
            relativeTime: 0)
        return try CHHapticPattern(events: [kick, rumble], parameterCurves: [fade])
    }
}
