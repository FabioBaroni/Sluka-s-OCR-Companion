import AppKit
import Foundation

@main
struct SlukaStudyTests {
    @MainActor static func main() async throws {
        var openRequests: [Bool] = []
        let study = SlukaStudy { _, _, activates, _ in
            openRequests.append(activates)
            return false
        }
        let launchURL: URL = try await withCheckedThrowingContinuation { ready in
            study.start { ready.resume(with: $0) }
        }
        let reader = TestReader(launchURL: launchURL)
        let shortcuts = CompanionShortcut.allCases
        precondition(Set(shortcuts.map { "\($0.globalModifiers):\($0.key.code)" }).count == shortcuts.count)
        precondition(shortcuts.compactMap(\.grade) == SlukaGrade.allCases)
        let gradeKeys: [String: SlukaGrade] = ["u": .new, "1": .level1, "2": .level2, "3": .level3,
                                              "4": .level4, "k": .known, "i": .ignored]
        for (key, grade) in gradeKeys {
            precondition(grade.cardKey == key && SlukaGrade.fromCardKey(keyDown(key)) == grade)
        }
        precondition(SlukaGrade.fromCardKey(keyDown("U", modifiers: .capsLock)) == .new)
        precondition(SlukaGrade.fromCardKey(keyDown("k", modifiers: .command)) == nil)
        precondition(SlukaGrade.fromCardKey(keyDown("1", repeats: true)) == nil)
        precondition(SlukaGrade.fromCardKey(keyDown("x")) == nil)
        precondition(!SlukaGrade.new.isSelectable(from: 7) && !SlukaGrade.known.isSelectable(from: 5))
        precondition(SlukaGrade.new.isSelectable(from: 5) && SlukaGrade.known.isSelectable(from: 0))
        let characters = Array("这是我的微信")
        let selection = StudySelection(content: .init(context: Segmenter.context(for: 0..<1, in: characters),
                                                       range: characters.indices, choices: ["这", "微信"]), chooseWord: true)
        selection.stepWord(1, choices: selection.choices)
        precondition(selection.word == "这")
        selection.stepWord(-1, choices: selection.choices)
        precondition(selection.word == "微信" && selection.preview.word == "微信")
        precondition(openRequests.isEmpty, "App launch should leave Chrome alone")

        let passage = "The screenshots show OCR Companion captured 戈 correctly, and Sluka had a definition for it in Chrome: ge,"
        study.showCapture(passage, selected: "戈", language: "zh-Hans")
        precondition(study.opening && openRequests == [false])
        study.showCapture(passage, selected: "戈", language: "zh-Hans")
        precondition(openRequests == [false], "A second lookup while connecting must not open another tab")
        let original = try await reader.state(join: true)
        precondition(original.text == passage)
        try await Task.sleep(for: .seconds(3))
        let fallback = try await reader.state()
        precondition(fallback.text == "戈" && fallback.textRevision > original.textRevision)
        precondition(fallback.language == "zh-Hans")

        let stale = try await reader.report(word: "戈", revision: original.textRevision, status: 5)
        precondition(stale == 409, "An earlier capture cannot supply a grade for the isolated word")
        let annotation = try await reader.report(word: "戈", revision: fallback.textRevision, status: 0)
        precondition(annotation == 204)
        try await waitUntil { study.busy }
        let offered = try await reader.state()
        let command = try require(offered.command)
        precondition(command.surface == "戈" && command.textRevision == fallback.textRevision && command.grade == nil)
        let lookup = try await reader.result(command: command)
        precondition(lookup == 204)
        try await waitUntil { study.lookup?.definition == "dagger-axe" && study.status == 0 && study.canGrade }
        study.grade(.level3)
        let gradeOffer = try await reader.state()
        let grade = try require(gradeOffer.command)
        precondition(grade.surface == "戈" && grade.expectedStatus == 0 && grade.grade == 3)
        let applied = try await reader.apply(grade)
        precondition(applied == 204)
        let confirmed = try await reader.report(word: "戈", revision: fallback.textRevision, status: 3)
        precondition(confirmed == 204)
        try await waitUntil { study.status == 3 && study.pendingGrade == nil && study.canGrade }

        study.showCapture("Bonjour et bienvenue", selected: "Bonjour", language: "fr")
        let french = try await reader.state()
        let recognized = try await reader.report(word: "Bonjour", revision: french.textRevision, status: 5)
        precondition(recognized == 204)
        try await waitUntil { study.word?.surface == "Bonjour" }
        try await Task.sleep(for: .seconds(3))
        let preserved = try await reader.state()
        precondition(preserved.textRevision == french.textRevision && preserved.text == french.text)
        print("Passed mixed-language word fallback, grade round-trip, stale revision rejection, and contextual French lookup")

        study.showCapture("这是我的\n微信", selected: "微信", language: "zh-Hans")
        let beforeClick = try await reader.state()
        precondition(beforeClick.command == nil)
        let observed = try await reader.report(word: "微信", revision: beforeClick.textRevision, status: 0)
        precondition(observed == 204)
        try await waitUntil { study.busy }
        let lookupState = try await reader.state()
        let pendingLookup = try require(lookupState.command)
        precondition(pendingLookup.surface == "微信" && pendingLookup.translatesPassage != true)
        precondition(study.canRequestTranslation, "A dictionary lookup must not disable passage translation")
        study.translateSelection()
        study.translateSelection()
        guard case .queued = study.passageTranslation else { throw TestFailure.expectedStateMissing }
        let whileQueued = try await reader.state()
        precondition(whileQueued.command == nil && whileQueued.textRevision == pendingLookup.textRevision)
        let finishedLookup = try await reader.unavailable(pendingLookup)
        precondition(finishedLookup == 204)
        try await waitUntil {
            if case .waiting = study.passageTranslation { return true }
            return false
        }
        let translationState = try await reader.state()
        let translation = try require(translationState.command)
        precondition(translation.translatesPassage == true && translation.grade == nil)
        precondition(translation.surface == "这是我的微信")
        let wrongRevision = try await reader.translation(translation, revision: beforeClick.textRevision)
        precondition(wrongRevision == 409)
        let acceptedTranslation = try await reader.translation(translation)
        precondition(acceptedTranslation == 204)
        try await waitUntil {
            if case .translated("This is my WeChat") = study.passageTranslation { return !study.busy }
            return false
        }
        precondition(!study.canRequestTranslation, "A translated passage cannot be submitted again by its shortcut")
        print("Passed queued passage translation, deduplication, line joining, and stale response rejection")
        let chinese = Array("研究生正在研究生命。")
        let research = WordInContext(word: "研究", passage: chinese, wordRange: 5..<7,
                                     alternatives: ["研究生", "研", "生命", "正在"])
        let hovering = StudySelection(content: .init(context: research, range: chinese.indices,
                                                      choices: ["研究"], pointerIndex: 5), chooseWord: false)
        precondition(hovering.boundaryMatches.map(\.surface) == ["研究", "研究生", "研"])
        let alternate = hovering.boundaryMatches[1]
        hovering.choose(alternate)
        precondition(hovering.isSelected(alternate))
        precondition(hovering.preview.before == "研究生正在" && hovering.preview.word == "研究生")

        let japanese = Array("📚 図書館、図書館で本。")
        let initialGuess = StudySelection(content: .init(context: Segmenter.context(for: 6..<8, in: japanese),
                                                          range: japanese.indices, choices: ["図書"], pointerIndex: 7), chooseWord: false)
        study.showCapture(String(japanese), selected: initialGuess.word, language: "ja", pointerOffset: 8) {
            initialGuess.choose($0)
        }
        let pointing = try await reader.state()
        precondition(pointing.pointerOffset == 8)
        let wrongOccurrence = try await reader.report(word: "図書館", revision: pointing.textRevision,
                                                      status: 0, pointerStart: 3)
        precondition(wrongOccurrence == 409, "A report must cover the actual hovered position")
        let rightOccurrence = try await reader.report(word: "図書館", revision: pointing.textRevision,
                                                      status: 0, pointerStart: 7)
        precondition(rightOccurrence == 204)
        try await waitUntil { study.selected == "図書館" }
        precondition(initialGuess.preview.before == "📚 図書館、" && initialGuess.preview.word == "図書館")
        let corrected = try await reader.state()
        let compoundCommand = try require(corrected.command)
        precondition(compoundCommand.surface == "図書館" && compoundCommand.grade == nil)
        precondition(initialGuess.boundaryMatches.map(\.surface) == ["図書館", "図書"])
        initialGuess.choose(initialGuess.boundaryMatches[1])
        study.choose(initialGuess.word)
        precondition(initialGuess.preview.before == "📚 図書館、" && initialGuess.preview.word == "図書")
        precondition(study.selected == "図書" && !study.canGrade)
        let completedCompound = try await reader.unavailable(compoundCommand)
        precondition(completedCompound == 204)
        try await Task.sleep(for: .milliseconds(2750))
        let isolated = try await reader.state()
        precondition(isolated.text == "図書" && isolated.pointerOffset == nil && !study.canGrade)
        let shortWord = try await reader.report(word: "図書", revision: isolated.textRevision, status: 0)
        precondition(shortWord == 204)
        try await waitUntil { study.busy }
        let reviewed = try await reader.state()
        precondition(reviewed.command?.surface == "図書")
        print("Passed pointer boundaries, overlap correction, exact alternate lookup, and stale-grade protection")

        precondition(openRequests == [false], "Subsequent captures must reuse the connected reader")
        study.connect()
        precondition(openRequests == [false, true], "The explicit action can bring Chrome forward")
        print("Passed one automatic background reader launch and explicit foreground recovery")
    }

