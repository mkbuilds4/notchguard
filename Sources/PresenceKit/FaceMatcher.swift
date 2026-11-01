import CoreImage
import CoreML
import CoreVideo
import Foundation
import Vision

/// Finds faces with Apple Vision, aligns each one to the ArcFace 112x112 template,
/// and turns it into a 512-d MobileFaceNet embedding.
final class FaceMatcher {
    private let model: MLModel
    private let ci = CIContext(options: [.cacheIntermediates: false])

    // ArcFace reference points (left eye, right eye, nose, left mouth, right mouth) on a 112x112 crop.
    private static let template: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    init() throws {
        guard let url = FaceMatcher.modelURL else {
            throw NSError(domain: "NotchGuard", code: 1, userInfo: [NSLocalizedDescriptionKey: "face model not installed"])
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: cfg)
    }

    /// The compiled model: inside the host app's bundle, or installed under Application Support.
    static var modelURL: URL? {
        if let u = Bundle.main.url(forResource: "FaceEmbedder", withExtension: "mlmodelc") { return u }
        let u = Paths.support.appendingPathComponent("FaceEmbedder.mlmodelc")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    struct Face {
        let embedding: [Float]
        let bounds: CGRect // normalized, Vision coordinates
    }

    /// Every face in the frame that has enough landmarks to align.
    func faces(in pixelBuffer: CVPixelBuffer) -> [Face] {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        let size = CGSize(width: width, height: height)
        let image = CIImage(cvPixelBuffer: pixelBuffer)

        return (request.results ?? []).compactMap { obs in
            guard let pts = landmarks(obs, imageSize: size),
                  let crop = alignedCrop(image, imageHeight: CGFloat(height), points: pts),
                  let emb = embed(crop) else { return nil }
            return Face(embedding: emb, bounds: obs.boundingBox)
        }
    }

    /// Cheap per-frame liveness signals for the largest face (no embedding).
    struct Probe {
        /// Eye opening height/width, both eyes averaged; dips during a blink.
        let eyeOpen: Float
        /// ln(R/B) on the face minus ln(R/B) on the background corners. Comparing the two
        /// cancels the camera's own white balance, so what's left is light reflected off the face.
        let tint: Float
        /// Normalized Vision box of the face.
        let box: CGRect
    }

    func probe(_ pixelBuffer: CVPixelBuffer) -> Probe? {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        guard let obs = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = obs.landmarks, let l = lm.leftEye, let r = lm.rightEye else { return nil }
        func openness(_ eye: VNFaceLandmarkRegion2D) -> Float {
            let p = eye.normalizedPoints
            let w = (p.map(\.x).max() ?? 0) - (p.map(\.x).min() ?? 0)
            let h = (p.map(\.y).max() ?? 0) - (p.map(\.y).min() ?? 0)
            return w > 0 ? Float(h / w) : 0
        }
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let box = VNImageRectForNormalizedRect(obs.boundingBox, Int(width), Int(height))
        let face = average(image, box.insetBy(dx: box.width * 0.2, dy: box.height * 0.2))
        let bgL = average(image, CGRect(x: 0, y: height * 0.75, width: width * 0.2, height: height * 0.25))
        let bgR = average(image, CGRect(x: width * 0.8, y: height * 0.75, width: width * 0.2, height: height * 0.25))
        func rb(_ c: SIMD3<Float>) -> Float { log(max(c.x, 1e-3) / max(c.z, 1e-3)) }
        return Probe(eyeOpen: (openness(l) + openness(r)) / 2, tint: rb(face) - (rb(bgL) + rb(bgR)) / 2, box: obs.boundingBox)
    }

    /// Head direction as the nose's offset from the eyes' midpoint, in face widths, mirrored to match a selfie
    /// view (positive x = your right, positive y = up). Compare against a straight-on baseline.
    func pose(_ pixelBuffer: CVPixelBuffer) -> CGPoint? {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        guard let obs = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }),
              let lm = obs.landmarks, let l = lm.leftEye, let r = lm.rightEye,
              let nose = lm.noseCrest?.normalizedPoints.min(by: { $0.y < $1.y }) ?? lm.nose?.normalizedPoints.first
        else { return nil }
        func c(_ p: [CGPoint]) -> CGPoint { CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count)) }
        let el = c(l.normalizedPoints), er = c(r.normalizedPoints)
        let eyes = CGPoint(x: (el.x + er.x) / 2, y: (el.y + er.y) / 2)
        return CGPoint(x: -(nose.x - eyes.x), y: nose.y - eyes.y)
    }

    /// A phone or tablet held up to the camera: a device-shaped rectangle that mostly contains the face.
    /// Adapted from Glance's DeviceBezelDetector (github.com/jonnyoo/glance, MIT).
    func deviceAround(_ pixelBuffer: CVPixelBuffer, face: CGRect) -> Bool {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        // Fraction of the frame's shorter side: a phone held at arm's length is only ~10% of the image area.
        request.minimumSize = 0.08
        request.maximumObservations = 6
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1.0
        request.quadratureTolerance = 30
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
        let faceArea = face.width * face.height
        guard faceArea > 0 else { return false }
        // Any device-shaped rectangle that contains most of the face and is clearly bigger than it
        // (not just the face's own outline) means a screen is being held up.
        return (request.results ?? []).map(\.boundingBox).contains { device in
            let inter = device.intersection(face)
            return (inter.width * inter.height) / faceArea > 0.8 && device.width * device.height > faceArea * 1.5
        }
    }

    private func average(_ image: CIImage, _ rect: CGRect) -> SIMD3<Float> {
        guard let f = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: rect)]),
              let out = f.outputImage else { return .zero }
        var px = [UInt8](repeating: 0, count: 4)
        ci.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return SIMD3(Float(px[0]), Float(px[1]), Float(px[2])) / 255
    }

    /// Five points in top-left-origin pixel coordinates, ordered like `template`.
    private func landmarks(_ obs: VNFaceObservation, imageSize: CGSize) -> [CGPoint]? {
        guard let lm = obs.landmarks else { return nil }
        func pts(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint]? {
            guard let r, r.pointCount > 0 else { return nil }
            return r.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
        }
        func centroid(_ p: [CGPoint]) -> CGPoint {
            CGPoint(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count))
        }
        guard let eyeA = pts(lm.leftPupil).map(centroid) ?? pts(lm.leftEye).map(centroid),
              let eyeB = pts(lm.rightPupil).map(centroid) ?? pts(lm.rightEye).map(centroid),
              let nose = pts(lm.noseCrest)?.max(by: { $0.y < $1.y }) ?? pts(lm.nose).map(centroid),
              let lips = pts(lm.outerLips) else { return nil }
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        let mouthL = lips.min { $0.x < $1.x }!, mouthR = lips.max { $0.x < $1.x }!
        return [eyes[0], eyes[1], nose, mouthL, mouthR]
    }

    /// Least-squares similarity transform from `points` onto the template, rendered to 112x112 BGRA.
    private func alignedCrop(_ image: CIImage, imageHeight: CGFloat, points src: [CGPoint]) -> CVPixelBuffer? {
        let dst = Self.template
        let n = CGFloat(src.count)
        let ms = CGPoint(x: src.map(\.x).reduce(0, +) / n, y: src.map(\.y).reduce(0, +) / n)
        let md = CGPoint(x: dst.map(\.x).reduce(0, +) / n, y: dst.map(\.y).reduce(0, +) / n)
        var num1: CGFloat = 0, num2: CGFloat = 0, den: CGFloat = 0
        for (s, d) in zip(src, dst) {
            let sx = s.x - ms.x, sy = s.y - ms.y, dx = d.x - md.x, dy = d.y - md.y
            num1 += sx * dx + sy * dy
            num2 += sx * dy - sy * dx
            den += sx * sx + sy * sy
        }
        guard den > 0 else { return nil }
        let a = num1 / den, b = num2 / den
        // Top-left coords: x' = a x - b y + tx, y' = b x + a y + ty
        let t = CGAffineTransform(a: a, b: b, c: -b, d: a,
                                  tx: md.x - (a * ms.x - b * ms.y),
                                  ty: md.y - (b * ms.x + a * ms.y))
        // Core Image is bottom-left origin: flip in, transform, flip out.
        let flipIn = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: imageHeight)
        let flipOut = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 112)
        let ciT = flipIn.concatenating(t).concatenating(flipOut)
        let out = image.transformed(by: ciT).cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112))

        var pb: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        CVPixelBufferCreate(nil, 112, 112, kCVPixelFormatType_32BGRA, attrs, &pb)
        guard let pb else { return nil }
        ci.render(out, to: pb, bounds: CGRect(x: 0, y: 0, width: 112, height: 112), colorSpace: CGColorSpaceCreateDeviceRGB())
        return pb
    }

    private func embed(_ crop: CVPixelBuffer) -> [Float]? {
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["face": MLFeatureValue(pixelBuffer: crop)]),
              let out = try? model.prediction(from: input),
              let arr = out.featureValue(for: "embedding")?.multiArrayValue else { return nil }
        var v = (0..<arr.count).map { arr[$0].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in v.indices { v[i] /= norm }
        return v
    }
}

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    zip(a, b).reduce(0) { $0 + $1.0 * $1.1 } // both unit-length
}

