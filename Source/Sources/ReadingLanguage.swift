import Foundation
import NaturalLanguage

struct ReadingLanguage: Equatable {
    let code: String

    var base: String { code.split(separator: "-").first.map(String.init) ?? code }
    var isChinese: Bool { base == "zh" }
    var name: String {
        if code == "zh-Hans" { return "Chinese (Simplified)" }
        if code == "zh-Hant" { return "Chinese (Traditional)" }
        if code == "yue" { return "Cantonese" }
        return Locale.current.localizedString(forLanguageCode: base) ?? code
    }

    // Sluka's study languages can still use selection and hover when Vision lacks OCR.
    static let studyCodes = ["zh-Hans", "zh-Hant", "yue", "ja", "ko", "th", "fr", "es",
                             "it", "pt", "de", "nl", "sv", "da", "no", "pl", "tr", "id",
                             "fi", "el", "ro", "ru", "uk", "vi", "ar", "en"]

    /// Whole-window OCR includes browser controls and parallel translations.
    /// Filter clear script mismatches and use language identification only
    /// when a line of a shared script gives the recognizer enough evidence.
    func windowLineFilter() -> (String) -> Bool {
        let script: String?
        switch base {
        case "zh", "yue": script = #"\p{sc=Han}"#
        case "ja": script = #"[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}]"#
        case "ko": script = #"\p{sc=Hangul}"#
        case "th": script = #"\p{sc=Thai}"#
        case "ar": script = #"\p{sc=Arabic}"#
        case "el": script = #"\p{sc=Greek}"#
        case "ru", "uk": script = #"\p{sc=Cyrillic}"#
        case "en", "fr", "es", "it", "pt", "de", "nl", "sv", "da", "no", "pl",
             "tr", "id", "fi", "ro", "vi": script = #"\p{sc=Latin}"#
        default: script = nil
        }
        let pattern = script.flatMap { try? NSRegularExpression(pattern: $0) }
        let needsLanguageCheck = script == nil || base == "ru" || base == "uk" || script == #"\p{sc=Latin}"#
        let target = NLLanguage(rawValue: base)
        let recognizer = NLLanguageRecognizer()
        return { text in
            let letterCount = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letterCount > 0 else { return false }
            if let pattern {
                let sameScript = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
                guard sameScript > 0, sameScript >= letterCount - sameScript else { return false }
            }
            guard needsLanguageCheck, letterCount >= 10,
                  text.split(whereSeparator: \.isWhitespace).count >= 2 else { return true }
            recognizer.reset()
            recognizer.processString(text)
            let scores = recognizer.languageHypotheses(withMaximum: 3)
            guard let best = scores.max(by: { $0.value < $1.value }),
                  best.key != target, best.value >= 0.75,
                  best.value - (scores[target] ?? 0) >= 0.45 else { return true }
            return false
        }
    }

    func wordRanges(in passage: [Character]) -> [Range<Int>] {
        let text = String(passage)
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: base))
        var result: [Range<Int>] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].contains(where: \.isLetter) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                result.append(start..<(start + text[range].count))
            }
            return true
        }
        return result
    }

}
