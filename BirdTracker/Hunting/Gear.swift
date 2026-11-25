import Foundation

// MARK: - Shotgun

enum GunAction: String, Codable, CaseIterable, Identifiable {
    case semiAuto, pump, overUnder, sideBySide

    var id: String { rawValue }
    var title: String {
        switch self {
        case .semiAuto:   return "Semi-automatic"
        case .pump:       return "Pump"
        case .overUnder:  return "Over & under"
        case .sideBySide: return "Side by side"
        }
    }
    /// Two barrels, each with its own choke.
    var isDouble: Bool { self == .overUnder || self == .sideBySide }
}

struct ChokeOption: Identifiable, Hashable {
    let marking: String
    let name: String
    let mm: Double
    var id: String { marking }
    var label: String { marking == name ? "\(name) · \(Self.mmText(mm))" : "\(marking)  \(name) · \(Self.mmText(mm))" }
    static func mmText(_ mm: Double) -> String { String(format: "%.2f mm", mm) }
}

/// How a manufacturer marks its choke tubes (or fixed-choke barrels).
enum ChokeSystem: String, Codable, CaseIterable, Identifiable {
    /// Stars or notches: 1 = Full … 5 = Cylinder. Beretta (Mobil/Optima), Benelli, Browning/Winchester
    /// Invector, Franchi, and Italian fixed-choke barrels stamped with stars.
    case notches
    /// Letters engraved on the tube: F, IM, M, IC, SK, CYL…
    case letters
    /// Constriction typed in directly (custom or extended tubes, often stamped in mm or thousandths).
    case millimetres

    var id: String { rawValue }
    var title: String {
        switch self {
        case .notches:     return "Stars / notches"
        case .letters:     return "Letters"
        case .millimetres: return "Constriction (mm)"
        }
    }

    var options: [ChokeOption] {
        switch self {
        case .notches:
            return [ChokeOption(marking: "★", name: "Full", mm: 1.0),
                    ChokeOption(marking: "★★", name: "Improved Modified", mm: 0.75),
                    ChokeOption(marking: "★★★", name: "Modified", mm: 0.5),
                    ChokeOption(marking: "★★★★", name: "Improved Cylinder", mm: 0.25),
                    ChokeOption(marking: "★★★★★", name: "Cylinder", mm: 0)]
        case .letters:
            return [ChokeOption(marking: "XF", name: "Extra Full", mm: 1.25),
                    ChokeOption(marking: "F", name: "Full", mm: 1.0),
                    ChokeOption(marking: "IM", name: "Improved Modified", mm: 0.75),
                    ChokeOption(marking: "M", name: "Modified", mm: 0.5),
                    ChokeOption(marking: "LM", name: "Light Modified", mm: 0.375),
                    ChokeOption(marking: "IC", name: "Improved Cylinder", mm: 0.25),
                    ChokeOption(marking: "SK", name: "Skeet", mm: 0.125),
                    ChokeOption(marking: "CYL", name: "Cylinder", mm: 0)]
        case .millimetres:
            return []
        }
    }

    /// Short name for a constriction, e.g. "Mod" or "0.60 mm".
    static func name(forMM mm: Double) -> String {
        let names: [(Double, String)] = [(0, "Cyl"), (0.125, "Skeet"), (0.25, "IC"), (0.375, "LM"),
                                         (0.5, "Mod"), (0.75, "IM"), (1.0, "Full"), (1.25, "XF")]
        if let match = names.first(where: { abs($0.0 - mm) < 0.02 }) { return match.1 }
        return String(format: "%.2f mm", mm)
    }
}

/// A shotgun model with its usual barrel lengths and choke-marking system. These are typical
/// catalogue values; barrel length and choke can always be changed to match the actual gun.
struct GunModel: Identifiable, Hashable {
    let brand: String
    let name: String
    let action: GunAction
    let barrels: [Double]            // cm
    let chokes: ChokeSystem
    var id: String { brand + "|" + name }
}