/// The enrolled face: every sample kept, matched by best cosine against any of them.
public struct Profile: Codable {
    var samples: [[Float]]
    var createdAt: Date
    /// Recent confident, live-checked matches, so the profile follows a growing beard or new glasses.
    /// Enrollment `samples` are never replaced.
    var learned: [[Float]] = []
    var lastLearned: Date?

    static let maxLearned = 40

    func score(_ e: [Float]) -> Float { (samples + learned).map { cosine($0, e) }.max() ?? -1 }

    enum CodingKeys: String, CodingKey { case samples, createdAt, learned, lastLearned }
    init(samples: [[Float]], createdAt: Date) { self.samples = samples; self.createdAt = createdAt }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        samples = try c.decode([[Float]].self, forKey: .samples)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        learned = try c.decodeIfPresent([[Float]].self, forKey: .learned) ?? []
        lastLearned = try c.decodeIfPresent(Date.self, forKey: .lastLearned)
    }

    /// Adds a look if it's been a while since the last one; oldest learned look drops off past the cap.
    mutating func learn(_ e: [Float], every interval: TimeInterval) -> Bool {
        if let last = lastLearned, Date().timeIntervalSince(last) < interval { return false }
        learned.append(e)
        if learned.count > Self.maxLearned { learned.removeFirst(learned.count - Self.maxLearned) }
        lastLearned = Date()
        return true
    }

    public static func load() -> Profile? {
        guard let d = try? Data(contentsOf: Paths.profile) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: d)
    }

    func save() throws {
        try JSONEncoder().encode(self).write(to: Paths.profile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.profile.path)
    }
}
