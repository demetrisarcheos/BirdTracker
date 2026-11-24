import SwiftUI

/// Bottom panel with the big readouts for the primary bird.
struct HUDView: View {
    let bird: BirdReadout?
    let unit: SpeedUnit
    let compassAvailable: Bool

    var body: some View {
        VStack(spacing: 10) {
            if let bird {
                HStack(alignment: .top, spacing: 8) {
                    metric("DISTANCE", Format.distance(bird.distance))
                    metric("SPEED", bird.speed.map { Format.speed($0, unit: unit) } ?? "…")
                    direction(bird)
                }
                HStack(spacing: 14) {
                    detail("arrow.up.and.down", "Height " + String(format: "%+.0f m", bird.heightAboveCamera))
                    if let v = bird.verticalSpeed {
                        detail(v >= 0 ? "arrow.up.right" : "arrow.down.right",
                               (v >= 0 ? "Climbing " : "Descending ") + String(format: "%.1f m/s", abs(v)))
                    }
                    if let r = bird.radialSpeed {
                        detail(r >= 0 ? "arrow.up.forward.circle" : "arrow.down.backward.circle",
                               (r >= 0 ? "Away " : "Toward ") + String(format: "%.1f m/s", abs(r)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Point the camera at a bird")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
            }
            if !compassAvailable {
                Text("Compass unavailable — directions are relative to the start position.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.caption2.bold()).foregroundStyle(.secondary)
            Text(value).font(.title2.monospacedDigit().bold()).minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func direction(_ bird: BirdReadout) -> some View {
        VStack(spacing: 4) {
            Text("DIRECTION").font(.caption2.bold()).foregroundStyle(.secondary)
            if let bearing = bird.bearing {
                HStack(spacing: 6) {
                    Image(systemName: "location.north.fill")
                        .rotationEffect(.degrees(bearing))      // north-up map arrow
                        .foregroundStyle(.yellow)
                    Text(Format.compass(bearing))
                        .font(.title3.monospacedDigit().bold())
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                }
            } else {
                Text(bird.speed == nil ? "…" : "Hovering").font(.title3.bold())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detail(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).lineLimit(1)
    }
}
