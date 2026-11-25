import Foundation

enum AppSettings {
    static let birdSizeKey = "birdSizeMeters"
    static let confidenceKey = "confidenceThreshold"
    static let speedUnitKey = "speedUnit"
    static let identifySpeciesKey = "identifySpecies"
    static let showLeadPointKey = "showLeadPoint"
    static let chokeKey = "choke"

    /// Name of the bundled Core ML model (without extension). Any yolo*.mlpackage also works.
    static let modelName = "yolo26n"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            birdSizeKey: BirdSizePreset.pigeon.meters,
            confidenceKey: 0.30,
            speedUnitKey: SpeedUnit.kmh.rawValue,
            identifySpeciesKey: true,
            showLeadPointKey: true,
            chokeKey: Choke.modified.rawValue,
        ])
    }
}

/// Typical wingspans. Distance (and therefore speed) scales linearly with this value,
/// so picking the right size class is the single biggest accuracy factor.
enum BirdSizePreset: String, CaseIterable, Identifiable {
    case sparrow, starling, pigeon, crow, gull, buzzard, heron, eagle

    var id: String { rawValue }

    var meters: Double {
        switch self {
        case .sparrow:  return 0.23
        case .starling: return 0.40
        case .pigeon:   return 0.65
        case .crow:     return 0.95
        case .gull:     return 1.30
        case .buzzard:  return 1.25
        case .heron:    return 1.80
        case .eagle:    return 2.10
        }
    }

    var title: String {
        switch self {
        case .sparrow:  return "Sparrow / small songbird"
        case .starling: return "Starling / swallow"
        case .pigeon:   return "Pigeon / dove"
        case .crow:     return "Crow / duck"
        case .gull:     return "Gull"
        case .buzzard:  return "Buzzard / hawk"
        case .heron:    return "Heron / stork / pelican"
        case .eagle:    return "Eagle / vulture"
        }
    }
}

enum SpeedUnit: String, CaseIterable, Identifiable {
    case kmh, ms, mph

    var id: String { rawValue }
    var label: String {
        switch self {
        case .kmh: return "km/h"
        case .ms:  return "m/s"
        case .mph: return "mph"
        }
    }

    func convert(_ metersPerSecond: Double) -> Double {
        switch self {
        case .kmh: return metersPerSecond * 3.6
        case .ms:  return metersPerSecond
        case .mph: return metersPerSecond * 2.236_94
        }
    }
}

/// Shotgun choke: how fast the shot pattern spreads (pattern radius per metre of range).
enum Choke: String, CaseIterable, Identifiable {
    case cylinder, improved, modified, full

    var id: String { rawValue }
    var title: String {
        switch self {
        case .cylinder: return "Cyl"
        case .improved: return "IC"
        case .modified: return "Mod"
        case .full:     return "Full"
        }
    }
    var patternGrowth: Double {
        switch self {
        case .cylinder: return 0.014
        case .improved: return 0.012
        case .modified: return 0.0105
        case .full:     return 0.009
        }
    }
}
