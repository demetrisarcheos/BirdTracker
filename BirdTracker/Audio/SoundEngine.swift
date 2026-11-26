import AVFoundation
import Combine
import QuartzCore

/// Shot sound and parking-sensor style aiming beeps, synthesised in code (no audio files).
///
/// Phone camera: the `.ambient` audio session category, which iOS mutes when the Ring/Silent
/// switch (or Action-button silent mode) is on silent. Gun camera: `.playback`, which keeps
/// sounding with the phone locked in a pocket (see `playsInBackground`). Both mix with other audio.
final class SoundEngine: ObservableObject {
    private let engine = AVAudioEngine()
    private let shotPlayer = AVAudioPlayerNode()
    private let beepPlayer = AVAudioPlayerNode()
    private let tonePlayer = AVAudioPlayerNode()
    private let sampleRate = 44_100.0
    private let format: AVAudioFormat
    private var shotBuffer: AVAudioPCMBuffer?
    private var beepBuffer: AVAudioPCMBuffer?
    private var toneBuffer: AVAudioPCMBuffer?

    private var timer: Timer?
    private var lastBeep = 0.0
    private var active = false
    /// nil = silent, 0 = continuous tone, otherwise seconds of silence between beeps.
    private var beepGap: Double?

    static let beepDuration = 0.07
    /// 1837.5 Hz = exactly 24 samples per cycle, so the looping tone has no click at the seam.
    private static let beepFrequency = 44_100.0 / 24

    init() {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        for node in [shotPlayer, beepPlayer, tonePlayer] {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
        }
        shotBuffer = makeShotBuffer()
        beepBuffer = makeBeepBuffer()
        toneBuffer = makeToneBuffer()
        tonePlayer.volume = 0
    }

    // MARK: Control

