import Foundation

/// Typical wingspan for a species name from the classifier.
///
/// English bird names end with the group noun ("ROCK DOVE", "HERRING GULL",
/// "EURASIAN EAGLE OWL"), so the words are checked from last to first and the first
/// group found wins. Values are typical adult wingspans in metres for the group;
/// a few common species have exact overrides.
enum SpeciesWingspan {
    private static let speciesOverrides: [String: Double] = [
        "ROCK DOVE": 0.67,
        "EUROPEAN TURTLE DOVE": 0.50,
        "MOURNING DOVE": 0.45,
        "HOUSE SPARROW": 0.23,
        "COMMON STARLING": 0.40,
        "EUROPEAN GOLDFINCH": 0.23,
        "BARN SWALLOW": 0.33,
        "EURASIAN MAGPIE": 0.56,
        "HOOPOES": 0.46,
        "ROUGH LEG BUZZARD": 1.35,
        "AMERICAN KESTREL": 0.58,
        "BALD EAGLE": 2.05,
        "GOLDEN EAGLE": 2.10,
        "MALLARD DUCK": 0.88,
        "MUTE SWAN": 2.20,
        "OSTRICH": 2.00,
        "EMU": 1.60,
    ]

    private static let groups: [String: Double] = [
        // Large soaring birds
        "CONDOR": 2.9, "ALBATROSS": 2.8, "VULTURE": 2.4, "PELICAN": 2.6, "FRIGATE": 2.2,
        "EAGLE": 2.0, "CRANE": 2.0, "STORK": 1.8, "SWAN": 2.1, "OSPREY": 1.6,
        "GANNET": 1.7, "BOOBY": 1.5, "FLAMINGO": 1.5, "HERON": 1.6, "EGRET": 1.0,
        "BITTERN": 1.2, "IBIS": 1.0, "SPOONBILL": 1.2, "GOOSE": 1.5, "CORMORANT": 1.3,
        "ANHINGA": 1.15, "TURKEY": 1.3, "PEACOCK": 1.4, "PEAFOWL": 1.4, "BUSTARD": 2.0,
        // Raptors & owls
        "BUZZARD": 1.25, "HAWK": 1.1, "KITE": 1.4, "HARRIER": 1.1, "CARACARA": 1.2,
        "FALCON": 1.0, "KESTREL": 0.75, "MERLIN": 0.6, "OWL": 1.0, "OWLET": 0.4,
        // Water birds
        "GULL": 1.3, "TERN": 0.8, "SKIMMER": 1.1, "PUFFIN": 0.55, "PENGUIN": 0.7,
        "DUCK": 0.85, "TEAL": 0.6, "WIGEON": 0.8, "MERGANSER": 0.8, "EIDER": 0.95,
        "SCOTER": 0.85, "GREBE": 0.7, "LOON": 1.3, "COOT": 0.75, "GALLINULE": 0.6,
        "RAIL": 0.4, "MOORHEN": 0.55,
        // Waders
        "CURLEW": 0.9, "GODWIT": 0.75, "CATCHER": 0.8, "AVOCET": 0.75, "STILT": 0.7,
        "SANDPIPER": 0.4, "PLOVER": 0.5, "DUNLIN": 0.4, "LAPWING": 0.8, "DOWITCHER": 0.45,
        // Medium land birds
        "PIGEON": 0.65, "DOVE": 0.5, "RAVEN": 1.2, "CROW": 1.0, "ROOK": 0.9, "JACKDAW": 0.7,
        "MAGPIE": 0.55, "JAY": 0.55, "NUTCRACKER": 0.55, "CHOUGH": 0.8,
        "MACAW": 1.0, "COCKATOO": 0.9, "PARROT": 0.7, "PARAKEET": 0.45, "LORIKEET": 0.4,
        "LORY": 0.4, "CONURE": 0.45, "LOVEBIRD": 0.25,
        "HORNBILL": 1.1, "TOUCAN": 0.6, "ARACARI": 0.45, "CUCKOO": 0.55, "ROADRUNNER": 0.55,
        "COUCAL": 0.6, "TURACO": 0.6, "PHEASANT": 0.8, "GROUSE": 0.7, "PARTRIDGE": 0.5,
        "QUAIL": 0.35, "GUINEAFOWL": 0.75, "CHACHALACA": 0.65, "CURASSOW": 0.9,
        "ROLLER": 0.6, "HOOPOE": 0.46, "EATER": 0.45, "KINGFISHER": 0.3, "KOOKABURRA": 0.65,
        "WOODPECKER": 0.4, "FLICKER": 0.5, "SAPSUCKER": 0.4, "TROGON": 0.4, "QUETZAL": 0.6,
        "NIGHTJAR": 0.55, "FROGMOUTH": 0.6, "POTOO": 0.7, "MOTMOT": 0.45,
        // Small birds
        "SWIFT": 0.42, "SWALLOW": 0.33, "MARTIN": 0.28, "STARLING": 0.38, "MYNA": 0.42,
        "THRUSH": 0.35, "ROBIN": 0.25, "BLACKBIRD": 0.37, "ORIOLE": 0.45, "SHRIKE": 0.3,
        "LARK": 0.33, "PIPIT": 0.26, "WAGTAIL": 0.28, "BULBUL": 0.3, "DRONGO": 0.4,
        "TANAGER": 0.28, "GROSBEAK": 0.32, "CARDINAL": 0.28, "BUNTING": 0.24,
        "FINCH": 0.23, "GOLDFINCH": 0.23, "SPARROW": 0.23, "CANARY": 0.22, "SISKIN": 0.21,
        "TOWHEE": 0.28, "JUNCO": 0.23, "WARBLER": 0.2, "VIREO": 0.23, "TIT": 0.2,
        "CHICKADEE": 0.2, "NUTHATCH": 0.25, "CREEPER": 0.19, "WREN": 0.15, "KINGLET": 0.17,
        "FLYCATCHER": 0.23, "PHOEBE": 0.27, "KINGBIRD": 0.38, "TYRANT": 0.3, "MOCKINGBIRD": 0.34,
        "THRASHER": 0.32, "CATBIRD": 0.27, "WAXWING": 0.3, "BLUEBIRD": 0.3, "WHYDAH": 0.22,
        "WEAVER": 0.22, "MANNIKIN": 0.17, "MUNIA": 0.17, "SUNBIRD": 0.15, "HONEYEATER": 0.25,
        "HUMMINGBIRD": 0.11, "HERMIT": 0.12, "BABBLER": 0.3, "BARBET": 0.35, "PITTA": 0.4,
        "COTINGA": 0.35, "MANAKIN": 0.18, "BOBOLINK": 0.28, "MEADOWLARK": 0.38,
        "GRACKLE": 0.42, "COWBIRD": 0.33, "BIRD": 0.3,
    ]

    /// Typical wingspan in metres, or nil if the species group is unknown.
    static func meters(for label: String) -> Double? {
        let name = label.uppercased()
        if let exact = speciesOverrides[name] { return exact }
        let words = name
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { String($0) }
        for word in words.reversed() {
            if let value = groups[word] { return value }
            // plural forms such as "HOOPOES"
            if word.hasSuffix("S"), let value = groups[String(word.dropLast())] { return value }
        }
        return nil
    }

    /// "ROCK DOVE" -> "Rock Dove"
    static func displayName(_ label: String) -> String {
        label.lowercased().split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
