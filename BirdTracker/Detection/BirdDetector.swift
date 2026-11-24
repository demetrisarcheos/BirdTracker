import CoreGraphics
import CoreML
import Vision

struct Detection {
    /// Normalised (0...1) to the upright portrait image, origin top-left.
    let rect: CGRect
    let confidence: Float
}

enum DetectorError: LocalizedError {
    case modelNotFound

    var errorDescription: String? {
        "No YOLO26 Core ML model found in the app bundle. Run scripts/export_yolo26.py, " +
        "put the .mlpackage in BirdTracker/Models and rebuild."
    }
}

/// Runs YOLO26 (Core ML) through Vision and returns bird detections only.
///
/// Handles every output layout Ultralytics can export:
///  • Vision object observations (model exported with an NMS pipeline)
///  • YOLO26 end-to-end / NMS-free tensor  [1, N, 6] = x1, y1, x2, y2, score, class
///  • Classic raw head                      [1, 4 + classes, anchors] (NMS done here)
final class BirdDetector {
    /// "bird" is class 14 in the COCO-80 label set that the stock YOLO26 weights use.
    static let cocoBirdClass = 14

    var confidenceThreshold: Float = 0.30
    var iouThreshold: Float = 0.45

    private let request: VNCoreMLRequest
    private let inputSize: CGSize

    init(preferredModelName: String = "yolo26n") throws {
        let bundle = Bundle.main
        let all = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        guard let url = bundle.url(forResource: preferredModelName, withExtension: "mlmodelc")
                ?? all.first(where: { $0.lastPathComponent.lowercased().hasPrefix("yolo") })
                ?? all.first else {
            throw DetectorError.modelNotFound
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all          // Neural Engine when available
        let model = try MLModel(contentsOf: url, configuration: config)
        inputSize = Self.imageInputSize(of: model) ?? CGSize(width: 640, height: 640)

        request = VNCoreMLRequest(model: try VNCoreMLModel(for: model))
        request.imageCropAndScaleOption = .scaleFill
    }

    private static func imageInputSize(of model: MLModel) -> CGSize? {
        for (_, description) in model.modelDescription.inputDescriptionsByName {
            if let c = description.imageConstraint {
                return CGSize(width: c.pixelsWide, height: c.pixelsHigh)
            }
        }
        return nil
    }

    /// `pixelBuffer` comes straight from the back camera (landscape); `.right` makes
    /// Vision feed the model the upright portrait image.
    func detect(in pixelBuffer: CVPixelBuffer) -> [Detection] {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let results = request.results ?? []

        let objects = results.compactMap { $0 as? VNRecognizedObjectObservation }
        if !objects.isEmpty { return objects.compactMap(detection(from:)) }

        for case let observation as VNCoreMLFeatureValueObservation in results {
            if let array = observation.featureValue.multiArrayValue { return decode(array) }
        }
        return []
    }

    // MARK: - Vision observations

    private func detection(from observation: VNRecognizedObjectObservation) -> Detection? {
        guard let label = observation.labels.first(where: { $0.identifier.lowercased() == "bird" }),
              label.confidence >= confidenceThreshold else { return nil }
        let b = observation.boundingBox                    // bottom-left origin
        return Detection(rect: CGRect(x: b.minX, y: 1 - b.maxY, width: b.width, height: b.height),
                         confidence: label.confidence)
    }

    // MARK: - Raw tensors

    private func decode(_ array: MLMultiArray) -> [Detection] {
        let shape = array.shape.map(\.intValue)
        guard shape.count >= 2 else { return [] }
        let t = TensorReader(array)
        let rows = shape[shape.count - 2]
        let cols = shape[shape.count - 1]

        // YOLO26 end-to-end (NMS-free) output.
        if cols == 6 || rows == 6 {
            let transposed = (rows == 6 && cols != 6)
            let n = transposed ? cols : rows
            var out: [Detection] = []
            for i in 0..<n {
                func v(_ k: Int) -> Float { transposed ? t[k, i] : t[i, k] }
                let score = v(4)
                guard score >= confidenceThreshold, Int(v(5).rounded()) == Self.cocoBirdClass,
                      let rect = normalise(x1: v(0), y1: v(1), x2: v(2), y2: v(3)) else { continue }
                out.append(Detection(rect: rect, confidence: score))
            }
            return out   // already de-duplicated by the model
        }

        // Raw detection head: (cx, cy, w, h, class scores...) per anchor.
        let channelsFirst = rows < cols
        let channels = channelsFirst ? rows : cols
        let anchors = channelsFirst ? cols : rows
        let scoreIndex = 4 + Self.cocoBirdClass
        guard channels > scoreIndex else { return [] }

        var candidates: [Detection] = []
        for i in 0..<anchors {
            func v(_ k: Int) -> Float { channelsFirst ? t[k, i] : t[i, k] }
            let score = v(scoreIndex)
            guard score >= confidenceThreshold else { continue }
            let cx = v(0), cy = v(1), w = v(2), h = v(3)
            if let rect = normalise(x1: cx - w / 2, y1: cy - h / 2, x2: cx + w / 2, y2: cy + h / 2) {
                candidates.append(Detection(rect: rect, confidence: score))
            }
        }
        return nonMaxSuppression(candidates)
    }

    private func normalise(x1: Float, y1: Float, x2: Float, y2: Float) -> CGRect? {
        let isNormalised = max(abs(x1), abs(y1), abs(x2), abs(y2)) <= 1.5
        let sx: CGFloat = isNormalised ? 1 : inputSize.width
        let sy: CGFloat = isNormalised ? 1 : inputSize.height
        let minX = max(0, min(1, CGFloat(x1) / sx)), maxX = max(0, min(1, CGFloat(x2) / sx))
        let minY = max(0, min(1, CGFloat(y1) / sy)), maxY = max(0, min(1, CGFloat(y2) / sy))
        guard maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func nonMaxSuppression(_ detections: [Detection]) -> [Detection] {
        var kept: [Detection] = []
        for d in detections.sorted(by: { $0.confidence > $1.confidence })
        where kept.allSatisfy({ iou($0.rect, d.rect) < CGFloat(iouThreshold) }) {
            kept.append(d)
        }
        return kept
    }

    private func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull else { return 0 }
        let inter = i.width * i.height
        return inter / (a.width * a.height + b.width * b.height - inter)
    }
}

/// Fast typed access to the last two dimensions of an MLMultiArray (batch dim ignored).
private struct TensorReader {
    let array: MLMultiArray
    let rowStride: Int
    let colStride: Int

    init(_ array: MLMultiArray) {
        self.array = array
        let strides = array.strides.map(\.intValue)
        rowStride = strides[strides.count - 2]
        colStride = strides[strides.count - 1]
    }

    subscript(_ i: Int, _ j: Int) -> Float {
        let offset = i * rowStride + j * colStride
        switch array.dataType {
        case .float32: return array.dataPointer.assumingMemoryBound(to: Float.self)[offset]
        case .float16: return Float(array.dataPointer.assumingMemoryBound(to: Float16.self)[offset])
        case .double:  return Float(array.dataPointer.assumingMemoryBound(to: Double.self)[offset])
        default:       return array[offset].floatValue
        }
    }
}
