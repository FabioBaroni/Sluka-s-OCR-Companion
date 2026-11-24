import AppKit
import OSLog
import SwiftUI

@MainActor
final class SlukaStudy: ObservableObject {
    enum PassageTranslation {
        case idle, queued, waiting, translated(String), unavailable
    }

    private let server = ReaderServer()
    typealias ReaderOpener = (URL, _ connected: Bool, _ activates: Bool, _ onError: @escaping (String) -> Void) -> Bool
    private let showReader: ReaderOpener
    private var attemptedReaderConnection = false
    private let translationLog = Logger(subsystem: "local.ocrcompanion.reader", category: "Translation")
    private let timing = OSSignposter(subsystem: "local.ocrcompanion.reader", category: "Lookup")
    private var url: URL?
    private var revision = 0
    private var passage = ""
    private var language = ""
    private var isolatedWord: String?
    private var pointerOffset: Int?
    private var onPointerWord: ((SlukaObservation.PointerWord) -> Void)?
    private var passageWords: [String] = []
    private var attempted: Set<String> = []
    private var retried: Set<String> = []
    private var cached: [String: SlukaObservation.Lookup] = [:]
    private var confirmed: [String: Int] = [:]
    @Published private(set) var opening = false
    @Published private(set) var waitingForWords = false
    @Published private(set) var noDefinition = false
    private var annotationWait: Task<Void, Never>?
    private var isolationWait: Task<Void, Never>?
    private var connectionWait: Task<Void, Never>?

    @Published private(set) var words: [SlukaObservation.Word] = []
    @Published private var ambiguousSurfaces: Set<String> = []
    @Published private(set) var selected = ""
    @Published private(set) var lookup: SlukaObservation.Lookup?
    @Published private(set) var pendingGrade: SlukaGrade?
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var passageTranslation = PassageTranslation.idle
    var connected: Bool { server.hasRecentStudyView() }
    var word: SlukaObservation.Word? { words.first { $0.surface == selected } }
    var hasUnresolvedBoundary: Bool { isolationWait != nil && isolatedWord == nil }
    var isIsolatedLookup: Bool { isolatedWord != nil }
    var selectionIsAmbiguous: Bool { ambiguousSurfaces.contains(selected) }
    var status: Int? { word.map { confirmed[$0.key] ?? $0.status } }
    var expectsFullDictionaryCard: Bool { (status ?? 0) >= 5 }
    var canGrade: Bool { connected && word?.gradeable == true && !busy && status == word?.status }
    func canSetGrade(_ grade: SlukaGrade) -> Bool { canGrade && grade.isSelectable(from: status) }

    var hasTranslatablePassage: Bool { passage.lazy.filter(\.isLetter).prefix(2).count == 2 }
    var canRequestTranslation: Bool {
        guard pendingGrade == nil, connected, hasTranslatablePassage else { return false }
        switch passageTranslation {
        case .idle, .unavailable: return true
        case .queued, .waiting, .translated: return false
        }
    }

    init(showReader: ReaderOpener? = nil) {
        self.showReader = showReader ?? SlukaBrowser().show
    }

    func choices(fallingBackTo local: [String]) -> [String] {
        let annotated = words.map(\.surface)
        var seen: Set<String> = []
        return (annotated + passageWords + local).filter { seen.insert($0).inserted }
    }

