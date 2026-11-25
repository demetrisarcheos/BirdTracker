import CoreGraphics
import Foundation
import simd

/// Where to aim so a simulated shotgun shot meets a moving bird, and what a shot fired now would do.
struct LeadSolution: Equatable {
    /// Aiming point in the upright image (normalised, origin top-left). The reticle is (0.5, 0.5).
    let aimPoint: CGPoint
    /// Distance between the bird now and the aiming point, metres (includes pellet drop).
    let leadMeters: Double
    /// Range to the meeting point (m) and the shot's travel time to it (s).
    let range: Double
    let flightTime: Double
    /// Pellet speed (m/s) and energy (J) on arrival, and the energy this bird needs for a clean kill.
    let impactSpeed: Double
    let impactEnergy: Double
    let neededEnergy: Double
    /// Diameter of the circle holding 75 % of the pellets at that range, metres.
    let patternDiameter: Double
    /// Distance from the pattern centre (reticle) to the meeting point, metres.
    let missMeters: Double
    /// Largest miss that still gives ≥ 80 % chance of a clean kill (0 = out of range).
    let toleranceMeters: Double
    /// Pattern σ at that range (for ranking how well each bird is covered).
    let sigma: Double
    /// Expected pellets (if fired now) in the bird's vitals — counting only pellets with enough
    /// energy — and in its whole body.
    let expectedVitalHits: Double
    let expectedBodyHits: Double
    /// Where the shot would pass relative to the aiming point, metres on the target plane
    /// (+right / +up as seen on the screen).
    let shotOffsetRight: Double
    let shotOffsetUp: Double
    /// The bird's direction of motion on the screen (unit vector, +right / +up), nil if (almost) still.
    let screenMotion: SIMD2<Double>?
    /// False until the bird's speed is known (first ~0.4 s of tracking).
    let ready: Bool

    var killProbability: Double { KillModel.killProbability(expectedVitalHits) }
    /// Even a perfectly centred shot would not reliably kill (too few pellets or too little energy).
    var outOfRange: Bool { toleranceMeters <= 0 }
    /// 0 = dead on, 1 = edge of the kill zone, larger = further away.
    var hitRatio: Double { toleranceMeters > 0 ? missMeters / toleranceMeters : .infinity }
    /// Miss in units of the pattern's σ (used to pick the bird you are aiming at).
    var missInSigmas: Double { missMeters / max(sigma, 0.01) }
    /// A shot fired now would kill with ≥ 80 % probability.
    var isHit: Bool { ready && !outOfRange && missMeters <= toleranceMeters }
}

/// Lead and kill-probability maths (simulation).
///
/// 1. Shot travel time from the cartridge's ballistics table (pellet drag integrated numerically).
/// 2. Meeting point = bird position + velocity · t, iterated because t depends on that distance;
///    raised by the pellet drop ½ g t².
/// 3. The shot leaves along the camera's optical axis (the reticle). Its pellet cloud is treated as
///    a 2-D Gaussian whose σ grows with range according to the choke.
/// 4. Expected pellets on the bird = pellet count × pattern density at the bird × presented area;
///    a clean kill needs ≥ 2 pellets with enough energy in the vitals (Poisson).
enum LeadSolver {
    static let stillBelowSpeed = 1.0       // m/s: slower than this counts as perched (no lead)

    /// - Parameters:
    ///   - position: bird position relative to the phone, world frame, metres.
    ///   - velocity: bird velocity, world frame, m/s; nil while it is not known yet.
    static func solve(position p: SIMD3<Double>, velocity: SIMD3<Double>?, geometry: CameraGeometry,
                      wingspan: Double, loadout: Loadout) -> LeadSolution? {
        var v = velocity ?? .zero
        if simd_length(v) < stillBelowSpeed { v = .zero }

        var t = loadout.impact(at: simd_length(p)).time
        var meet = p
        for _ in 0..<4 {
            meet = p + v * t
            t = loadout.impact(at: simd_length(meet)).time
        }
        let drop = 0.5 * 9.81 * t * t
        let aimWorld = meet + SIMD3(0, 0, drop)

        let worldToCamera = geometry.cameraToWorld.transpose
        let a = worldToCamera * aimWorld          // camera: x right, y down, z forward
        guard a.z > 0.5 else { return nil }       // behind / beside the phone

        // The shot travels along the barrel axis (the optical axis for the phone camera).
        let barrel = geometry.barrelAxis
        let along = simd_dot(a, barrel)
        guard along > 0.5 else { return nil }
        let perp = a - along * barrel

        let w = Double(geometry.imageSize.width), h = Double(geometry.imageSize.height)
        let px = geometry.focalPx * a.x / a.z + w / 2
        let py = geometry.focalPx * a.y / a.z + h / 2

        // Closest approach of the pattern centre (barrel axis) to the aiming point.
        let miss = simd_length(perp)
        let range = simd_length(aimWorld)
        let impact = loadout.impact(at: range)
        let sigma = loadout.sigma(at: range)

        // Pellets per m² at the pattern centre, and how many would land on the bird.
        let centreDensity = loadout.pelletCount / (2 * .pi * sigma * sigma)
        let needed = KillModel.minEnergy(wingspan: wingspan)
        let killing = KillModel.energyFactor(energy: impact.energy, needed: needed)
        let vitalAtCentre = centreDensity * KillModel.vitalArea(wingspan: wingspan) * killing
        let falloff = exp(-miss * miss / (2 * sigma * sigma))

        let lStar = KillModel.lambdaForThreshold
        let tolerance = vitalAtCentre > lStar ? sigma * (2 * log(vitalAtCentre / lStar)).squareRoot() : 0

        let vc = worldToCamera * v
        let screen = SIMD2(vc.x, -vc.y)
        let motion = simd_length(screen) > 0.3 ? simd_normalize(screen) : nil

        return LeadSolution(aimPoint: CGPoint(x: px / w, y: py / h),
                            leadMeters: simd_length(aimWorld - p),
                            range: range,
                            flightTime: t,
                            impactSpeed: impact.speed,
                            impactEnergy: impact.energy,
                            neededEnergy: needed,
                            patternDiameter: loadout.patternDiameter(at: range),
                            missMeters: miss,
                            toleranceMeters: tolerance,
                            sigma: sigma,
                            expectedVitalHits: vitalAtCentre * falloff,
                            expectedBodyHits: centreDensity * KillModel.bodyArea(wingspan: wingspan) * falloff,
                            shotOffsetRight: -perp.x,
                            shotOffsetUp: perp.y,
                            screenMotion: motion,
                            ready: velocity != nil)
    }
}