    /// Gun camera: keep sounding (and so keep the app running) in the background and play even
    /// when the phone is on silent — with the phone in a pocket the beeps are the only aiming cue.
    /// Phone camera: `.ambient`, which follows the silent switch.
    var playsInBackground = false {
        didSet { if active && oldValue != playsInBackground { configureSession() } }
    }

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(playsInBackground ? .playback : .ambient, mode: .default,
                                 options: [.mixWithOthers])
        try? session.setActive(true)
    }

    func start() {
        guard !active else { return }
        active = true
        configureSession()
        startEngineIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    func stop() {
        guard active else { return }
        active = false
        timer?.invalidate()
        timer = nil
        beepGap = nil
        tonePlayer.volume = 0
        engine.pause()
    }

    /// Sets the beep rhythm: nil = silent, 0 = continuous tone, otherwise the gap between beeps (s).
    func setBeepGap(_ gap: Double?) { beepGap = gap }

    func playShot() {
        guard active, let shotBuffer else { return }
        startEngineIfNeeded()
        shotPlayer.scheduleBuffer(shotBuffer, at: nil, options: .interrupts)
        if !shotPlayer.isPlaying { shotPlayer.play() }
    }

    /// Result of a real shot, for when the screen is in a pocket: two rising chirps for a hit,
    /// one low buzz for a miss.
    func playResult(hit: Bool) {
        guard active, let buffer = hit ? hitBuffer : missBuffer else { return }
        startEngineIfNeeded()
        shotPlayer.scheduleBuffer(buffer, at: nil, options: .interrupts)
        if !shotPlayer.isPlaying { shotPlayer.play() }
    }

    private lazy var hitBuffer: AVAudioPCMBuffer? = makeChirps([1400, 2100], length: 0.09, gap: 0.06)
    private lazy var missBuffer: AVAudioPCMBuffer? = makeChirps([330], length: 0.35, gap: 0)

    private func makeChirps(_ frequencies: [Double], length: Double, gap: Double) -> AVAudioPCMBuffer? {
        let total = Double(frequencies.count) * (length + gap)
        guard let b = buffer(seconds: total), let data = b.floatChannelData?[0] else { return nil }
        let n = Int(length * sampleRate), step = Int((length + gap) * sampleRate)
        let ramp = Int(0.006 * sampleRate)
        for i in 0..<Int(b.frameLength) { data[i] = 0 }
        for (k, f) in frequencies.enumerated() {
            for i in 0..<n where k * step + i < Int(b.frameLength) {
                let envelope = Float(min(1, Double(min(i, n - 1 - i)) / Double(ramp)))
                data[k * step + i] = 0.6 * envelope * Float(sin(2 * .pi * f * Double(i) / sampleRate))
            }
        }
        return b
    }

    /// Beep rhythm for an aiming solution, like a car parking sensor: silent when far off,
    /// faster beeps as the reticle closes in, a continuous tone at the shooting point.
    static func beepGap(for lead: LeadSolution?) -> Double? {
        guard let lead, lead.ready, !lead.outOfRange else { return nil }
        if lead.isHit { return 0 }
        let r = lead.hitRatio
        guard r < 8 else { return nil }
        let f = log(r) / log(8)          // 0 at the edge of the kill zone … 1 at 8× off
        return 0.05 + f * 0.85
    }

    // MARK: Private

    private func startEngineIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            if let toneBuffer {
                tonePlayer.scheduleBuffer(toneBuffer, at: nil, options: [.loops, .interrupts])
            }
            for node in [shotPlayer, beepPlayer, tonePlayer] { node.play() }
        } catch {
            // Audio is optional; try again on the next tick.
        }
    }

    private func tick() {
        guard active else { return }
        startEngineIfNeeded()
        guard let gap = beepGap else {
            tonePlayer.volume = 0
            return
        }
        if gap == 0 {
            tonePlayer.volume = 0.5
            return
        }
        tonePlayer.volume = 0
        let now = CACurrentMediaTime()
        if now - lastBeep >= Self.beepDuration + gap, let beepBuffer {
            lastBeep = now
            beepPlayer.scheduleBuffer(beepBuffer, at: nil)
            if !beepPlayer.isPlaying { beepPlayer.play() }
        }
    }

    private func buffer(seconds: Double) -> AVAudioPCMBuffer? {
        let frames = AVAudioFrameCount(seconds * sampleRate)
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        b.frameLength = frames
        return b
    }

    private func makeBeepBuffer() -> AVAudioPCMBuffer? {
        guard let b = buffer(seconds: Self.beepDuration), let data = b.floatChannelData?[0] else { return nil }
        let n = Int(b.frameLength), ramp = Int(0.005 * sampleRate)
        for i in 0..<n {
            let envelope = Float(min(1, Double(min(i, n - 1 - i)) / Double(ramp)))
            data[i] = 0.5 * envelope * Float(sin(2 * .pi * Self.beepFrequency * Double(i) / sampleRate))
        }
        return b
    }

    private func makeToneBuffer() -> AVAudioPCMBuffer? {
        // 2400 samples = exactly 100 cycles → seamless loop.
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400),
              let data = b.floatChannelData?[0] else { return nil }
        b.frameLength = 2400
        for i in 0..<2400 {
            data[i] = 0.5 * Float(sin(2 * .pi * Self.beepFrequency * Double(i) / sampleRate))
        }
        return b
    }

    /// Shotgun blast: a sharp noise crack, a low muzzle boom with falling pitch and a decaying,
    /// muffled echo tail.
    private func makeShotBuffer() -> AVAudioPCMBuffer? {
        guard let b = buffer(seconds: 1.4), let data = b.floatChannelData?[0] else { return nil }
        let n = Int(b.frameLength)
        var lowBoom = 0.0, lowTail = 0.0, phase = 0.0, peak = 0.0
        var samples = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sampleRate
            let noise = Double.random(in: -1...1)
            lowBoom += 0.06 * (noise - lowBoom)              // one-pole low-pass ≈ 400 Hz
            lowTail += 0.02 * (noise - lowTail)              // ≈ 140 Hz
            let freq = 45 + 55 * exp(-t / 0.05)              // thump falling from 100 Hz to 45 Hz
            phase += 2 * .pi * freq / sampleRate
            let attack = min(1, t / 0.0015)
            let crack = noise * exp(-t / 0.010)
            let boom = 5.0 * lowBoom * exp(-t / 0.16)
            let thump = 0.9 * sin(phase) * exp(-t / 0.09)
            let tail = 7.0 * lowTail * exp(-t / 0.45)
            let s = attack * (crack + boom + thump + tail)
            samples[i] = s
            peak = max(peak, abs(s))
        }
        let gain = peak > 0 ? 0.95 / peak : 1
        for i in 0..<n { data[i] = Float(tanh(samples[i] * gain * 1.4) / tanh(1.4)) }   // soft clip = punch
        return b
    }
}