    private static func keyDown(_ key: String, modifiers: NSEvent.ModifierFlags = [], repeats: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: 0, context: nil, characters: key, charactersIgnoringModifiers: key,
                         isARepeat: repeats, keyCode: 0)!
    }

    @MainActor private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<40 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TestFailure.expectedStateMissing
    }

    private static func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw TestFailure.expectedStateMissing }
        return value
    }
}

private enum TestFailure: Error { case expectedStateMissing }

private struct TestReader {
    let origin: String
    let key: String
    let id = UUID().uuidString
    let session = URLSession(configuration: .ephemeral)

    init(launchURL: URL) {
        origin = "http://127.0.0.1:\(launchURL.port!)"
        key = String(launchURL.fragment!.dropFirst("session=".count))
    }

    func state(join: Bool = false) async throws -> ReaderSnapshot {
        var request = request("/state")
        request.setValue("compact", forHTTPHeaderField: "X-OCRCompanion-View")
        request.setValue("ready", forHTTPHeaderField: "X-OCRCompanion-Controls")
        if join { request.setValue("1", forHTTPHeaderField: "X-OCRCompanion-Join") }
        let (body, response) = try await session.data(for: request)
        precondition((response as? HTTPURLResponse)?.statusCode == 200)
        return try JSONDecoder().decode(ReaderSnapshot.self, from: body)
    }

