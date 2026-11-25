import Foundation

/// Pellet material. Density sets pellet mass (and so how well it keeps its speed and energy).
enum PelletMaterial: String, Codable, CaseIterable, Identifiable {
    case lead, steel, bismuth, tungsten

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lead:     return "Lead"
        case .steel:    return "Steel"
        case .bismuth:  return "Bismuth"
        case .tungsten: return "Tungsten"
        }
    }

    /// kg/m³ (hardened lead with antimony ≈ 11 000).
    var density: Double {
        switch self {
        case .lead:     return 11_000
        case .steel:    return 7_850
        case .bismuth:  return 9_600
        case .tungsten: return 15_000
        }
    }

    /// Hard pellets don't deform in the barrel, so they pattern tighter
    /// (steel ≈ one choke step tighter than lead).
    var patternBonus: Double {
        switch self {
        case .steel:    return 0.05
        case .tungsten: return 0.03
        default:        return 0
        }
    }
}

/// Shot sizes on the Italian / continental scale (0.25 mm steps), used by most cartridges
/// sold in Cyprus. Boxes usually print the diameter in mm too, which always wins.
enum ShotScale {
    static let sizes: [(number: String, mm: Double)] = [
        ("1", 4.0), ("2", 3.75), ("3", 3.5), ("4", 3.25), ("5", 3.0), ("6", 2.75), ("7", 2.5),
        ("7½", 2.4), ("8", 2.25), ("9", 2.0), ("10", 1.75), ("11", 1.5), ("12", 1.25),
    ]
    static var numbers: [String] { sizes.map(\.number) }

    static func mm(for number: String) -> Double? {
        sizes.first { $0.number == number }?.mm
    }

    /// Closest shot number for a diameter.
    static func number(for mm: Double) -> String {
        sizes.min { abs($0.mm - mm) < abs($1.mm - mm) }?.number ?? "7"
    }
}

/// Time of flight and remaining speed of one pellet versus distance, by numerical integration
/// of a sphere's drag:  dv/dt = −ρ_air · Cd(Mach) · A · v² / (2m).
/// Cd follows the standard sphere drag curve: ≈0.47 subsonic, rising through the sound
/// barrier to ≈0.95 (shot leaves the barrel at Mach 1.1–1.3).
struct BallisticsTable {
    private var distance: [Double] = []
    private var time: [Double] = []
    private var speed: [Double] = []

    static let airDensity = 1.2        // kg/m³ (≈20 °C, sea level)
    static let speedOfSound = 343.0    // m/s

    /// - Parameters:
    ///   - velocity: pellet speed measured `refDistance` metres from the muzzle (as printed on the box).
    init(velocity: Double, measuredAt refDistance: Double, pelletDiameterMM: Double, density: Double) {
        let d = max(pelletDiameterMM, 0.5) / 1000
        let mass = density * .pi / 6 * d * d * d
        let area = .pi * d * d / 4
        let k = Self.airDensity * area / (2 * mass)
        let v0 = max(velocity, 100)

        var x = max(refDistance, 0), v = v0, t = x / v0
        distance = [0]; time = [0]; speed = [v0]
        if x > 0 { distance.append(x); time.append(t); speed.append(v) }

        let dt = 0.0002
        var step = 0
        while x < 200 && v > 40 && t < 3 {
            v -= k * Self.dragCoefficient(mach: v / Self.speedOfSound) * v * v * dt
            x += v * dt
            t += dt
            step += 1
            if step % 5 == 0 { distance.append(x); time.append(t); speed.append(v) }   // ~1 ms resolution
        }
    }

    static func dragCoefficient(mach m: Double) -> Double {
        let curve: [(Double, Double)] = [(0, 0.47), (0.6, 0.47), (0.8, 0.52), (0.9, 0.62),
                                         (1.0, 0.80), (1.1, 0.90), (1.2, 0.95), (1.5, 0.95), (2.0, 0.92)]
        if m <= curve[0].0 { return curve[0].1 }
        for i in 1..<curve.count where m <= curve[i].0 {
            let (m0, c0) = curve[i - 1], (m1, c1) = curve[i]
            return c0 + (c1 - c0) * (m - m0) / (m1 - m0)
        }
        return curve[curve.count - 1].1
    }

    /// Time of flight (s) and pellet speed (m/s) at a distance.
    func at(_ x: Double) -> (time: Double, speed: Double) {
        guard let lastX = distance.last, x < lastX else {
            let v = max(speed.last ?? 40, 40)
            return ((time.last ?? 0) + (x - (distance.last ?? 0)) / v, v)
        }
        var lo = 0, hi = distance.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if distance[mid] <= x { lo = mid } else { hi = mid }
        }
        let span = distance[hi] - distance[lo]
        let f = span > 0 ? (x - distance[lo]) / span : 0
        return (time[lo] + f * (time[hi] - time[lo]), speed[lo] + f * (speed[hi] - speed[lo]))
    }
}

/// Everything the aiming maths needs about the current gun + cartridge (+ which barrel fires next).
struct Loadout {
    let gun: GunSetup
    let cartridge: Cartridge
    let barrel: Int                 // 1 or 2
    let constrictionMM: Double
    let pelletMass: Double          // kg
    let pelletCount: Double
    let table: BallisticsTable
    /// Pattern spread: σ of the (approximately Gaussian) pellet cloud, σ(r) = σ0 + growth · r.
    let sigmaAtMuzzle = 0.012
    let sigmaGrowth: Double

