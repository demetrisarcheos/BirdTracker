import CoreGraphics
import Foundation
import simd

/// What the UI shows for one tracked bird.
struct BirdReadout: Identifiable, Equatable {
    let id: Int
    /// Normalised rect in the upright image (origin top-left).
    let rect: CGRect
    let confidence: Float
    /// Straight-line distance from the phone, metres.
    let distance: Double
    /// Height above the phone, metres (+ = above).
    let heightAboveCamera: Double
    /// Total 3D speed, m/s (nil until the track is old enough).
    let speed: Double?
    /// Flight direction, degrees clockwise from north (nil if hovering / not yet known).
    let bearing: Double?
    /// m/s, + = climbing.
    let verticalSpeed: Double?
    /// m/s, + = moving away from you, − = approaching.
    let radialSpeed: Double?
    /// Best species guess (display name) and its averaged confidence, if any.
    let species: String?
    let speciesConfidence: Float?
    /// Wingspan used for the distance maths, and whether it came from the species.
    let wingspan: Double
    let wingspanFromSpecies: Bool
}

/// Associates detections across frames, runs a 3D Kalman filter per bird and
/// accumulates species guesses per bird.
final class MultiBirdTracker {
    private final class Track {
        let id: Int
        let firstSeen: Double
        var lastSeen: Double
        var motionStart: Double             // reset when the wingspan (distance scale) changes
        var rect: CGRect
        var confidence: Float
        var hits = 0
        var sizeHistory: [Double] = []
        var filter = KalmanCV3D()
        var wingspanInUse: Double?
        var lastClassified = -Double.infinity
        var speciesHistory: [[String: Float]] = []

        init(id: Int, rect: CGRect, confidence: Float, time: Double) {
            self.id = id
            self.rect = rect
            self.confidence = confidence
            firstSeen = time
            lastSeen = time
            motionStart = time
        }

        /// Species with the highest probability averaged over recent classifications.
        var bestSpecies: (label: String, confidence: Float)? {
            guard !speciesHistory.isEmpty else { return nil }
            var sums: [String: Float] = [:]
            for result in speciesHistory {
                for (label, p) in result { sums[label, default: 0] += p }
            }
            guard let best = sums.max(by: { $0.value < $1.value }) else { return nil }
            return (best.key, best.value / Float(speciesHistory.count))
        }
    }

    var maxCoastTime = 0.7          // s without detections before a track is dropped
    var minAgeForMotion = 0.4       // s of tracking before speed/direction are shown
    var sizeWindow = 15             // frames used for the median apparent size
    var pixelNoise = 4.0            // px, centre jitter
    var relativeDepthNoise = 0.20   // 20 % frame-to-frame size jitter (wing flapping)

    var classifyInterval = 0.2      // s between species classifications of one bird (~5/s)
    var minClassifySizePx = 32.0    // smaller birds are too blurry to identify
    var speciesHistoryLength = 6     // ~1.2 s of guesses averaged
    var showSpeciesAbove: Float = 0.50  // shown from the very first guess
    var useSpeciesSizeAbove: Float = 0.60

    private var tracks: [Track] = []
    private var nextID = 1

    func reset() { tracks.removeAll() }

    func update(detections: [Detection], time: Double, geometry: CameraGeometry,
                presetSizeMeters: Double, useSpeciesSize: Bool) -> [BirdReadout] {
        let w = Double(geometry.imageSize.width), h = Double(geometry.imageSize.height)

        // Greedy association by centre distance (in pixels), gated by box size.
        var candidates: [(track: Int, det: Int, cost: Double)] = []
        for (ti, track) in tracks.enumerated() {
            for (di, det) in detections.enumerated() {
                let dx = (Double(track.rect.midX) - Double(det.rect.midX)) * w
                let dy = (Double(track.rect.midY) - Double(det.rect.midY)) * h
                let scale = max(Double(track.rect.width) * w, Double(track.rect.height) * h,
                                Double(det.rect.width) * w, Double(det.rect.height) * h, 20)
                let cost = hypot(dx, dy) / (2.0 * scale)
                if cost < 1 { candidates.append((ti, di, cost)) }
            }
        }
        candidates.sort { $0.cost < $1.cost }

        var usedTracks = Set<Int>()
        var usedDetections = Set<Int>()
        for c in candidates where !usedTracks.contains(c.track) && !usedDetections.contains(c.det) {
            usedTracks.insert(c.track)
            usedDetections.insert(c.det)
            apply(detections[c.det], to: tracks[c.track], time: time, geometry: geometry,
                  presetSize: presetSizeMeters, useSpeciesSize: useSpeciesSize)
        }

        for (di, det) in detections.enumerated() where !usedDetections.contains(di) {
            let track = Track(id: nextID, rect: det.rect, confidence: det.confidence, time: time)
            nextID += 1
            apply(det, to: track, time: time, geometry: geometry,
                  presetSize: presetSizeMeters, useSpeciesSize: useSpeciesSize)
            tracks.append(track)
        }

        tracks.removeAll { time - $0.lastSeen > maxCoastTime }

        return tracks
            .filter { $0.hits >= 3 && time - $0.lastSeen < 0.25 && $0.filter.isInitialized }
            .map { readout(for: $0, time: time, presetSize: presetSizeMeters) }
    }

