import CoreGraphics
import CoreML
import Vision

struct Detection {
    /// Normalised (0...1) to the upright portrait image, origin top-left.
    let rect: CGRect
    let confidence: Float
    /// Found by the centre-zoom pass (about 3× finer than a full-frame box).
    var zoomed = false
}

enum DetectorError: LocalizedError {
    case modelNotFound
    case clayModelNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "No YOLO26 Core ML model found in the app bundle. Run scripts/export_yolo26.py, " +
                "put the .mlpackage in BirdTracker/Models and rebuild."
        case .clayModelNotFound:
            return "This build has no clay-target model yet. It is trained on GitHub by the " +
                "\"Train clay model\" workflow; the next app build includes it."
        }
    }
}

/// Which model to load and which of its classes to keep.
struct DetectorTarget {
    let modelName: String
    let classIndex: Int
    let label: String
    /// Fall back to any other yolo*.mlmodelc in the bundle (not for clays: a bird model would
    /// "find" nothing useful).
    let allowOtherModels: Bool
    let missingError: DetectorError

    /// "bird" is class 14 in the COCO-80 label set that the stock YOLO26 weights use.
    static let bird = DetectorTarget(modelName: AppSettings.modelName, classIndex: 14, label: "bird",
                                     allowOtherModels: true, missingError: .modelNotFound)
    /// Our own one-class model.
    static let clay = DetectorTarget(modelName: AppSettings.clayModelName, classIndex: 0, label: "clay",
                                     allowOtherModels: false, missingError: .clayModelNotFound)

    static func forKind(_ kind: TargetKind) -> DetectorTarget { kind == .bird ? .bird : .clay }
}

/// Runs YOLO26 (Core ML) through Vision and returns detections of one class (birds or clays).
///
/// Handles every output layout Ultralytics can export:
///  • Vision object observations (model exported with an NMS pipeline)
///  • YOLO26 end-to-end / NMS-free tensor  [1, N, 6] = x1, y1, x2, y2, score, class
///  • Classic raw head                      [1, 4 + classes, anchors] (NMS done here)
final class BirdDetector {
    var confidenceThreshold: Float = 0.30
    var iouThreshold: Float = 0.45

    let target: DetectorTarget
    private let request: VNCoreMLRequest
    private let inputSize: CGSize

    init(target: DetectorTarget = .bird) throws {
        self.target = target
        let bundle = Bundle.main
        let all = bundle.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil) ?? []
        let fallback = target.allowOtherModels
            ? all.first(where: { $0.lastPathComponent.lowercased().hasPrefix("yolo") }) : nil
        guard let url = bundle.url(forResource: target.modelName, withExtension: "mlmodelc") ?? fallback else {
            throw target.missingError
        }

        let config = MLModelConfiguration()
        // CPU + Neural Engine, not the GPU: iOS forbids GPU work while the app runs in the
        // background (gun camera with the phone locked in a pocket).
        config.computeUnits = .cpuAndNeuralEngine
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

    /// Full-frame detection plus an optional "centre zoom" pass.
    ///
    /// The full frame is shrunk to the model's 640-px input, so a distant bird becomes only a few
    /// pixels. The zoom pass also runs the model on a square crop around `zoomCentre` (the reticle) at
    /// about the camera's native resolution, which roughly triples the range there. Zoomed detections
    /// replace full-frame ones of the same bird (sharper box, so a better distance).
    ///
    /// - Returns: detections and the zoom square used (normalised, upright image, origin top-left).
    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation,
                imageSize: CGSize, zoomCentre: CGPoint?) -> (detections: [Detection], zoom: CGRect?) {
        var full = detect(in: pixelBuffer, orientation: orientation)
        guard let centre = zoomCentre, let roi = zoomRegion(centre: centre, imageSize: imageSize) else {
            return (full, nil)
        }

        let edge: CGFloat = 0.01
        let zoomed = detect(in: pixelBuffer, orientation: orientation, region: roi).compactMap { d -> Detection? in
            // A bird cut by the crop's edge has a too-small box; the full frame covers it instead.
            let cut = (d.rect.minX < edge && roi.minX > 0.001) || (d.rect.maxX > 1 - edge && roi.maxX < 0.999)
                || (d.rect.minY < edge && roi.minY > 0.001) || (d.rect.maxY > 1 - edge && roi.maxY < 0.999)
            if cut { return nil }
            return Detection(rect: CGRect(x: roi.minX + d.rect.minX * roi.width,
                                          y: roi.minY + d.rect.minY * roi.height,
                                          width: d.rect.width * roi.width,
                                          height: d.rect.height * roi.height),
                             confidence: d.confidence, zoomed: true)
        }
        full.removeAll { f in zoomed.contains { iou($0.rect, f.rect) > 0.3 } }
        return (zoomed + full, roi)
    }

    /// Square of about the model's input size in image pixels, centred on `centre` and kept inside
    /// the image. nil when it would cover most of the picture anyway (no gain).
    private func zoomRegion(centre: CGPoint, imageSize: CGSize) -> CGRect? {
        guard imageSize.width > 0, imageSize.height > 0 else { return nil }
        let side = min(max(inputSize.width, inputSize.height), imageSize.width, imageSize.height)
        let w = side / imageSize.width, h = side / imageSize.height
        guard w * h < 0.6 else { return nil }
        let x = min(max(centre.x - w / 2, 0), 1 - w)
        let y = min(max(centre.y - h / 2, 0), 1 - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// `pixelBuffer` comes straight from the back camera (landscape); `.right` makes
    /// Vision feed the model the upright portrait image.
    /// Other sources (the gun camera) pass their own orientation.
    /// With a `region` (normalised, top-left origin) only that part is analysed and the boxes are
    /// relative to the region.
    func detect(in pixelBuffer: CVPixelBuffer, orientation: CGImagePropertyOrientation = .right,
                region: CGRect? = nil) -> [Detection] {
        if let r = region {
            request.regionOfInterest = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        } else {
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])
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
        guard let label = observation.labels.first(where: { $0.identifier.lowercased() == target.label }),
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
                guard score >= confidenceThreshold, Int(v(5).rounded()) == target.classIndex,
                      let rect = normalise(x1: v(0), y1: v(1), x2: v(2), y2: v(3)) else { continue }
                out.append(Detection(rect: rect, confidence: score))
            }
            return out   // already de-duplicated by the model
        }

        // Raw detection head: (cx, cy, w, h, class scores...) per anchor.
        let channelsFirst = rows < cols
        let channels = channelsFirst ? rows : cols
        let anchors = channelsFirst ? cols : rows
        let scoreIndex = 4 + target.classIndex
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
