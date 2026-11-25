import SwiftUI

/// Red aiming reticle drawn at the exact centre of the screen.
/// The preview uses aspect-fill, which crops the camera image equally on both sides, so the
/// screen centre is the image centre, i.e. the camera's aiming point (optical axis).
struct ReticleView: View {
    var size: CGFloat = 64        // overall width/height
    var gap: CGFloat = 10         // empty space around the centre so the target stays visible
    var color: Color = .red

    var body: some View {
        ZStack {
            crosshair.stroke(.black.opacity(0.6), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            crosshair.stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            Circle()
                .stroke(.black.opacity(0.6), lineWidth: 4)
                .frame(width: size * 0.62, height: size * 0.62)
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: size * 0.62, height: size * 0.62)
            Circle()
                .fill(color)
                .frame(width: 4, height: 4)
                .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 1))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Four lines from the outer edge to the gap around the centre.
    private var crosshair: Path {
        Path { p in
            let c = size / 2
            p.move(to: CGPoint(x: 0, y: c));          p.addLine(to: CGPoint(x: c - gap, y: c))
            p.move(to: CGPoint(x: c + gap, y: c));    p.addLine(to: CGPoint(x: size, y: c))
            p.move(to: CGPoint(x: c, y: 0));          p.addLine(to: CGPoint(x: c, y: c - gap))
            p.move(to: CGPoint(x: c, y: c + gap));    p.addLine(to: CGPoint(x: c, y: size))
        }
    }
}