    func report(word: String, revision: Int, status: Int, pointerStart: Int? = nil) async throws -> Int {
        var fields: [String: Any] = [
            "textRevision": revision,
            "words": [["surface": word, "key": word, "status": status, "gradeable": true]]
        ]
        if let pointerStart { fields["pointerWord"] = ["surface": word, "start": pointerStart] }
        return try await post("/sluka", fields)
    }

    func result(command: SlukaCommand) async throws -> Int {
        try await post("/sluka-result", [
            "id": command.id, "textRevision": command.textRevision, "outcome": "lookup",
            "lookup": ["surface": "戈", "key": "戈", "reading": "gē", "definition": "dagger-axe", "status": 0]
        ])
    }

    func apply(_ command: SlukaCommand) async throws -> Int {
        let fields: [String: Any] = ["id": command.id, "textRevision": command.textRevision]
        let authorized = try await post("/sluka-commit", fields)
        precondition(authorized == 204)
        return try await post("/sluka-result", fields.merging(["outcome": "applied", "status": 3]) { old, _ in old })
    }

    func unavailable(_ command: SlukaCommand) async throws -> Int {
        try await post("/sluka-result", [
            "id": command.id, "textRevision": command.textRevision, "outcome": "unavailable"
        ])
    }

    func translation(_ command: SlukaCommand, revision: Int? = nil) async throws -> Int {
        try await post("/sluka-result", [
            "id": command.id, "textRevision": revision ?? command.textRevision, "outcome": "translated",
            "translation": "This is my WeChat"
        ])
    }

    private func request(_ route: String) -> URLRequest {
        var request = URLRequest(url: URL(string: origin + route)!, timeoutInterval: 5)
        request.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")
        request.setValue(key, forHTTPHeaderField: "X-OCRCompanion-Session")
        request.setValue(id, forHTTPHeaderField: "X-OCRCompanion-Reader")
        return request
    }

    private func post(_ route: String, _ payload: [String: Any]) async throws -> Int {
        var request = request(route)
        request.httpMethod = "POST"
        request.setValue(origin, forHTTPHeaderField: "Origin")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}
