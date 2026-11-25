import Foundation
import CoreGraphics
import simd

/// Where to aim so a simulated shotgun shot meets a moving bird.
struct LeadSolution: Equatable {
    /// Aiming point in the upright image (normalised, origin top-left). The reticle is (0.5, 0.5).
    let aimPoint: CGPoint
    /// Distance between the bird now and the aiming point, metres (includes pellet drop).
    let leadMeters: Double
    /// Time the shot needs to reach the meeting point, seconds.
    let flightTime: Double
    /// Distance by which a shot fired *now* (along the reticle) would miss the meeting point, metres.
    let missMeters: Double
    /// A shot is a hit when missMeters ≤ this: core of the shot pattern + half the bird.
    let toleranceMeters: Double
    /// Where the shot would pass relative to the aiming point, metres on the target plane
    /// (+right / +up as seen on the screen).
    let shotOffsetRight: Double
    let shotOffsetUp: Double
    /// The bird's direction of motion on the screen (unit vector, +right / +up), nil if (almost) still.
    let screenMotion: SIMD2<Double>?
    /// False until the bird's speed is known (first ~0.4 s of tracking).
    let ready: Bool

    /// 0 = dead on, 1 = edge of a hit, larger = further away.
    var hitRatio: Double { missMeters / max(toleranceMeters, 0.01) }
    var isHit: Bool { ready && hitRatio <= 1 }
}

/// Simplified shotgun exterior ballistics (simulation only).
///
/// • Pellet speed decays exponentially with distance: v(x) = v0 · e^(−x/L)
///   → flight time t(d) = L/v0 · (e^(d/L) − 1). With v0 = 390 m/s, L = 60 m: ~0.03 s at 10 m,
///   ~0.10 s at 30 m, ~0.15 s at 40 m — close to real game loads.
/// • Meeting point = bird position + velocity · t, iterated because t depends on that distance.
/// • Pellet drop ½ g t² is added by aiming that much higher.
/// • Pattern radius grows linearly with range (set by the choke); the dense core
///   (75 % of the radius) plus half the bird's wingspan counts as a hit.
enum LeadSolver {
    static let muzzleVelocity = 390.0      // m/s
    static let velocityDecayLength = 60.0  // m
    static let patternRadiusAtMuzzle = 0.02
    static let coreFraction = 0.75
    static let stillBelowSpeed = 1.0       // m/s: slower than this counts as perched (no lead)

    static func flightTime(distance d: Double) -> Double {
        velocityDecayLength / muzzleVelocity * (exp(min(d, 250) / velocityDecayLength) - 1)
    }

    /// - Parameters:
    ///   - position: bird position relative to the phone, world frame, metres.
    ///   - velocity: bird velocity, world frame, m/s; nil while it is not known yet.
    ///   - patternGrowth: pattern radius growth per metre of range (see `Choke`).
    static func solve(position p: SIMD3<Double>, velocity: SIMD3<Double>?, geometry: CameraGeometry,
                      wingspan: Double, patternGrowth: Double) -> LeadSolution? {
        var v = velocity ?? .zero
        if simd_length(v) < stillBelowSpeed { v = .zero }

        var t = flightTime(distance: simd_length(p))
        var meet = p
        for _ in 0..<4 {
            meet = p + v * t
            t = flightTime(distance: simd_length(meet))
        }
        let drop = 0.5 * 9.81 * t * t
        let aimWorld = meet + SIMD3(0, 0, drop)

        let worldToCamera = geometry.cameraToWorld.transpose
        let a = worldToCamera * aimWorld          // camera: x right, y down, z forward
        guard a.z > 0.5 else { return nil }       // behind / beside the phone

        let w = Double(geometry.imageSize.width), h = Double(geometry.imageSize.height)
        let px = geometry.focalPx * a.x / a.z + w / 2
        let py = geometry.focalPx * a.y / a.z + h / 2

        // The shot travels along the optical axis (the reticle). Its closest approach to the
        // aiming point is the perpendicular distance from that point to the axis.
        let miss = hypot(a.x, a.y)
        let range = simd_length(aimWorld)
        let tolerance = coreFraction * (patternRadiusAtMuzzle + patternGrowth * range) + 0.25 * wingspan

        let vc = worldToCamera * v
        let screen = SIMD2(vc.x, -vc.y)
        let motion = simd_length(screen) > 0.3 ? simd_normalize(screen) : nil

        return LeadSolution(aimPoint: CGPoint(x: px / w, y: py / h),
                            leadMeters: simd_length(aimWorld - p),
                            flightTime: t,
                            missMeters: miss,
                            toleranceMeters: tolerance,
                            shotOffsetRight: -a.x,
                            shotOffsetUp: a.y,
                            screenMotion: motion,
                            ready: velocity != nil)
    }
}
