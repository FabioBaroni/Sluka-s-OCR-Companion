import CoreGraphics
import Vision
import VisionKit

enum ScreenRecognition {
    struct PointerHit {
        let line: Int
        let character: Int?
    }

    struct Output {
        let lines: [ScreenCaptureLine]
        let engine: String
        let pointerHit: PointerHit?
    }

    static func supports(_ language: String) -> Bool {
        supportsPointer(language) ||
            locale(for: language, among: liveTextLanguages) != nil || TesseractOCR.supports(language)
    }

    static func supportsPointer(_ language: String) -> Bool {
        locale(for: language, among: visionLanguages) != nil
    }

    static let visionLanguages: [String] = {
        (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
    }()

    static let liveTextLanguages: [String] = ImageAnalyzer.isSupported ? ImageAnalyzer.supportedTextRecognitionLanguages : []

    static func locale(for language: String, among available: [String]) -> String? {
        if let exact = available.first(where: { $0 == language || $0.hasPrefix(language + "-") }) { return exact }
        guard !language.hasPrefix("zh-") else { return nil }
        let base = language.split(separator: "-").first
        return available.first { $0.split(separator: "-").first == base }
    }

    static func recognize(_ image: CGImage, language: String, bounds: CGRect, point: CGPoint?, allowTesseract: Bool = true) async throws -> Output {
        let visionResult = await Task.detached(priority: .userInitiated) {
            Result { try vision(image, language: language, bounds: bounds, point: point) }
        }.value
        if case .success(let output) = visionResult, !output.lines.isEmpty { return output }
        if point != nil { return try visionResult.get() }

        var liveTextResult: Result<Output, Error>?
        if let locale = locale(for: language, among: liveTextLanguages) {
            var configuration = ImageAnalyzer.Configuration(.text)
            configuration.locales = [locale]
            do {
                let analysis = try await ImageAnalyzer().analyze(image, orientation: .up, configuration: configuration)
                let lines = analysis.transcript.split(whereSeparator: \.isNewline).map {
                    ScreenCaptureLine(text: String($0), bounds: nil, confidence: nil)
                }
                let output = Output(lines: lines, engine: "Apple Live Text", pointerHit: nil)
                if !lines.isEmpty { return output }
                liveTextResult = .success(output)
            } catch {
                liveTextResult = .failure(error)
            }
        }

        // A supported Apple language can still fail for a particular frame.
        if allowTesseract && TesseractOCR.supports(language) {
            let lines = try await Task.detached(priority: .userInitiated) {
                try TesseractOCR.recognize(image, language: language)
            }.value
            return Output(lines: lines, engine: "Tesseract", pointerHit: nil)
        }
        if case .success(let output) = visionResult { return output }
        if let liveTextResult { return try liveTextResult.get() }
        return try visionResult.get()
    }

    private static func vision(_ image: CGImage, language: String, bounds: CGRect, point: CGPoint?) throws -> Output {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = try request.supportedRecognitionLanguages()
        guard let locale = locale(for: language, among: supported) else {
            throw NSError(domain: "OCRCompanion", code: 3)
        }
        request.recognitionLanguages = [locale]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        var lines: [ScreenCaptureLine] = []
        var pointerHit: PointerHit?
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let lineBounds = ScreenGeometry.screenBounds(forNormalizedFrame: observation.boundingBox, in: bounds)
            lines.append(ScreenCaptureLine(text: candidate.string, bounds: lineBounds, confidence: candidate.confidence))
            if pointerHit == nil, let point, lineBounds.contains(point) {
                pointerHit = PointerHit(line: lines.count - 1, character: unambiguousCharacter(in: candidate, at: point, bounds: bounds))
            }
        }
        return Output(lines: lines, engine: "Apple Vision", pointerHit: pointerHit)
    }

    /// Accurate recognition may return the same bounding box for several characters in a word.
    /// Send a focus character only when a single character box matches the pointer.
    private static func unambiguousCharacter(in candidate: VNRecognizedText, at point: CGPoint, bounds: CGRect) -> Int? {
        let string = candidate.string
        guard string.count <= 160 else { return nil }
        var matched: Int?
        for (offset, start) in string.indices.enumerated() {
            let end = string.index(after: start)
            guard let box = try? candidate.boundingBox(for: start..<end),
                  ScreenGeometry.screenBounds(forNormalizedFrame: box.boundingBox, in: bounds).contains(point) else { continue }
            if matched != nil { return nil }
            matched = offset
        }
        return matched
    }
}
