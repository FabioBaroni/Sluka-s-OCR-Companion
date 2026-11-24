import Foundation

@main
struct ReadingLanguageTests {
    static func main() {
        for (language, sentence, word) in [
            ("en", "A small book.", "small"),
            ("it", "Leggo un libro.", "libro"),
            ("ar", "هذا كتاب", "كتاب"),
            ("ru", "Это книга.", "книга"),
            ("ko", "작은 책", "책"),
            ("ja", "本を読む", "本"),
        ] {
            let passage = Array(sentence)
            let actual = ReadingLanguage(code: language).wordRanges(in: passage).map { String(passage[$0]) }
            precondition(actual.contains(word), "\(language): \(actual)")
        }
        precondition(ReadingLanguage(code: "zh-Hant").isChinese)
        precondition(!ReadingLanguage(code: "ja").isChinese)
        let chinese = ReadingLanguage(code: "zh-Hans").windowLineFilter()
        let mixedWindow = ["G", "ㅂ", "instagram.com", "乾 Papers: IHTeam", "Greeting in Chinese",
                           "你好！", "Ni hao", "Hello!", "请问您贵姓?", "繁體中文", "早上好 2026"]
        precondition(mixedWindow.filter(chinese) == ["你好！", "请问您贵姓?", "繁體中文", "早上好 2026"])
        let japanese = ReadingLanguage(code: "ja").windowLineFilter()
        precondition(japanese("図書館で本を読みます。") && !japanese("Read this book"))
        let italian = ReadingLanguage(code: "it").windowLineFilter()
        precondition(italian("Questa mattina vorrei leggere un libro in biblioteca."))
        precondition(!italian("This morning I would like to read a book in the library."))
        precondition(italian("Ciao!"), "Keep short text when language identification is uncertain")
        print("Passed whole-window language filtering for mixed Chinese, Japanese, and Italian text")
        print("Passed word boundaries across six study languages")
    }
}