enum GunCatalog {
    static let other = "Other / not listed"

    static let models: [GunModel] = [
        GunModel(brand: "Beretta", name: "A400 Xplor", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Beretta", name: "A300 Outlander", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Beretta", name: "1301", action: .semiAuto, barrels: [61, 66, 71], chokes: .notches),
        GunModel(brand: "Beretta", name: "686 Silver Pigeon", action: .overUnder, barrels: [71, 76, 81], chokes: .notches),
        GunModel(brand: "Beretta", name: "690", action: .overUnder, barrels: [71, 76, 81], chokes: .notches),
        GunModel(brand: "Beretta", name: "694", action: .overUnder, barrels: [76, 81], chokes: .notches),
        GunModel(brand: "Benelli", name: "Montefeltro", action: .semiAuto, barrels: [61, 66, 71, 76], chokes: .notches),
        GunModel(brand: "Benelli", name: "Raffaello", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Benelli", name: "Super Black Eagle 3", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Benelli", name: "M2", action: .semiAuto, barrels: [61, 66, 71], chokes: .notches),
        GunModel(brand: "Benelli", name: "828U", action: .overUnder, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Browning", name: "Maxus II", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Browning", name: "A5", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Browning", name: "B525", action: .overUnder, barrels: [71, 76, 81], chokes: .notches),
        GunModel(brand: "Winchester", name: "SX4", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Franchi", name: "Affinity 3", action: .semiAuto, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Franchi", name: "Feeling", action: .overUnder, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: "Fabarm", name: "XLR5", action: .semiAuto, barrels: [71, 76], chokes: .letters),
        GunModel(brand: "Fabarm", name: "Elos", action: .overUnder, barrels: [71, 76], chokes: .letters),
        GunModel(brand: "Stoeger", name: "M3000", action: .semiAuto, barrels: [66, 71, 76], chokes: .letters),
        GunModel(brand: "Stoeger", name: "Condor", action: .overUnder, barrels: [66, 71], chokes: .letters),
        GunModel(brand: "Huglu", name: "Semi-auto", action: .semiAuto, barrels: [66, 71, 76], chokes: .letters),
        GunModel(brand: "Huglu", name: "Over & under", action: .overUnder, barrels: [71, 76], chokes: .letters),
        GunModel(brand: "Hatsan", name: "Escort", action: .semiAuto, barrels: [66, 71, 76], chokes: .letters),
        GunModel(brand: "ATA Arms", name: "SP", action: .overUnder, barrels: [71, 76], chokes: .letters),
        GunModel(brand: "Remington", name: "870", action: .pump, barrels: [66, 71], chokes: .letters),
        GunModel(brand: "Mossberg", name: "500", action: .pump, barrels: [61, 71], chokes: .letters),
        GunModel(brand: other, name: "Semi-automatic", action: .semiAuto, barrels: [66, 71, 76], chokes: .letters),
        GunModel(brand: other, name: "Over & under", action: .overUnder, barrels: [71, 76, 81], chokes: .letters),
        GunModel(brand: other, name: "Side by side", action: .sideBySide, barrels: [66, 71, 76], chokes: .notches),
        GunModel(brand: other, name: "Pump", action: .pump, barrels: [66, 71], chokes: .letters),
    ]

    static var brands: [String] {
        var seen = Set<String>()
        return models.map(\.brand).filter { seen.insert($0).inserted }
    }

    static func models(of brand: String) -> [GunModel] { models.filter { $0.brand == brand } }
}

/// The user's shotgun as set up in Settings.
struct GunSetup: Codable, Equatable {
    var brand = "Beretta"
    var model = "A400 Xplor"
    var action = GunAction.semiAuto
    var barrelCM: Double = 71
    var chokeSystem = ChokeSystem.notches
    /// Constriction of the only barrel / the first barrel fired (bottom barrel of an O/U), mm.
    var choke1MM: Double = 0.5
    /// Second barrel of a double gun, mm.
    var choke2MM: Double = 0.75