    func start(onReady: ((Result<URL, Error>) -> Void)? = nil) {
        server.onSlukaObservation = { [weak self] observation in
            DispatchQueue.main.async { self?.receive(observation) }
        }
        server.onStudyViewChanged = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.opening = false
                self.words = []
                self.ambiguousSurfaces = []
                self.lookup = nil
                self.cached = [:]
                self.confirmed = [:]
                self.attempted = []
                self.retried = []
                self.noDefinition = false
                self.waitForAnnotation()
                self.scheduleWordFallback()
                self.objectWillChange.send()
            }
        }
        do {
            try server.start { [weak self] result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let url):
                        self?.url = url
                        self?.connectAutomatically()
                    case .failure: self?.message = "The Sluka connection could not start."
                    }
                    onReady?(result)
                }
            }
        } catch {
            message = "The Sluka connection could not start."
            onReady?(.failure(error))
        }
    }

    func showCapture(_ text: String, selected: String, language: String, pointerOffset: Int? = nil,
                     onPointerWord: ((SlukaObservation.PointerWord) -> Void)? = nil) {
        self.pointerOffset = pointerOffset
        self.onPointerWord = onPointerWord
        passage = text
        self.language = language
        self.selected = selected
        passageWords = []
        passageTranslation = .idle
        publishForStudy()
        connectAutomatically()
    }

    private func publishForStudy(isolating surface: String? = nil) {
        isolationWait?.cancel()
        isolatedWord = surface
        server.publish(text: surface ?? passage, status: "Latest Mac lookup", language: language,
                       refreshIfUnannotated: surface != nil || passage == selected,
                       pointerOffset: surface == nil ? pointerOffset : nil)
        revision = server.currentTextRevision()
        words = []
        ambiguousSurfaces = []
        lookup = nil
        pendingGrade = nil
        busy = false
        attempted = []
        retried = []
        cached = [:]
        confirmed = [:]
        noDefinition = false
        message = ""
        waitForAnnotation()
        scheduleWordFallback()
    }

    func choose(_ surface: String) {
        guard pendingGrade == nil else { return }
        pointerOffset = nil
        onPointerWord = nil
        if updateSelection(surface) {
            if isolatedWord != nil && word == nil {
                publishForStudy()
                if case .queued = passageTranslation { sendTranslation() }
            } else {
                scheduleWordFallback()
            }
        }
        autoLookup()
    }

    @discardableResult
    private func updateSelection(_ surface: String) -> Bool {
        guard selected != surface else { return false }
        selected = surface
        noDefinition = false
        message = ""
        lookup = word.flatMap { cached[$0.key] }.flatMap { $0.surface == surface ? $0 : nil }
        return true
    }

    private func receive(_ observation: SlukaObservation) {
        guard observation.textRevision == revision else { return }
        let old = words
        words = observation.words
        ambiguousSurfaces = Set(observation.ambiguousSurfaces ?? [])
        if pointerOffset != nil, pendingGrade == nil, isolatedWord == nil, let boundary = observation.pointerWord {
            updateSelection(boundary.surface)
            onPointerWord?(boundary)
            pointerOffset = nil
            onPointerWord = nil
        }
        if word != nil { isolationWait?.cancel(); isolationWait = nil }
        if !words.isEmpty { waitingForWords = false }
        for item in words where confirmed[item.key] != nil {
            if confirmed[item.key] == item.status || old.first(where: { $0.key == item.key })?.status != item.status {
                confirmed[item.key] = nil
            }
        }
        if let lookup = observation.lookup, lookup.surface == selected {
            cached[lookup.key] = lookup
            self.lookup = lookup
            if !lookup.definition.isEmpty { noDefinition = false }
        }
        if word == nil { lookup = nil }
        message = opening ? "" : message
        autoLookup()
    }

    private func waitForAnnotation() {
        annotationWait?.cancel()
        waitingForWords = connected && words.isEmpty
        guard waitingForWords else { return }
        annotationWait = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled { self?.waitingForWords = false }
        }
    }

    private func scheduleWordFallback() {
        isolationWait?.cancel()
        isolationWait = nil
        switch passageTranslation {
        case .queued, .waiting: return
        default: break
        }
        let surface = selected
        guard connected, word == nil, !selectionIsAmbiguous, isolatedWord == nil, !surface.isEmpty,
              surface != passage, passage.contains(surface), surface.utf16.count <= 64 else { return }
        let revision = self.revision
        isolationWait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(2500))
            guard !Task.isCancelled, let self, self.revision == revision, self.selected == surface,
                  self.connected, self.word == nil, !self.selectionIsAmbiguous else { return }
            self.passageWords = self.words.map(\.surface)
            self.publishForStudy(isolating: surface)
        }
    }

    func connect() { openSluka(recover: true) }

    private func connectAutomatically() {
        guard url != nil, !passage.isEmpty, !connected, !attemptedReaderConnection else { return }
        openSluka(recover: true, activates: false)
    }

    private func openSluka(recover: Bool, activates: Bool = true) {
        guard let url else { message = "The Sluka connection is starting. Try again in a moment."; return }
        attemptedReaderConnection = true
        opening = recover
        connectionWait?.cancel()
        if opening {
            connectionWait = Task { [weak self] in
                try? await Task.sleep(for: .seconds(9))
                guard !Task.isCancelled, let self, self.opening else { return }
                self.opening = false
                self.message = "The Sluka tab didn’t connect. Open it again in the Chrome profile that has Sluka."
            }
        }
        message = ""
        let reused = showReader(url, connected, activates) { [weak self] message in
            self?.opening = false
            self?.message = message
        }
        if reused && connected { opening = false; connectionWait?.cancel() }
    }

    private func autoLookup() {
        guard let word, lookup == nil, !busy, attempted.insert(word.surface).inserted else { return }
        send(grade: nil, automatic: true)
    }

    func retryLookup() { send(grade: nil, automatic: false) }
    func grade(_ grade: SlukaGrade) {
        guard canSetGrade(grade) else { return }
        send(grade: grade, automatic: false)
    }

    func translateSelection() {
        guard canRequestTranslation else { return }
        isolationWait?.cancel()
        if busy {
            // The reader handles one command at a time. Keep this explicit request
            // with the current capture and start it before any automatic retry.
            passageTranslation = .queued
        } else {
            sendTranslation()
        }
    }

    private func sendTranslation() {
        guard connected else {
            passageTranslation = .unavailable
            return
        }
        // Keep the original OCR lines in the Mac card. Sluka's selection
        // runs inside a single paragraph and can't span HTML blocks.
        let joined = passage.replacingOccurrences(of: "(?<=\\p{Han})[\\r\\n]+(?=\\p{Han})",
                                                   with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        if isolatedWord != nil || joined != passage {
            pointerOffset = nil
            onPointerWord = nil
            passage = joined
            publishForStudy()
        }
        isolationWait?.cancel()
        busy = true
        passageTranslation = .waiting
        let revision = self.revision
        server.requestTranslation(passage, revision: revision) { [weak self] outcome, result in
            DispatchQueue.main.async {
                guard let self, self.revision == revision else { return }
                self.busy = false
                if outcome == .translated, let translation = result?.translation {
                    self.passageTranslation = .translated(translation)
                } else {
                    self.translationLog.info("Sluka passage translation ended with \(outcome.rawValue, privacy: .public)")
                    self.passageTranslation = .unavailable
                }
                self.scheduleWordFallback()
                self.autoLookup()
            }
        }
    }

    private func send(grade: SlukaGrade?, automatic: Bool) {
        guard let word, !busy else { return }
        if grade == nil { noDefinition = false }
        busy = true
        pendingGrade = grade
        message = ""
        let revision = self.revision
        let timing = self.timing
        let interval = timing.beginInterval("Sluka command")
        server.requestSluka(word, revision: revision, grade: grade?.rawValue, mayWake: !automatic) { [weak self] outcome, result in
            timing.endInterval("Sluka command", interval)
            DispatchQueue.main.async {
                guard let self, self.revision == revision else { return }
                self.busy = false
                self.pendingGrade = nil
                if let lookup = result?.lookup {
                    self.cached[lookup.key] = lookup
                    if self.selected == lookup.surface { self.lookup = lookup }
                }
                if outcome == .applied || outcome == .unchanged, let status = result?.status,
                   self.words.first(where: { $0.key == word.key })?.status != status {
                    self.confirmed[word.key] = status
                }
                if grade == nil && self.selected == word.surface {
                    self.noDefinition = outcome == .noDefinition || (outcome == .lookup && result?.lookup?.definition.isEmpty == true)
                }
                if !automatic && self.selected == word.surface &&
                    ![.lookup, .noDefinition, .applied, .unchanged].contains(outcome) {
                    if grade != nil {
                        self.message = "Sluka didn’t confirm this grade. Check the current grade before trying again."
                    } else {
                        self.message = "Sluka’s definition didn’t load."
                    }
                }
                let shouldRetryLookup = automatic && outcome == .unavailable && self.retried.insert(word.surface).inserted
                if case .queued = self.passageTranslation {
                    if shouldRetryLookup { self.attempted.remove(word.surface) }
                    self.sendTranslation()
                    return
                }
                if shouldRetryLookup {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(1))
                        guard let self, self.revision == revision, self.selected == word.surface,
                              self.lookup == nil, self.connected, !self.busy else { return }
                        self.attempted.remove(word.surface)
                        self.autoLookup()
                    }
                }
                self.autoLookup()
            }
        } wake: { [weak self] in
            DispatchQueue.main.async { self?.openSluka(recover: false) }
        }
    }
}