    init(gun: GunSetup, cartridge: Cartridge, barrel: Int = 1) {
        self.gun = gun
        self.cartridge = cartridge
        let b = gun.action.isDouble ? min(max(barrel, 1), 2) : 1
        self.barrel = b
        constrictionMM = b == 2 ? gun.choke2MM : gun.choke1MM

        let d = cartridge.pelletMM / 1000
        let mass = cartridge.material.density * .pi / 6 * d * d * d
        pelletMass = mass
        pelletCount = max(1, cartridge.loadGrams / 1000 / mass)

        // Box speeds are measured in a 76 cm test barrel; about 0.5 m/s per cm of difference.
        let velocity = cartridge.velocity + 0.5 * (gun.barrelCM - 76)
        table = BallisticsTable(velocity: velocity, measuredAt: cartridge.velocityDistance,
                                pelletDiameterMM: cartridge.pelletMM, density: cartridge.material.density)

        // Choke → share of pellets inside a 76.2 cm (30 inch) circle at 36.6 m (40 yd), the standard
        // patterning test. A Gaussian cloud with that share has σ = R / √(−2 ln(1 − p)).
        let p = min(0.85, Self.patternPercent(constrictionMM: constrictionMM) + cartridge.material.patternBonus)
        let sigma40 = 0.381 / (-2 * log(1 - p)).squareRoot()
        sigmaGrowth = (sigma40 - 0.012) / 36.58
    }

    static let `default` = Loadout(gun: GunSetup(), cartridge: Cartridge.presets[1])

    /// Pattern percentage at 40 yd for a constriction (Cyl 40 %, IC 50 %, Mod 60 %, IM 65 %, Full 70 %).
    static func patternPercent(constrictionMM c: Double) -> Double {
        let table: [(Double, Double)] = [(0, 0.40), (0.125, 0.45), (0.25, 0.50), (0.5, 0.60),
                                         (0.75, 0.65), (1.0, 0.70), (1.25, 0.74), (1.5, 0.76)]
        if c <= 0 { return table[0].1 }
        for i in 1..<table.count where c <= table[i].0 {
            let (c0, p0) = table[i - 1], (c1, p1) = table[i]
            return p0 + (p1 - p0) * (c - c0) / (c1 - c0)
        }
        return table[table.count - 1].1
    }

    func sigma(at range: Double) -> Double { sigmaAtMuzzle + sigmaGrowth * max(range, 0) }

    /// Diameter of the circle holding 75 % of the pellets at a range (2 · σ · √(2 ln 4)).
    func patternDiameter(at range: Double) -> Double { 2 * 1.665 * sigma(at: range) }

    func impact(at range: Double) -> (time: Double, speed: Double, energy: Double) {
        let r = table.at(range)
        return (r.time, r.speed, 0.5 * pelletMass * r.speed * r.speed)
    }

    var summary: String {
        var s = "\(cartridge.shortTitle) · \(ChokeSystem.name(forMM: constrictionMM))"
        if gun.action.isDouble { s += " (barrel \(barrel))" }
        return s
    }
}

/// How many pellets it takes, and how hard they must hit, for a clean kill.
enum KillModel {
    /// Clean kill = at least 2 pellets with enough energy in the vital area. P(≥2) for a Poisson count.
    static func killProbability(_ lambda: Double) -> Double { 1 - exp(-lambda) * (1 + lambda) }
    /// SHOOT is shown when a shot fired now would kill with at least this probability.
    static let shootThreshold = 0.80
    /// λ at which killProbability == shootThreshold.
    static let lambdaForThreshold = 2.994

    /// Side-on area of the bird's body (m²), scaled from wingspan (≈0.03 m² for a wood pigeon).
    static func bodyArea(wingspan: Double) -> Double { 0.055 * wingspan * wingspan }
    static func vitalArea(wingspan: Double) -> Double { 0.4 * bodyArea(wingspan: wingspan) }

    /// Minimum energy per pellet for a clean kill (J), growing with bird size:
    /// ≈0.35 J thrush/skylark, ≈0.55 J partridge, ≈0.9 J wood pigeon, ≈1.25 J crow.
    static func minEnergy(wingspan: Double) -> Double { min(2.5, max(0.3, 1.3 * pow(wingspan, 1.3))) }

    /// Share of pellets that still kill: 0 below 60 % of the needed energy, 1 above it.
    static func energyFactor(energy: Double, needed: Double) -> Double {
        min(1, max(0, (energy / needed - 0.6) / 0.4))
    }

    /// Random count from a Poisson distribution (for simulating where the pellets went).
    static func poisson(_ lambda: Double) -> Int {
        guard lambda > 0 else { return 0 }
        if lambda > 40 {
            let u1 = Double.random(in: Double.ulpOfOne..<1), u2 = Double.random(in: 0..<1)
            let z = (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
            return max(0, Int((lambda + z * lambda.squareRoot()).rounded()))
        }
        let limit = exp(-lambda)
        var k = 0, p = 1.0
        repeat { k += 1; p *= Double.random(in: 0..<1) } while p > limit
        return k - 1
    }
}
