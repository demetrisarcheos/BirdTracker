import SwiftUI
import simd

/// Round red button that fills in as the reticle approaches the correct aiming point
/// and turns solid with "SHOOT" when a shot fired now would hit.
struct ShootButton: View {
    let lead: LeadSolution?
    let action: () -> Void
    var diameter: CGFloat = 88

    /// 0.15 when far off (or nothing to shoot at) → 1.0 at the edge of a hit.
    static func opacity(for lead: LeadSolution?) -> Double {
        guard let lead, lead.ready else { return 0.15 }
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
                } else if lead?.ready == false {
                    ProgressView().tint(.white)          // still measuring speed
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
            Path { p in p.move(to: from); p.addLine(to: to) }
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
    let id = UUID()
    let hit: Bool
    let text: String

    static func evaluate(_ bird: BirdReadout?) -> ShotResult {
        guard let bird, let lead = bird.lead else {
            return ShotResult(hit: false, text: "No bird in the sights")
        }
        let name = bird.species ?? "bird"
        if !lead.ready {
            return ShotResult(hit: false, text: "Too early – still measuring the \(name)'s speed")
        }
        if lead.isHit {
            return ShotResult(hit: true, text: String(format: "HIT! %@ at %.0f m · lead %.2f m", name.capitalized,
                                                      bird.distance, lead.leadMeters))
        }
        return ShotResult(hit: false, text: String(format: "MISS – %.2f m %@", lead.missMeters, missDirection(lead)))
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