    // MARK: - Species

    /// Birds visible in this frame that are due for (re-)classification, most overdue first.
    func classificationCandidates(time: Double, imageSize: CGSize, limit: Int) -> [(id: Int, rect: CGRect)] {
        let w = Double(imageSize.width), h = Double(imageSize.height)
        return tracks
            .filter { t in
                t.lastSeen == time
                    && time - t.lastClassified >= classifyInterval
                    && max(Double(t.rect.width) * w, Double(t.rect.height) * h) >= minClassifySizePx
            }
            .sorted { $0.lastClassified < $1.lastClassified }
            .prefix(limit)
            .map { ($0.id, $0.rect) }
    }

    func addSpeciesGuesses(_ guesses: [SpeciesClassifier.Guess], toTrack id: Int, time: Double) {
        guard let track = tracks.first(where: { $0.id == id }) else { return }
        track.lastClassified = time
        guard !guesses.isEmpty else { return }
        var result: [String: Float] = [:]
        for g in guesses { result[g.label] = g.confidence }
        track.speciesHistory.append(result)
        if track.speciesHistory.count > speciesHistoryLength { track.speciesHistory.removeFirst() }
    }

    /// Wingspan from a confidently identified species, if known.
    private func speciesWingspan(of track: Track) -> Double? {
        guard track.speciesHistory.count >= 2,
              let best = track.bestSpecies, best.confidence >= useSpeciesSizeAbove else { return nil }
        return SpeciesWingspan.meters(for: best.label)
    }

    // MARK: - Measurement update

    private func apply(_ det: Detection, to track: Track, time: Double, geometry: CameraGeometry,
                       presetSize: Double, useSpeciesSize: Bool) {
        track.rect = det.rect
        track.confidence = det.confidence
        track.lastSeen = time
        track.hits += 1

        let w = Double(geometry.imageSize.width), h = Double(geometry.imageSize.height)
        let sizePx = max(Double(det.rect.width) * w, Double(det.rect.height) * h)

        // A box cut off by the frame edge under-reports the bird's size.
        let r = det.rect
        let clipped = r.minX < 0.01 || r.minY < 0.01 || r.maxX > 0.99 || r.maxY > 0.99
        if !clipped || track.sizeHistory.isEmpty {
            track.sizeHistory.append(sizePx)
            if track.sizeHistory.count > sizeWindow { track.sizeHistory.removeFirst() }
        }

        // Median size smooths out wing-beat changes of the bounding box.
        let medianSize = track.sizeHistory.sorted()[track.sizeHistory.count / 2]
        guard medianSize > 3 else { return }

        // Changing the assumed wingspan rescales every position; restart the filter so the
        // jump is not mistaken for motion.
        let wingspan = (useSpeciesSize ? speciesWingspan(of: track) : nil) ?? presetSize
        if let current = track.wingspanInUse, abs(current - wingspan) > 0.01 * current {
            track.filter = KalmanCV3D()
            track.motionStart = time
        }
        track.wingspanInUse = wingspan

        let depth = geometry.depth(realSizeMeters: wingspan, sizePixels: medianSize)
        let centre = CGPoint(x: r.midX * CGFloat(w), y: r.midY * CGFloat(h))
        let pointCamera = geometry.ray(throughPixel: centre) * depth

        let toWorld = geometry.cameraToWorld
        let pointWorld = toWorld * pointCamera

        // Measurement noise: precise across the image, poor along the viewing ray.
        let lateral = max(0.05, depth * pixelNoise / geometry.focalPx)
        let along = max(0.2, depth * relativeDepthNoise)
        let rCamera = simd_double3x3(diagonal: SIMD3(lateral * lateral, lateral * lateral, along * along))
        let rWorld = toWorld * rCamera * toWorld.transpose

        track.filter.update(measurement: pointWorld, covariance: rWorld, time: time)
    }

    private func readout(for track: Track, time: Double, presetSize: Double) -> BirdReadout {
        let p = track.filter.position
        let v = track.filter.velocity
        let distance = simd_length(p)

        var speed: Double?, bearing: Double?, vertical: Double?, radial: Double?
        if time - track.motionStart >= minAgeForMotion {
            speed = simd_length(v)
            vertical = v.z
            radial = distance > 0 ? simd_dot(v, p) / distance : 0
            let horizontal = hypot(v.x, v.y)
            if horizontal > 0.7 {
                // World x = north, y = west  →  east = −y
                var deg = atan2(-v.y, v.x) * 180 / .pi
                if deg < 0 { deg += 360 }
                bearing = deg
            }
        }

        var species: String?, speciesConfidence: Float?
        if let best = track.bestSpecies, best.confidence >= showSpeciesAbove {
            species = SpeciesWingspan.displayName(best.label)
            speciesConfidence = best.confidence
        }
        let wingspan = track.wingspanInUse ?? presetSize

        return BirdReadout(id: track.id, rect: track.rect, confidence: track.confidence,
                           distance: distance, heightAboveCamera: p.z,
                           speed: speed, bearing: bearing,
                           verticalSpeed: vertical, radialSpeed: radial,
                           species: species, speciesConfidence: speciesConfidence,
                           wingspan: wingspan,
                           wingspanFromSpecies: abs(wingspan - presetSize) > 1e-6)
    }
}
