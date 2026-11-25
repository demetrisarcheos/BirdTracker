import Foundation

/// The species the Cyprus model knows (labels = training folder names in training/build_dataset.py)
/// and their typical adult wingspans.
enum SpeciesWingspan {
    static let otherLabel = "Other Bird"

    private static let wingspans: [String: Double] = [
        "wood pigeon": 0.75,        // 68–80 cm
        "song thrush": 0.35,        // 33–36 cm
        "chukar partridge": 0.50,   // 47–52 cm
        "eurasian skylark": 0.33,   // 30–36 cm
        "hooded crow": 0.98,        // 93–104 cm
    ]

    /// True for the catch-all class (any bird that is not one of the five species).
    static func isOther(_ label: String) -> Bool {
        label.caseInsensitiveCompare(otherLabel) == .orderedSame
    }

    /// Typical wingspan in metres, or nil for "Other Bird" / unknown labels.
    static func meters(for label: String) -> Double? {
        wingspans[label.lowercased()]
    }

    static func displayName(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
