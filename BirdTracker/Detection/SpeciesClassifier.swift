import CoreGraphics
import CoreML
import Vision

/// Identifies the species of a detected bird by classifying a crop around its box.
/// Model: chriamue/bird-species-classifier (EfficientNet-B2, 525 species), exported by
/// scripts/export_species.py as BirdSpecies.mlpackage.
final class SpeciesClassifier {
    struct Guess {
        let label: String        // raw model label, e.g. "ROCK DOVE"
        let confidence: Float
    }

    private let request: VNCoreMLRequest

    /// Returns nil when the model is not in the bundle (species recognition is then simply off).
    init?(modelName: String = "BirdSpecies") {
        guard let url = Bundle.main.url(forResource: modelName, withExtension: "mlmodelc") else { return nil }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let model = try? MLModel(contentsOf: url, configuration: config),
              let vnModel = try? VNCoreMLModel(for: model) else { return nil }
        request = VNCoreMLRequest(model: vnModel)
        request.imageCropAndScaleOption = .scaleFill
    }

    /// - Parameters:
    ///   - rect: normalised bird box in the upright image, origin top-left.
    /// - Returns: the top guesses, best first.
    func classify(_ pixelBuffer: CVPixelBuffer, rect: CGRect, imageSize: CGSize, top: Int = 10) -> [Guess] {
        // Square crop with some margin: the model was trained on roughly centred, square photos.
        let w = Double(imageSize.width), h = Double(imageSize.height)
        let side = max(Double(rect.width) * w, Double(rect.height) * h) * 1.3
        let cx = Double(rect.midX) * w, cy = Double(rect.midY) * h
        var crop = CGRect(x: (cx - side / 2) / w, y: (cy - side / 2) / h, width: side / w, height: side / h)
        crop = crop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { return [] }

        // Vision's region of interest uses a bottom-left origin.
        request.regionOfInterest = CGRect(x: crop.minX, y: 1 - crop.maxY, width: crop.width, height: crop.height)

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let results = (request.results as? [VNClassificationObservation]) ?? []
        return results.prefix(top).map { Guess(label: $0.identifier, confidence: $0.confidence) }
    }
}
