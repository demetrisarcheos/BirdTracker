import CoreMotion
import Foundation
import simd

/// Provides the phone's orientation as a rotation from the device frame to a world frame
/// whose axes are: x = magnetic north, y = west, z = up.
///
/// Because the app converts every bird position into this world frame, panning the phone
/// to follow a bird does not show up as bird motion.
final class MotionProvider {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var _deviceToWorld: simd_double3x3?
    /// nil = not decided yet; true = CMAttitude.rotationMatrix maps world -> device.
    private var matrixIsWorldToDevice: Bool?

    private(set) var hasCompass = false

    var deviceToWorld: simd_double3x3? {
        lock.lock(); defer { lock.unlock() }
        return _deviceToWorld
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.showsDeviceMovementDisplay = true   // lets iOS prompt for compass calibration

        let frames = CMMotionManager.availableAttitudeReferenceFrames()
        let frame: CMAttitudeReferenceFrame =
            frames.contains(.xMagneticNorthZVertical) ? .xMagneticNorthZVertical : .xArbitraryCorrectedZVertical
        hasCompass = (frame == .xMagneticNorthZVertical)

        queue.maxConcurrentOperationCount = 1
        manager.startDeviceMotionUpdates(using: frame, to: queue) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.handle(motion)
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    private func handle(_ motion: CMDeviceMotion) {
        let m = motion.attitude.rotationMatrix
        let r = simd_double3x3(rows: [
            SIMD3(m.m11, m.m12, m.m13),
            SIMD3(m.m21, m.m22, m.m23),
            SIMD3(m.m31, m.m32, m.m33),
        ])

        // Self-check of the matrix convention against measured gravity (device frame),
        // so a transpose mistake can never silently flip directions.
        if matrixIsWorldToDevice == nil {
            let up = -SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
            let upIfWorldToDevice = r * SIMD3<Double>(0, 0, 1)
            let upIfDeviceToWorld = r.transpose * SIMD3<Double>(0, 0, 1)
            let a = simd_dot(simd_normalize(up), upIfWorldToDevice)
            let b = simd_dot(simd_normalize(up), upIfDeviceToWorld)
            if abs(a - b) > 0.5 { matrixIsWorldToDevice = a > b }   // decisive only when phone is tilted
        }
        let worldToDevice = matrixIsWorldToDevice ?? true
        let d2w = worldToDevice ? r.transpose : r

        lock.lock()
        _deviceToWorld = d2w
        lock.unlock()
    }
}
