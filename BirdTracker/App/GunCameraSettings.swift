import CoreGraphics
import Foundation
import simd

/// Where the video (and the aiming direction) comes from.
enum CameraSource: String, CaseIterable, Identifiable {
    case phone
    case gunCamera

    var id: String { rawValue }
    var title: String {
        switch self {
        case .phone:     return "Phone camera"
        case .gunCamera: return "GoPro on the gun"
        }
    }
}

/// How the WitMotion sensor is strapped to the gun. Axes refer to the X/Y/Z drawing printed on the sensor.
enum SensorMount: String, CaseIterable, Identifiable {
    case topLabelUp, underLabelDown, sideLabelRight, sideLabelLeft

    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLabelUp:     return "On top, flat"
        case .underLabelDown: return "Underneath, upside down"
        case .sideLabelRight: return "On the right side"
        case .sideLabelLeft:  return "On the left side"
        }
    }

    /// The sensor's X, Y, Z axes expressed in the gun frame (x = right, y = down, z = towards the muzzle).
    /// In every option the sensor's X arrow points towards the muzzle.
    var sensorToGun: simd_double3x3 {
        switch self {
        case .topLabelUp:     // Z up, Y left
            return simd_double3x3(columns: (SIMD3(0, 0, 1), SIMD3(-1, 0, 0), SIMD3(0, -1, 0)))
        case .underLabelDown: // Z down, Y right
            return simd_double3x3(columns: (SIMD3(0, 0, 1), SIMD3(1, 0, 0), SIMD3(0, 1, 0)))
        case .sideLabelRight: // Z right, Y up
            return simd_double3x3(columns: (SIMD3(0, 0, 1), SIMD3(0, -1, 0), SIMD3(1, 0, 0)))
        case .sideLabelLeft:  // Z left, Y down
            return simd_double3x3(columns: (SIMD3(0, 0, 1), SIMD3(0, 1, 0), SIMD3(-1, 0, 0)))
        }
    }
}

extension AppSettings {
    static let cameraSourceKey = "cameraSource"
    /// GoPro horizontal field of view in degrees (Linear lens ≈ 86°).
    static let goproFOVKey = "goproFOV"
    /// Seconds between the GoPro seeing something and the frame reaching the app.
    static let goproLatencyKey = "goproLatency"
    static let cameraUpsideDownKey = "cameraUpsideDown"
    /// Where the barrel points in the GoPro image (normalised, upright image, origin top-left).
    static let boresightXKey = "boresightX"
    static let boresightYKey = "boresightY"
    static let sensorMountKey = "sensorMount"
    static let sensorIDKey = "gunSensorID"
    /// Degrees added so the gun's heading matches north.
    static let headingOffsetKey = "headingOffset"
    static let recoilTriggerKey = "recoilTrigger"
    static let recoilThresholdKey = "recoilThresholdG"

    static let gunCameraDefaults: [String: Any] = [
        cameraSourceKey: CameraSource.phone.rawValue,
        goproFOVKey: 86.0,
        goproLatencyKey: 0.25,
        cameraUpsideDownKey: false,
        boresightXKey: 0.5,
        boresightYKey: 0.5,
        sensorMountKey: SensorMount.topLabelUp.rawValue,
        headingOffsetKey: 0.0,
        recoilTriggerKey: true,
        recoilThresholdKey: 6.0,
    ]

    static var boresight: CGPoint {
        let d = UserDefaults.standard
        return CGPoint(x: d.double(forKey: boresightXKey), y: d.double(forKey: boresightYKey))
    }
}

enum Rotation {
    static func x(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, c, -s), SIMD3(0, s, c)])
    }
    static func y(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(rows: [SIMD3(c, 0, s), SIMD3(0, 1, 0), SIMD3(-s, 0, c)])
    }
    static func z(_ a: Double) -> simd_double3x3 {
        let c = cos(a), s = sin(a)
        return simd_double3x3(rows: [SIMD3(c, -s, 0), SIMD3(s, c, 0), SIMD3(0, 0, 1)])
    }
}

/// Gun camera orientation from the gun sensor.
/// World frame as everywhere in the app: x = north, y = west, z = up.
enum GunOrientation {
    static func cameraToWorld(sensorToWorld r: simd_double3x3) -> simd_double3x3 {
        let d = UserDefaults.standard
        let mount = SensorMount(rawValue: d.string(forKey: AppSettings.sensorMountKey) ?? "") ?? .topLabelUp
        let heading = d.double(forKey: AppSettings.headingOffsetKey) * .pi / 180
        return Rotation.z(heading) * r * mount.sensorToGun.transpose
    }

    /// Barrel elevation, degrees (+ = up).
    static func elevation(_ c: simd_double3x3) -> Double {
        asin(max(-1, min(1, (c * SIMD3(0, 0, 1)).z))) * 180 / .pi
    }

    /// Sideways tilt, degrees (+ = right side down).
    static func cant(_ c: simd_double3x3) -> Double {
        asin(max(-1, min(1, -(c * SIMD3(1, 0, 0)).z))) * 180 / .pi
    }

    /// Where the barrel points, degrees clockwise from north.
    static func heading(_ c: simd_double3x3) -> Double {
        let f = c * SIMD3(0, 0, 1)
        var deg = atan2(-f.y, f.x) * 180 / .pi
        if deg < 0 { deg += 360 }
        return deg
    }
}
