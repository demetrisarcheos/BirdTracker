import Foundation

/// Chosen on every fresh launch: hunting birds or shooting clay targets.
enum UserMode: String, CaseIterable, Identifiable {
    case hunter, shooter

    var id: String { rawValue }
    var title: String { self == .hunter ? "Hunter" : "Shooter" }
    var targetKind: TargetKind { self == .hunter ? .bird : .clay }

    static var current: UserMode {
        UserMode(rawValue: UserDefaults.standard.string(forKey: AppSettings.userModeKey) ?? "") ?? .hunter
    }
}

/// What the detector looks for and the tracker follows.
enum TargetKind: String {
    case bird, clay
}

/// Clay target sizes (ISSF / FITASC). Distance is worked out from the diameter.
enum ClayType: String, CaseIterable, Identifiable {
    case standard, midi, mini, battue, rabbit

    var id: String { rawValue }

    var diameter: Double {
        switch self {
        case .standard: return 0.110
        case .midi:     return 0.090
        case .mini:     return 0.060
        case .battue:   return 0.108
        case .rabbit:   return 0.110
        }
    }

    var title: String {
        switch self {
        case .standard: return "Standard (110 mm)"
        case .midi:     return "Midi (90 mm)"
        case .mini:     return "Mini (60 mm)"
        case .battue:   return "Battue (108 mm, flat)"
        case .rabbit:   return "Rabbit (110 mm, rolling)"
        }
    }

    static var current: ClayType {
        ClayType(rawValue: UserDefaults.standard.string(forKey: AppSettings.clayTypeKey) ?? "") ?? .standard
    }
}

/// Size and toughness of what is being shot at, for the pellet maths.
struct TargetBody {
    /// Area the shot can hit (m²).
    let bodyArea: Double
    /// Area where hits count for a clean kill or a break (m²).
    let vitalArea: Double
    /// Energy one pellet needs (J).
    let minEnergy: Double

    static func bird(wingspan: Double) -> TargetBody {
        TargetBody(bodyArea: KillModel.bodyArea(wingspan: wingspan),
                   vitalArea: KillModel.vitalArea(wingspan: wingspan),
                   minEnergy: KillModel.minEnergy(wingspan: wingspan))
    }

    /// A clay is seen at an angle: on average about half of its full disc. Any part breaks it,
    /// and a pellet needs far less energy than for a bird (estimate: 0.5 J).
    static func clay(diameter d: Double) -> TargetBody {
        let area = 0.5 * Double.pi * d * d / 4
        return TargetBody(bodyArea: area, vitalArea: area, minEnergy: clayBreakEnergy)
    }

    static let clayBreakEnergy = 0.5
}
