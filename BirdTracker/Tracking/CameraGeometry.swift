import CoreGraphics
import simd

/// Pinhole camera model for one frame plus the camera's orientation at that moment.
///
/// Frames used:
///  • Camera: x = right, y = down (image axes), z = forward (out of the lens)
///  • Device (Core Motion, portrait): x = right, y = up, z = out of the screen
///  • World: x = magnetic north, y = west, z = up
struct CameraGeometry {
    /// Upright image size in pixels.
    let imageSize: CGSize
    /// Focal length in pixels.
    let focalPx: Double
    let cameraToWorld: simd_double3x3
    /// Unit direction the shot travels in camera coordinates (phone: the optical axis;
    /// gun camera: wherever the barrel points in the image).
    var barrelAxis = SIMD3<Double>(0, 0, 1)

    private static let cameraToDevice = simd_double3x3(diagonal: SIMD3(1, -1, -1))

    /// Phone camera: orientation from Core Motion.
    init(imageSize: CGSize, focalPx: Double, deviceToWorld: simd_double3x3) {
        self.imageSize = imageSize
        self.focalPx = focalPx
        self.cameraToWorld = deviceToWorld * Self.cameraToDevice
    }

    /// Any camera whose orientation is known directly (gun camera + gun sensor).
    init(imageSize: CGSize, focalPx: Double, cameraToWorld: simd_double3x3,
         barrelAxis: SIMD3<Double> = SIMD3(0, 0, 1)) {
        self.imageSize = imageSize
        self.focalPx = focalPx
        self.cameraToWorld = cameraToWorld
        self.barrelAxis = barrelAxis
    }

    /// Same camera and barrel, different orientation.
    func with(cameraToWorld: simd_double3x3) -> CameraGeometry {
        CameraGeometry(imageSize: imageSize, focalPx: focalPx, cameraToWorld: cameraToWorld,
                       barrelAxis: barrelAxis)
    }

    /// Ray through an image pixel, scaled so z == 1 (multiply by depth to get a 3D point).
    func ray(throughPixel p: CGPoint) -> SIMD3<Double> {
        let cx = Double(imageSize.width) / 2
        let cy = Double(imageSize.height) / 2
        return SIMD3((Double(p.x) - cx) / focalPx, (Double(p.y) - cy) / focalPx, 1)
    }

    /// Unit direction through a normalised image point (origin top-left).
    func axis(throughNormalized p: CGPoint) -> SIMD3<Double> {
        simd_normalize(ray(throughPixel: CGPoint(x: p.x * imageSize.width, y: p.y * imageSize.height)))
    }

    /// Monocular range from apparent size:  depth = f · realSize / sizeInPixels
    func depth(realSizeMeters: Double, sizePixels: Double) -> Double {
        focalPx * realSizeMeters / sizePixels
    }
}