    var title: String { brand == GunCatalog.other ? model : "\(brand) \(model)" }
}

// MARK: - Cartridge

struct Cartridge: Codable, Identifiable, Equatable {
    var id = UUID()
    var brand = ""
    var model = ""
    var gauge = 12
    var loadGrams: Double = 32
    var shotNumber = "7"
    var pelletMM: Double = 2.5
    var material = PelletMaterial.lead
    /// Pellet speed as printed on the box (m/s) and the distance it was measured at:
    /// 0 = muzzle (V0), 1 m (V1) or 2.5 m (V2.5).
    var velocity: Double = 400
    var velocityDistance: Double = 1

    var title: String {
        let name = [brand, model].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Cartridge" : name
    }

    var shortTitle: String { String(format: "%.0f g No.%@", loadGrams, shotNumber) }

    var summary: String {
        let v = velocityDistance == 0 ? "V0" : (velocityDistance == 1 ? "V1" : "V2.5")
        return String(format: "%.0f g · No.%@ (%.2f mm) %@ · %@ %.0f m/s", loadGrams, shotNumber, pelletMM,
                      material.title.lowercased(), v, velocity)
    }

    private static func presetID(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    /// Typical, generic loads to start from. Real boxes differ: scan or type in your own.
    static let presets: [Cartridge] = [
        Cartridge(id: presetID(1), brand: "Generic", model: "Thrush 28 g No.10", loadGrams: 28, shotNumber: "10", pelletMM: 1.75,
                  velocity: 390),
        Cartridge(id: presetID(2), brand: "Generic", model: "All-round 32 g No.7½", loadGrams: 32, shotNumber: "7½", pelletMM: 2.4,
                  velocity: 400),
        Cartridge(id: presetID(3), brand: "Generic", model: "Pigeon 34 g No.6", loadGrams: 34, shotNumber: "6", pelletMM: 2.75,
                  velocity: 405),
        Cartridge(id: presetID(4), brand: "Generic", model: "Steel 32 g 3.0 mm", loadGrams: 32, shotNumber: "5", pelletMM: 3.0,
                  material: .steel, velocity: 430),
    ]
}

// MARK: - Storage (JSON strings in UserDefaults, so SwiftUI views can observe them with @AppStorage)

enum GearStore {
    static let gunKey = "gunSetup"
    static let cartridgesKey = "cartridges"
    static let selectedCartridgeKey = "selectedCartridge"

    static func gun(_ json: String) -> GunSetup {
        (try? JSONDecoder().decode(GunSetup.self, from: Data(json.utf8))) ?? GunSetup()
    }

    static func json(_ gun: GunSetup) -> String {
        (try? String(decoding: JSONEncoder().encode(gun), as: UTF8.self)) ?? ""
    }

    static func cartridges(_ json: String) -> [Cartridge] {
        let list = (try? JSONDecoder().decode([Cartridge].self, from: Data(json.utf8))) ?? []
        return list.isEmpty ? Cartridge.presets : list
    }

    static func json(_ list: [Cartridge]) -> String {
        (try? String(decoding: JSONEncoder().encode(list), as: UTF8.self)) ?? ""
    }

    static func selected(_ list: [Cartridge], id: String) -> Cartridge {
        list.first { $0.id.uuidString == id } ?? list.first { $0.model.contains("All-round") } ?? list[0]
    }

    /// Current loadout from what is saved in UserDefaults.
    static func loadout(barrel: Int = 1, defaults: UserDefaults = .standard) -> Loadout {
        let gun = gun(defaults.string(forKey: gunKey) ?? "")
        let list = cartridges(defaults.string(forKey: cartridgesKey) ?? "")
        let cartridge = selected(list, id: defaults.string(forKey: selectedCartridgeKey) ?? "")
        return Loadout(gun: gun, cartridge: cartridge, barrel: barrel)
    }
}
