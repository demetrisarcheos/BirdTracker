import Foundation
import ImageIO
import UIKit
import Vision

/// Reads the specs printed on a cartridge box from a photo (on-device text recognition).
enum CartridgeScanner {
    struct Result {
        var cartridge: Cartridge
        /// What was recognised, for the user to check ("Load 32 g", "Speed V1 400 m/s"…).
        var found: [String]
        var rawText: String
    }

    static func scan(_ image: UIImage) async -> Result {
        let lines = await recognizeText(in: image)
        return parse(lines)
    }

    // MARK: Text recognition

    static func recognizeText(in image: UIImage) async -> [String] {
        guard let cgImage = image.cgImage else { return [] }
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US", "it-IT", "fr-FR", "es-ES", "de-DE"]
            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
            do { try handler.perform([request]) } catch { return [] }
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        }.value
    }

    // MARK: Parsing

    static let knownBrands = [
        "Fiocchi", "RC", "Baschieri & Pellagri", "B&P", "Cheddite", "Clever", "Mirage", "Saga", "Eley",
        "Gamebore", "Hull", "Lyalvale", "Winchester", "Remington", "Federal", "Sellier & Bellot", "NobelSport",
        "Nobel Sport", "Bornaghi", "Martignoni", "Rio", "Maxam", "Kent", "Rottweil", "Geco", "Armusa", "Sterling",
    ]

    static func parse(_ lines: [String]) -> Result {
        let raw = lines.joined(separator: "\n")
        // One lower-case line of text; decimal commas → points ("2,4 mm" → "2.4 mm").
        var text = lines.joined(separator: " ").lowercased()
        text = text.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
        text = text.replacingOccurrences(of: "½", with: ".5")

        var c = Cartridge(brand: "", model: "")
        var found: [String] = []

        // Brand
        let brand = knownBrands.first { b in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: b.lowercased()) + "\\b"
            return text.range(of: pattern, options: .regularExpression) != nil
        }
        if let brand {
            c.brand = brand == "B&P" ? "Baschieri & Pellagri" : brand
            found.append("Brand: \(c.brand)")
            // Model: the first line after the brand line that looks like a product name.
            if let i = lines.firstIndex(where: { $0.lowercased().contains(brand.lowercased()) }) {
                let candidates = lines[(i)...].prefix(4).map { $0.replacingOccurrences(of: brand, with: "", options: .caseInsensitive) }
                if let name = candidates.map({ $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)) })
                    .first(where: { $0.count >= 3 && $0.rangeOfCharacter(from: .letters) != nil && $0.count <= 30 }) {
                    c.model = name
                }
            }
        }

        // Gauge, e.g. "12/70", "cal. 12", "12 ga"
        if let g = firstNumber(in: text, patterns: [#"\b(12|16|20|28)\s*/\s*(?:65|67|70|76|89)\b"#,
                                                    #"\bcal(?:ibre|ibro|\.)?\s*(12|16|20|28)\b"#,
                                                    #"\b(12|16|20|28)\s*(?:ga|gauge|g\.a\.)\b"#], range: 12...28) {
            c.gauge = Int(g)
            found.append("Gauge \(Int(g))")
        }

        // Load in grams, e.g. "32 g", "32gr", "gr. 32", "32 grammi". Avoid "12 g"auge.
        if let load = firstNumber(in: text, patterns: [#"\b(\d{2}(?:\.\d)?)\s*(?:g|gr|grs|gram|grams|grammi|gramos|grammes)\b\.?"#,
                                                       #"\b(?:g|gr|grs)\.?\s*(\d{2}(?:\.\d)?)\b"#], range: 14...60) {
            c.loadGrams = load
            found.append(String(format: "Load %.0f g", load))
        }

        // Pellet diameter, e.g. "2.4 mm", "Ø 2.4"
        let mm = firstNumber(in: text, patterns: [#"\b(\d\.\d{1,2})\s*mm\b"#, #"ø\s*(\d\.\d{1,2})\b"#], range: 1.0...5.5)

        // Shot number, e.g. "n.7", "no 7.5", "piombo 9", "#8", "pb 10"
        let number = firstNumber(in: text, patterns: [
            #"(?:\bn[°º.]?|\bno\.?|\bnr\.?|\bnum\.?|#|\bpiombo|\bpb|\bshot|\bsize|\bpallini|\bplomb|\bperdigón|\bperdigon)\s*(\d{1,2}(?:\.5)?)\b"#,
        ], range: 1...12)

        if let mm {
            c.pelletMM = mm
            c.shotNumber = number.map(shotNumberText) ?? ShotScale.number(for: mm)
            found.append(String(format: "Shot No.%@ · %.2f mm", c.shotNumber, mm))
        } else if let number {
            c.shotNumber = shotNumberText(number)
            c.pelletMM = ShotScale.mm(for: c.shotNumber) ?? c.pelletMM
            found.append(String(format: "Shot No.%@ (≈%.2f mm, check the box)", c.shotNumber, c.pelletMM))
        }

        // Speed, e.g. "V1 400 m/s", "400 m/s", "v2.5 = 385", "1300 fps"
        if let v = firstNumber(in: text, patterns: [#"\b(\d{3})\s*(?:m\s*/\s*s(?:ec)?|mps|m\.s\.)"#,
                                                    #"\bv\s*(?:0|1|2\.5)\s*[=:]?\s*(?:m/s)?\s*(\d{3})\b"#], range: 250...560) {
            c.velocity = v
            if let ref = firstNumber(in: text, patterns: [#"\bv\s*(0|1|2\.5)\b"#], range: 0...2.5) {
                c.velocityDistance = ref
            }
            found.append(String(format: "Speed V%@ %.0f m/s", c.velocityDistance == 2.5 ? "2.5" : String(Int(c.velocityDistance)), v))
        } else if let fps = firstNumber(in: text, patterns: [#"\b(\d{4})\s*(?:fps|ft/s|ft\.?/sec)"#], range: 900...1800) {
            c.velocity = (fps * 0.3048).rounded()
            c.velocityDistance = 1
            found.append(String(format: "Speed %.0f fps = %.0f m/s", fps, c.velocity))
        }

        // Material
        let materials: [(PelletMaterial, [String])] = [
            (.steel, ["steel", "acciaio", "acier", "stahl", "acero", "fer doux"]),
            (.bismuth, ["bismuth", "bismuto"]),
            (.tungsten, ["tungsten", "tungsteno", "hevi", "tss"]),
            (.lead, ["lead", "piombo", "plomb", "plomo", "blei"]),
        ]
        if let m = materials.first(where: { $0.1.contains { text.contains($0) } }) {
            c.material = m.0
            found.append("Pellets: \(m.0.title.lowercased())")
        }

        return Result(cartridge: c, found: found, rawText: raw)
    }

    private static func shotNumberText(_ n: Double) -> String {
        n.truncatingRemainder(dividingBy: 1) == 0.5 ? "\(Int(n))½" : "\(Int(n))"
    }

    /// First capture group of the first pattern that yields a number inside `range`.
    private static func firstNumber(in text: String, patterns: [String], range: ClosedRange<Double>) -> Double? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.numberOfRanges > 1 {
                let group = match.range(at: 1)
                guard group.location != NSNotFound, let value = Double(ns.substring(with: group)) else { continue }
                if range.contains(value) { return value }
            }
        }
        return nil
    }
}

extension CGImagePropertyOrientation {
    init(_ o: UIImage.Orientation) {
        switch o {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