struct StudyCard: View {
    @ObservedObject var study: SlukaStudy
    @ObservedObject var reader: StudySelection
    let sections: [String]
    let allowsTranslation: Bool
    var announcesLookup = false
    let onSectionChange: (Int) -> Void
    @State private var section = 0
    @State private var showsBoundaryMatches = false
    @State private var matchGlosses: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ActionSlot(centerAboveBaseline: 12)
            if sections.count > 1 {
                Picker("Captured passage", selection: $section) {
                    ForEach(sections.indices, id: \.self) { index in
                        Text("\(index + 1). \(String(sections[index].prefix(55)))").tag(index)
                    }
                }
                .pickerStyle(.menu)
                .disabled(study.pendingGrade != nil)
                .onChange(of: section) { _, index in onSectionChange(index) }
            }
            if reader.isPassage || allowsTranslation || !sections.isEmpty ||
                (reader.isPointerLookup && reader.preview.word != String(reader.passage)) {
                capturedPassage
                if allowsTranslation && study.hasTranslatablePassage { passageTranslation }
            }
            if reader.isPassage || (showSlukaAlternatives && reader.boundaryMatches.count < 2) { wordPicker }
            if reader.boundaryMatches.count > 1 { boundaryPicker }
            if !reader.word.isEmpty { wordDetails }
            if let explanation { lookupStatus(explanation) }
            if study.word?.gradeable == true {
                SlukaGradeBar(status: study.status, pending: study.pendingGrade,
                              isEnabled: study.canGrade, onGrade: study.grade)
            } else if study.word != nil {
                Text("This entry doesn’t have a grade in Sluka.")
                    .cardFont(TextSize.callout).foregroundStyle(.secondary)
            }
            if !reader.isPointerLookup && !reader.isPassage && !allowsTranslation && sections.isEmpty &&
                reader.preview.word != String(reader.passage) {
                capturedPassage
            }
        }
        .onChange(of: study.pendingGrade) { previous, grade in
            if let previous, grade == nil, study.status == previous.rawValue {
                announceCardText("Sluka grade: \(previous.statusName)")
            }
            if grade == nil, reader.word != study.selected { study.choose(reader.word) }
        }
        .onChange(of: study.lookup, initial: true) { _, lookup in
            guard reader.boundaryMatches.count > 1, let lookup,
                  lookup.surface == reader.word,
                  let gloss = lookup.definition.split(whereSeparator: \.isNewline).first else { return }
            matchGlosses[lookup.surface] = String(gloss.prefix(120))
        }
        .onChange(of: spokenDefinition, initial: true) { _, description in
            if let description { announceCardText(description) }
        }
    }

    private var spokenDefinition: String? {
        guard announcesLookup, let lookup = study.lookup, study.selected == reader.word, !lookup.definition.isEmpty else {
            return nil
        }
        return [lookup.surface, lookup.reading, String(lookup.definition.prefix(220))]
            .filter { !$0.isEmpty }.joined(separator: ", ")
    }

    private var wordDetails: some View {
        let headword = Text(study.lookup?.surface ?? reader.word)
            .cardFont(TextSize.headword, .medium)
            .accessibilityAddTraits(.isHeader)
        let reading = Text(study.lookup?.reading ?? "")
            .cardFont(TextSize.title3).foregroundStyle(.secondary)
        return VStack(alignment: .leading, spacing: Space.xs) {
            if let lookup = study.lookup, !lookup.reading.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                        headword
                        reading
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        headword
                        reading
                    }
                }
            } else {
                headword
            }
            if let definition = study.lookup?.definition, !definition.isEmpty {
                Text(definition).cardFont(TextSize.body).textSelection(.enabled)
            }
        }
    }

    private func lookupStatus(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text(text).cardFont(TextSize.callout).foregroundStyle(.secondary)
            if !study.connected && !study.opening {
                Button("Connect Sluka…", action: study.connect).buttonStyle(.bordered)
            } else if study.connected && study.words.isEmpty && !study.waitingForWords && !study.selectionIsAmbiguous {
                openSlukaReaderButton
            } else if study.word != nil && study.lookup == nil && !study.busy && !study.noDefinition {
                ViewThatFits(in: .horizontal) {
                    HStack { lookupRecoveryButtons }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: Space.xs) { lookupRecoveryButtons }
                }
            }
        }
    }

    @ViewBuilder private var lookupRecoveryButtons: some View {
        Button("Retry Lookup", action: study.retryLookup).buttonStyle(.bordered)
        if study.expectsFullDictionaryCard { openSlukaReaderButton }
    }

    private var boundaryPicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Button {
                showsBoundaryMatches.toggle()
            } label: {
                HStack(spacing: Space.s) {
                    Text("Other matches").cardFont(TextSize.body, .semibold)
                    Spacer(minLength: Space.s)
                    Image(systemName: showsBoundaryMatches ? "chevron.up" : "chevron.down")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.bordered)
            .accessibilityValue(showsBoundaryMatches ? "Expanded" : "Collapsed")
            if showsBoundaryMatches {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Choose a match to see its definition in Sluka.")
                        .cardFont(TextSize.callout)
                        .foregroundStyle(.secondary)
                    ForEach(reader.boundaryMatches) { match in
                        let selected = reader.isSelected(match)
                        Button {
                            guard study.pendingGrade == nil else { return }
                            reader.choose(match)
                            study.choose(match.surface)
                        } label: {
                            VStack(alignment: .leading, spacing: Space.xxs) {
                                Label {
                                    Text(match.surface).cardFont(TextSize.body, .semibold)
                                } icon: {
                                    if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                                }
                                if let gloss = matchGlosses[match.surface] {
                                    Text(gloss).cardFont(TextSize.callout)
                                        .foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .padding(.horizontal, Space.s)
                            .padding(.vertical, Space.xs)
                            .frame(maxWidth: .infinity, minHeight: CompanionStyle.controlSize, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StudyChoiceStyle(selected: selected))
                        .disabled(study.pendingGrade != nil)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
            }
        }
    }

    private var capturedPassage: some View {
        let preview = reader.preview
        let before = reader.isPointerLookup && preview.before.count > 36 ? "…" + preview.before.suffix(36) : preview.before
        let after = reader.isPointerLookup && preview.after.count > 36 ? preview.after.prefix(36) + "…" : preview.after
        let passage = Text(before) + Text(preview.word).bold().foregroundColor(.accentColor) + Text(after)
        let content = passage.cardFont(TextSize.callout).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        return Group {
            if reader.isPointerLookup {
                content.fixedSize(horizontal: false, vertical: true)
            } else {
                ViewThatFits(in: .vertical) {
                    content.fixedSize(horizontal: false, vertical: true)
                    ScrollView { content }
                }
                .frame(maxHeight: 122)
            }
        }
        .padding(Space.s)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: CompanionStyle.insetRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Captured text")
    }

    private var explanation: String? {
        if study.opening { return "Connecting to Sluka…" }
        if !study.connected { return study.message.isEmpty ? "Connect Sluka to see definitions and grades." : study.message }
        if study.selectionIsAmbiguous { return "Several entries match. Select a shorter passage." }
        if study.waitingForWords { return "Finding words with Sluka…" }
        if study.words.isEmpty {
            return study.isIsolatedLookup && reader.boundaryMatches.count > 1
                ? "Sluka didn’t recognize this match."
                : "Activate Sluka in the reader and check the study language."
        }
        if reader.word.isEmpty { return "Choose a word to see its definition and grade." }
        if study.word == nil {
            if study.hasUnresolvedBoundary { return "Looking up this match in Sluka…" }
            if reader.boundaryMatches.count > 1 { return "Sluka didn’t recognize this match. Try another match below." }
            return "Sluka split this text differently. Choose a word above."
        }
        if !study.message.isEmpty { return study.message }
        if study.pendingGrade != nil { return nil }
        if study.busy && study.lookup == nil { return "Looking up the definition…" }
        if study.noDefinition { return "Sluka has no definition for this entry." }
        if study.lookup == nil { return "Sluka’s definition didn’t load." }
        return nil
    }

    private var showSlukaAlternatives: Bool {
        study.word == nil && !study.words.isEmpty
    }

    @ViewBuilder private var passageTranslation: some View {
        switch study.passageTranslation {
        case .idle:
            translateButton("Translate selection")
        case .queued:
            translateButton("Waiting for word lookup…")
        case .waiting:
            translateButton("Translating…")
        case .translated(let translation):
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Translation via Sluka").cardFont(TextSize.callout).foregroundStyle(.secondary)
                Text(translation).cardFont(TextSize.body).textSelection(.enabled)
            }
            .accessibilityElement(children: .contain)
        case .unavailable:
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Sluka couldn’t translate this passage.")
                    .cardFont(TextSize.callout).foregroundStyle(.secondary)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Space.s) {
                        translateButton("Retry translation")
                        openSlukaReaderButton
                    }.fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        translateButton("Retry translation")
                        openSlukaReaderButton
                    }
                }
            }
        }
    }

    private func translateButton(_ title: String) -> some View {
        Button(action: study.translateSelection) {
            Label(title, systemImage: "character.bubble")
                .fontWeight(.semibold)
                .frame(minHeight: CompanionStyle.controlSize)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!study.canRequestTranslation)
        .help("Uses Sluka’s translation settings. Sluka may send the selected text to Google Translate.")
    }

    private var openSlukaReaderButton: some View {
        Button("Open Sluka Reader", action: study.connect)
            .buttonStyle(.link)
    }

    private var wordPicker: some View {
        let words = study.choices(fallingBackTo: reader.choices)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: Space.xs) {
                    ForEach(words, id: \.self) { word in
                        let selected = reader.word == word
                        Button {
                            reader.choose(word)
                            study.choose(reader.word)
                        } label: {
                            Text(word)
                                .cardFont(TextSize.body, selected ? .semibold : .regular)
                                .padding(.horizontal, Space.s)
                                .frame(minWidth: CompanionStyle.controlSize, minHeight: CompanionStyle.controlSize)
                        }
                        .buttonStyle(StudyChoiceStyle(selected: selected))
                        .disabled(study.pendingGrade != nil)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                        .id(word)
                    }
                }
            }
            .scrollIndicators(.visible)
            .accessibilityLabel("Words in the captured passage")
            .onChange(of: reader.word, initial: true) { _, word in
                if !word.isEmpty { proxy.scrollTo(word, anchor: .center) }
            }
            .onChange(of: words) { _, updated in
                if updated.contains(reader.word) { proxy.scrollTo(reader.word, anchor: .center) }
            }
        }
    }
}

