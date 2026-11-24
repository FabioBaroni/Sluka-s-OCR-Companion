import CoreGraphics
import Foundation

struct ScreenCaptureLine {
    let text: String
    let bounds: CGRect?
    let confidence: Float?
}

struct ScreenCaptureResult {
    let text: String
    let language: String
    let sourceName: String?
    /// Anchor and line bounds use global AppKit screen points, with the origin at the lower left.
    let anchor: CGRect
    let lines: [ScreenCaptureLine]
    let focusText: String?
    let context: String?
    let sourceDescription: String
}

enum CapturedPassages {
    static func sections(in lines: [ScreenCaptureLine], limit: Int) -> [String] {
        precondition(limit > 0)
        return lines.flatMap { line -> [String] in
            var result: [String] = []
            var remaining = line.text[...]
            while !remaining.isEmpty {
                let prefix = remaining.prefix(limit)
                let boundary = prefix.endIndex != remaining.endIndex
                    ? prefix.lastIndex(where: \.isWhitespace).flatMap { $0 == prefix.startIndex ? nil : $0 }
                    : nil
                let end = boundary ?? prefix.endIndex
                let text = remaining[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
                if text.contains(where: \.isLetter) { result.append(text) }
                remaining = remaining[end...].drop(while: \.isWhitespace)
            }
            return result
        }
    }
}
