import CoreGraphics
import simd

/// Pinhole camera model for one frame plus the phone's orientation at that moment.
///
/// Frames used:
///  • Camera: x = right, y = down (image axes), z = forward (out of the back of the phone)
///  • Device (Core Motion, portrait): x = right, y = up, z = out of the screen
///  • World: x = magnetic north, y = west, z = up
struct CameraGeometry {
    /// Upright (portrait) image size in pixels.
    let imageSize: CGSize
    /// Focal length in pixels.
    let focalPx: Double
    let deviceToWorld: simd_double3x3

    private static let cameraToDevice = simd_double3x3(diagonal: SIMD3(1, -1, -1))

    var cameraToWorld: simd_double3x3 { deviceToWorld * Self.cameraToDevice }

    /// Ray through an image pixel, scaled so z == 1 (multiply by depth to get a 3D point).
    func ray(throughPixel p: CGPoint) -> SIMD3<Double> {
        let cx = Double(imageSize.width) / 2
        let cy = Double(imageSize.height) / 2
        return SIMD3((Double(p.x) - cx) / focalPx, (Double(p.y) - cy) / focalPx, 1)
    }

    /// Monocular range from apparent size:  depth = f · realSize / sizeInPixels
    func depth(realSizeMeters: Double, sizePixels: Double) -> Double {
        focalPx * realSizeMeters / sizePixels
    }
}