@MainActor
final class StudySelection: ObservableObject {
    struct Content {
        let context: WordInContext
        let range: Range<Int>
        let choices: [String]
        var pointerIndex: Int? = nil
    }

    struct BoundaryMatch: Identifiable {
        let surface: String
        let range: Range<Int>
        var id: Range<Int> { range }
    }

    private var pointerIndex: Int?
    private(set) var boundaryMatches: [BoundaryMatch] = []
    var isPointerLookup: Bool { pointerIndex != nil }
    private(set) var passage: [Character] = []
    private(set) var choices: [String] = []
    var isPassage: Bool { choices.count > 1 }
    private var wordRange = 0..<0
    @Published private(set) var word = ""

    init(content: Content, chooseWord: Bool) {
        display(content, chooseWord: chooseWord)
    }

    func display(_ content: Content, chooseWord: Bool) {
        let context = content.context
        let start = content.range.lowerBound
        passage = Array(context.passage[content.range])
        var seen: Set<String> = []
        choices = content.choices.filter { seen.insert($0).inserted }
        wordRange = (context.wordRange.lowerBound - start)..<(context.wordRange.upperBound - start)
        pointerIndex = content.pointerIndex.map { $0 - start }
        boundaryMatches = plausibleMatches(in: context)
        word = chooseWord && isPassage ? "" : context.word
    }

