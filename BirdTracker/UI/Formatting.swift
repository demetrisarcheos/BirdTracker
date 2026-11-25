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
    imageRect(normalized, imageSize: imageSize, in: viewSize, fill: true)
}

/// Maps a normalised image rect onto a view showing that image with aspect-fit (letterboxed).
func aspectFitRect(_ normalized: CGRect, imageSize: CGSize, in viewSize: CGSize) -> CGRect {
    imageRect(normalized, imageSize: imageSize, in: viewSize, fill: false)
}

/// A point in a view showing an image with aspect-fit → normalised image coordinates (nil = outside).
func normalizedPointInFit(_ p: CGPoint, imageSize: CGSize, in viewSize: CGSize) -> CGPoint? {
    let r = aspectFitRect(CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: imageSize, in: viewSize)
    guard r.width > 0, r.height > 0 else { return nil }
    let x = (p.x - r.minX) / r.width, y = (p.y - r.minY) / r.height
    return (0...1).contains(x) && (0...1).contains(y) ? CGPoint(x: x, y: y) : nil
}

func imageRect(_ normalized: CGRect, imageSize: CGSize, in viewSize: CGSize, fill: Bool) -> CGRect {
    guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
    let sx = viewSize.width / imageSize.width, sy = viewSize.height / imageSize.height
    let scale = fill ? max(sx, sy) : min(sx, sy)
    let drawnWidth = imageSize.width * scale
    let drawnHeight = imageSize.height * scale
    let offsetX = (viewSize.width - drawnWidth) / 2
    let offsetY = (viewSize.height - drawnHeight) / 2
    return CGRect(x: offsetX + normalized.minX * drawnWidth,
                  y: offsetY + normalized.minY * drawnHeight,
                  width: normalized.width * drawnWidth,
                  height: normalized.height * drawnHeight)
}
