import SwiftUI

/// Panel above the Shoot button with the big readouts for the primary bird (shown only while
/// a bird is detected).
struct HUDView: View {
    let bird: BirdReadout
    let unit: SpeedUnit
    let compassAvailable: Bool
    var speciesEnabled = true

    var body: some View {
        VStack(spacing: 10) {
            Group {
                speciesRow(bird)
                HStack(alignment: .top, spacing: 8) {
                    metric("DISTANCE", Format.distance(bird.distance))
                    metric("SPEED", bird.perched ? "Perched" : (bird.speed.map { Format.speed($0, unit: unit) } ?? "…"))
                    direction(bird)
                }
                HStack(spacing: 14) {
                    detail("arrow.up.and.down", "Height " + String(format: "%+.0f m", bird.heightAboveCamera))
                    if let v = bird.verticalSpeed, !bird.perched, abs(v) >= 0.1 {
                        detail(v >= 0 ? "arrow.up.right" : "arrow.down.right",
                               (v >= 0 ? "Climbing " : "Descending ") + String(format: "%.1f m/s", abs(v)))
                    }
                    if let r = bird.radialSpeed, r != 0 {
                        detail(r >= 0 ? "arrow.up.forward.circle" : "arrow.down.backward.circle",
                               (r >= 0 ? "Away " : "Toward ") + String(format: "%.1f m/s", abs(r)))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let lead = bird.lead, lead.ready {
                    VStack(spacing: 3) {
                        Label(String(format: "Lead %.2f m · aim off %.2f m · kill chance %.0f%%",
                                     lead.leadMeters, lead.missMeters, lead.killProbability * 100),
                              systemImage: "scope")
                        Text(String(format: "Shot %.2f s · %.0f m/s · %.1f J/pellet (needs %.1f) · pattern Ø %.2f m",
                                    lead.flightTime, lead.impactSpeed, lead.impactEnergy, lead.neededEnergy,
                                    lead.patternDiameter))
                            .font(.caption2.monospacedDigit())
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(lead.isHit ? .green : (lead.outOfRange ? .orange : .red))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                }
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

    @ViewBuilder
    private func speciesRow(_ bird: BirdReadout) -> some View {
        if bird.isClay {
            HStack(spacing: 8) {
                Image(systemName: "circle.circle.fill").foregroundStyle(.orange)
                Text("Clay").font(.headline)
                Spacer()
                Text(String(format: "diameter %.0f mm", bird.wingspan * 1000))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else {
            birdRow(bird)
        }
    }

    private func birdRow(_ bird: BirdReadout) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "bird.fill").foregroundStyle(.yellow)
            if let species = bird.species, let conf = bird.speciesConfidence {
                Text(species).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
                Text(String(format: "%.0f%%", conf * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(conf >= 0.6 ? .green : .orange)
            } else {
                Text(speciesEnabled ? "Identifying…" : "Bird").font(.headline).foregroundStyle(.secondary)
            }
            Spacer()
            Text(String(format: "wingspan %.2f m · %@", bird.wingspan,
                        bird.wingspanFromSpecies ? "species" : "preset"))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
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
                Text(bird.speed == nil ? "…" : (bird.perched ? "—" : "Hovering")).font(.title3.bold())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func detail(_ icon: String, _ text: String) -> some View {
        Label(text, systemImage: icon).lineLimit(1)
    }
}