    func choose(_ boundary: SlukaObservation.PointerWord) {
        let text = String(passage)
        guard let range = Range(boundary.range, in: text), text[range] == boundary.surface else { return }
        let start = text.distance(from: text.startIndex, to: range.lowerBound)
        let match = BoundaryMatch(surface: boundary.surface, range: start..<(start + boundary.surface.count))
        if isPointerLookup {
            boundaryMatches.removeAll { $0.surface == match.surface }
            boundaryMatches.insert(match, at: 0)
        }
        choose(match)
    }

    func isSelected(_ match: BoundaryMatch) -> Bool {
        match.range == wordRange && match.surface == word
    }

    func choose(_ match: BoundaryMatch) {
        wordRange = match.range
        word = match.surface
    }

    private func plausibleMatches(in context: WordInContext) -> [BoundaryMatch] {
        guard let pointerIndex, passage.indices.contains(pointerIndex) else { return [] }
        var matches = [BoundaryMatch(surface: context.word, range: wordRange)]
        for surface in context.alternatives {
            let characters = Array(surface)
            let first = max(0, pointerIndex - characters.count + 1)
            let last = min(pointerIndex, passage.count - characters.count)
            guard first <= last else { continue }
            let starts = (first...last).filter { passage[$0..<($0 + characters.count)].elementsEqual(characters) }
            if let start = starts.min(by: { abs($0 - wordRange.lowerBound) < abs($1 - wordRange.lowerBound) }) {
                matches.append(.init(surface: surface, range: start..<(start + characters.count)))
            }
        }
        return matches
    }

    func choose(_ word: String) {
        if let match = boundaryMatches.first(where: { $0.surface == word }) {
            choose(match)
            return
        }
        guard let start = SelectionReader.nearest(word, in: passage, to: wordRange.lowerBound) else { return }
        wordRange = start..<(start + word.count)
        self.word = word
    }

    func stepWord(_ direction: Int, choices: [String]) {
        guard !choices.isEmpty else { return }
        let current = choices.firstIndex(of: word) ?? (direction > 0 ? -1 : 0)
        choose(choices[(current + direction + choices.count) % choices.count])
    }

    var preview: (before: String, word: String, after: String) {
        guard !word.isEmpty else { return (String(passage), "", "") }
        return (String(passage[..<wordRange.lowerBound]), word, String(passage[wordRange.upperBound...]))
    }
}
