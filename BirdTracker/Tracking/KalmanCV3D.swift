import simd

/// 3D constant-velocity Kalman filter. State = position (3) + velocity (3).
/// The 6×6 covariance is kept as four 3×3 blocks so plain simd types suffice:
///     P = | Ppp  Ppv |
///         | Pvp  Pvv |     (Pvp = Ppvᵀ)
struct KalmanCV3D {
    private(set) var position = SIMD3<Double>.zero
    private(set) var velocity = SIMD3<Double>.zero
    private(set) var isInitialized = false

    /// White-noise acceleration spectral density, (m/s²)²·s. Birds manoeuvre hard.
    var accelerationNoise: Double = 16

    private var ppp = matrix_identity_double3x3
    private var ppv = simd_double3x3()
    private var pvv = matrix_identity_double3x3
    private var lastTime: Double = 0

    /// Velocity covariance, (m/s)².
    var velocityCovariance: simd_double3x3 { pvv }

    /// 1-sigma speed uncertainty (m/s).
    var speedSigma: Double { sqrt(max(0, pvv[0, 0] + pvv[1, 1] + pvv[2, 2])) }

    mutating func update(measurement z: SIMD3<Double>, covariance r: simd_double3x3, time t: Double) {
        guard isInitialized else {
            position = z
            velocity = .zero
            ppp = r
            ppv = simd_double3x3()
            pvv = simd_double3x3(diagonal: SIMD3(repeating: 20 * 20))   // birds rarely exceed ~20 m/s
            lastTime = t
            isInitialized = true
            return
        }

        let dt = min(max(t - lastTime, 1e-3), 1.0)
        lastTime = t

        // Predict
        let q = accelerationNoise
        let i3 = matrix_identity_double3x3
        position += velocity * dt
        let newPpp = ppp + dt * (ppv + ppv.transpose) + (dt * dt) * pvv + (q * dt * dt * dt / 3) * i3
        let newPpv = ppv + dt * pvv + (q * dt * dt / 2) * i3
        let newPvv = pvv + (q * dt) * i3
        ppp = newPpp; ppv = newPpv; pvv = newPvv

        // Update (H = [I 0])
        let sInv = (ppp + r).inverse
        let kp = ppp * sInv
        let kv = ppv.transpose * sInv
        let innovation = z - position
        position += kp * innovation
        velocity += kv * innovation

        let oldPpp = ppp, oldPpv = ppv
        ppp = oldPpp - kp * oldPpp
        ppv = oldPpv - kp * oldPpv
        pvv = pvv - kv * oldPpv

        // Keep symmetric against numerical drift.
        ppp = 0.5 * (ppp + ppp.transpose)
        pvv = 0.5 * (pvv + pvv.transpose)
    }
}
