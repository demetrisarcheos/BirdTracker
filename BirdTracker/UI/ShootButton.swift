import SwiftUI
import simd

/// Round red button that fills in as the reticle approaches the correct aiming point
/// and turns solid with "SHOOT" when a shot fired now would kill (≥ 80 %).
struct ShootButton: View {
    let lead: LeadSolution?
    let action: () -> Void
    var diameter: CGFloat = 88

    /// 0.15 when far off, out of range or nothing to shoot at → 1.0 at the edge of the kill zone.
    static func opacity(for lead: LeadSolution?) -> Double {
        guard let lead, lead.ready, !lead.outOfRange else { return 0.15 }
        let r = lead.hitRatio
        if r <= 1 { return 1 }
        // Logarithmic ramp: 2× off ≈ 0.75, 4× ≈ 0.5, 10× or more = 0.15
        return 0.15 + 0.85 * max(0, 1 - log10(r))
    }

    var body: some View {
        let onTarget = lead?.isHit ?? false
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(Self.opacity(for: lead)))
                Circle()
                    .stroke(.white.opacity(onTarget ? 1 : 0.7), lineWidth: onTarget ? 4 : 2)
                if onTarget {
                    Text("SHOOT")
                        .font(.system(size: 19, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                } else if let lead, !lead.ready {
                    ProgressView().tint(.white)          // still measuring speed
                } else if let lead, lead.outOfRange {
                    Text("TOO\nFAR")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(width: diameter, height: diameter)
            .scaleEffect(onTarget ? 1.08 : 1)
            .shadow(color: .red.opacity(onTarget ? 0.8 : 0), radius: 14)
            .animation(.easeOut(duration: 0.12), value: onTarget)
            .animation(.linear(duration: 0.1), value: Self.opacity(for: lead))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(onTarget ? "Shoot, on target" : "Shoot")
    }
}

/// Small red ring at the computed aiming point, joined to the bird by a dashed line.
struct LeadMarkerView: View {
    let from: CGPoint
    let to: CGPoint
    let onTarget: Bool

    var body: some View {
        ZStack {
            Path { p in
                p.move(to: from)
                p.addLine(to: to)
            }
            .stroke(.red.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            Circle()
                .stroke(onTarget ? Color.green : Color.red, lineWidth: 2.5)
                .background(Circle().stroke(.black.opacity(0.5), lineWidth: 4.5))
                .frame(width: 22, height: 22)
                .position(to)
        }
    }
}

/// Outcome of a simulated shot, shown briefly on screen.
struct ShotResult: Identifiable, Equatable {
    enum Outcome { case kill, wounded, miss, noShot }

    let id = UUID()
    let outcome: Outcome
    let text: String

    var hit: Bool { outcome == .kill }
    /// Counts towards the score (a real shot was fired at a measured bird).
    var counts: Bool { outcome != .noShot }

    /// Simulates where the pellets went: random pellet counts drawn around the expected values
    /// for the current aim, so — as in real shooting — a good aim usually, not always, kills.
    static func simulate(_ bird: BirdReadout?, barrelNote: String) -> ShotResult {
        guard let bird, let lead = bird.lead else {
            return ShotResult(outcome: .noShot, text: "No bird in the sights")
        }
        let name = (bird.species ?? "bird").capitalized
        if !lead.ready {
            return ShotResult(outcome: .noShot, text: "Too early – still measuring the bird's speed")
        }

        let vital = KillModel.poisson(lead.expectedVitalHits)
        let body = max(vital, KillModel.poisson(lead.expectedBodyHits))
        let prefix = barrelNote.isEmpty ? "" : barrelNote + " · "

        if vital >= 2 {
            return ShotResult(outcome: .kill, text: String(
                format: "%@HIT! %@ at %.0f m – %d pellets in the vitals (%.1f J each)",
                prefix, name, lead.range, vital, lead.impactEnergy))
        }
        if body >= 1 {
            let weak = lead.impactEnergy < lead.neededEnergy ? ", pellets too weak at this range" : ""
            return ShotResult(outcome: .wounded, text: String(
                format: "%@WOUNDED – %d pellet%@ hit, not a clean kill%@",
                prefix, body, body == 1 ? "" : "s", weak))
        }
        if lead.outOfRange && lead.hitRatio.isInfinite && lead.missMeters < lead.patternDiameter / 2 {
            return ShotResult(outcome: .miss, text: prefix + "MISS – too far for this cartridge and choke")
        }
        return ShotResult(outcome: .miss, text: String(format: "%@MISS – %.2f m %@", prefix, lead.missMeters,
                                                       missDirection(lead)))
    }

    /// "behind", "ahead", "high", "low", "left" or "right" — whichever dominates.
    private static func missDirection(_ lead: LeadSolution) -> String {
        let offset = SIMD2(lead.shotOffsetRight, lead.shotOffsetUp)
        if let m = lead.screenMotion {
            let along = simd_dot(offset, m)
            let across = offset - along * m
            if abs(along) >= simd_length(across) { return along < 0 ? "behind" : "ahead" }
        }
        if abs(offset.y) >= abs(offset.x) { return offset.y > 0 ? "high" : "low" }
        return offset.x > 0 ? "right" : "left"
    }
}
