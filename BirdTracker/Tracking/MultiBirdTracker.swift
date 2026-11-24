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
}

/// Associates detections across frames and runs a 3D Kalman filter per bird.
final class MultiBirdTracker {
    private final class Track {
        let id: Int
        let firstSeen: Double
        var lastSeen: Double
        var rect: CGRect
        var confidence: Float
        var hits = 0
        var sizeHistory: [Double] = []
        var filter = KalmanCV3D()

        init(id: Int, rect: CGRect, confidence: Float, time: Double) {
            self.id = id
            self.rect = rect
            self.confidence = confidence
            firstSeen = time
            lastSeen = time
        }
    }

    var maxCoastTime = 0.7          // s without detections before a track is dropped
    var minAgeForMotion = 0.4       // s of tracking before speed/direction are shown
    var sizeWindow = 15             // frames used for the median apparent size
    var pixelNoise = 4.0            // px, centre jitter
    var relativeDepthNoise = 0.20   // 20 % frame-to-frame size jitter (wing flapping)

    private var tracks: [Track] = []
    private var nextID = 1

    func reset() { tracks.removeAll() }

    func update(detections: [Detection], time: Double,
                geometry: CameraGeometry, birdSizeMeters: Double) -> [BirdReadout] {
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
            apply(detections[c.det], to: tracks[c.track], time: time, geometry: geometry, birdSize: birdSizeMeters)
        }

        for (di, det) in detections.enumerated() where !usedDetections.contains(di) {
            let track = Track(id: nextID, rect: det.rect, confidence: det.confidence, time: time)
            nextID += 1
            apply(det, to: track, time: time, geometry: geometry, birdSize: birdSizeMeters)
            tracks.append(track)
        }

        tracks.removeAll { time - $0.lastSeen > maxCoastTime }

        return tracks
            .filter { $0.hits >= 3 && time - $0.lastSeen < 0.25 && $0.filter.isInitialized }
            .map { readout(for: $0, time: time) }
    }

    private func apply(_ det: Detection, to track: Track, time: Double,
                       geometry: CameraGeometry, birdSize: Double) {
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

        let depth = geometry.depth(realSizeMeters: birdSize, sizePixels: medianSize)
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

    private func readout(for track: Track, time: Double) -> BirdReadout {
        let p = track.filter.position
        let v = track.filter.velocity
        let distance = simd_length(p)

        var speed: Double?, bearing: Double?, vertical: Double?, radial: Double?
        if time - track.firstSeen >= minAgeForMotion {
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

        return BirdReadout(id: track.id, rect: track.rect, confidence: track.confidence,
                           distance: distance, heightAboveCamera: p.z,
                           speed: speed, bearing: bearing,
                           verticalSpeed: vertical, radialSpeed: radial)
    }
}
