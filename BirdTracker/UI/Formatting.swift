import CoreGraphics
import Foundation

enum Format {
    static func distance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    static func speed(_ metersPerSecond: Double, unit: SpeedUnit) -> String {
        String(format: "%.0f %@", unit.convert(metersPerSecond), unit.label)
    }

    static func signedRate(_ metersPerSecond: Double) -> String {
        String(format: "%+.1f m/s", metersPerSecond)
    }

    private static let points = ["N", "NNE", "NE", "ENE", "E", "ESE", "SE", "SSE",
                                 "S", "SSW", "SW", "WSW", "W", "WNW", "NW", "NNW"]

    static func compass(_ degrees: Double) -> String {
        let index = Int((degrees / 22.5).rounded()) % 16
        return "\(points[index]) \(Int(degrees.rounded()) % 360)°"
    }

    static func shortCompass(_ degrees: Double) -> String {
        points[Int((degrees / 22.5).rounded()) % 16]
    }
}

/// Maps a normalised image rect onto a view showing that image with aspect-fill.
func aspectFillRect(_ normalized: CGRect, imageSize: CGSize, in viewSize: CGSize) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
    let drawnWidth = imageSize.width * scale
    let drawnHeight = imageSize.height * scale
    let offsetX = (viewSize.width - drawnWidth) / 2
    let offsetY = (viewSize.height - drawnHeight) / 2
    return CGRect(x: offsetX + normalized.minX * drawnWidth,
                  y: offsetY + normalized.minY * drawnHeight,
                  width: normalized.width * drawnWidth,
                  height: normalized.height * drawnHeight)
}
