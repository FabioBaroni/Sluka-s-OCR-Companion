import AppKit
import ApplicationServices
import OSLog
import ScreenCaptureKit
import SwiftUI

@main
enum Main {
    @MainActor static func main() {
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--compile-segmentation-dictionary" {
            do {
                let dictionary = try CEDict(contentsOf: URL(fileURLWithPath: args[2]))
                let count = try dictionary.compile(to: URL(fileURLWithPath: args[3]))
                print("Verified \(count) compiled dictionary headwords")
                return
            } catch {
                FileHandle.standardError.write(Data("Dictionary compilation failed: \(error)\n".utf8))
                exit(EXIT_FAILURE)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        ?? "Sluka's OCR Companion"
    static let maxSelection = 400
    private let lookupTiming = OSSignposter(subsystem: "local.ocrcompanion.reader", category: "Lookup")
    private let popup = PopupController()
    private let chip = SelectionChip()
    private let study = SlukaStudy()
    private lazy var chineseDictionary = try? CEDict.load()
    private var statusItem: NSStatusItem!
    private var hotKeys: [CompanionShortcut: HotKey] = [:]
    private var cardAllowsTranslation = false
    private weak var cardSelection: StudySelection?
    private var hoverTimer: Timer?
    private var hoverPoint: CGPoint?
    private var hoverStarted: TimeInterval = 0
    private var hovered = false
    private var pointerTask: Task<Void, Never>?
    private var hoverGeneration = 0
    private var lastHoverWord: String?
    private var hoverSource: CGPoint?
    private var transitExpiry: TimeInterval = 0
    private var lastPointer: CGPoint?
    private var activationObserver: NSObjectProtocol?
    private var areaWindows: [NSWindow] = []
    private var capturing = false
    private var lastCaptureStatus: String?
    private var permissionWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private static let permissionSetupComplete = "permissionSetupComplete"
    private var language = ReadingLanguage(code: UserDefaults.standard.string(forKey: "readingLanguage") ?? "zh-Hans")
    private lazy var languages: [ReadingLanguage] = {
        let extra = (ScreenRecognition.visionLanguages + ScreenRecognition.liveTextLanguages)
            .map { ReadingLanguage(code: $0) }.filter { !$0.isChinese }.map(\.base)
        return Set(ReadingLanguage.studyCodes + extra).map(ReadingLanguage.init(code:))
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = statusIcon()
        statusItem.button?.toolTip = appName
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: appName)
        let aboutItem = applicationMenu.addItem(withTitle: "About \(appName)", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        applicationMenu.addItem(makeSettingsItem())
        let quitItem = applicationMenu.addItem(withTitle: "Quit \(appName)", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        study.start()
        for shortcut in CompanionShortcut.allCases {
            hotKeys[shortcut] = HotKey(shortcut) { [weak self] in
                Task { @MainActor in self?.performShortcut(shortcut) }
            }
        }
        chip.onClick = { [weak self] selection, anchor in
            Task { @MainActor in
                guard let self else { return }
                self.cancelPointerLookup()
                if let selection { self.showSelection(selection, near: anchor) }
                else if let copied = await SelectionReader.readByCopying() { self.showSelection(copied, near: anchor) }
            }
        }
        chip.start()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { event in
            guard let app = event.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            SelectionReader.prepare(app)
        }
        if let front = NSWorkspace.shared.frontmostApplication { SelectionReader.prepare(front) }
        if UserDefaults.standard.bool(forKey: "hoverEnabled"), hoverHasAccess { startHover() }
        if !UserDefaults.standard.bool(forKey: Self.permissionSetupComplete),
           !AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess() {
            showPermissions()
        }
    }

    private func statusIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
              let icon = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "eye", accessibilityDescription: appName)
        }
        icon.size = NSSize(width: 20, height: 20)
        icon.isTemplate = false
        icon.accessibilityDescription = appName
        return icon
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        let canRead = hoverHasAccess
        if !canRead {
            _ = add("Set Up Reading Permissions…", #selector(showPermissions))
            menu.addItem(.separator())
        }
        let lookup = addShortcut(.lookup, title: "Look Up Selection or Pointer", to: menu)
        if lookup.toolTip == nil {
            lookup.toolTip = "Select text and choose this command, or point at a word and press Control–Option–L."
        }
        addShortcut(.hover, title: "Automatic Hover", to: menu).state = hoverTimer == nil ? .off : .on
        addShortcut(.captureArea, title: "Capture Screen Area…", to: menu)
        addShortcut(.captureWindow, title: "Capture Window…", to: menu)
        if let lastCaptureStatus {
            let status = menu.addItem(withTitle: lastCaptureStatus, action: nil, keyEquivalent: "")
            status.isEnabled = false
        }
        menu.addItem(.separator())
        let languageMenu = NSMenu()
        for option in languages {
            let suffix = ScreenRecognition.supportsPointer(option.code) ? ""
                : ScreenRecognition.supports(option.code) ? " · Image word picker" : " · Selectable text only"
            let item = languageMenu.addItem(withTitle: option.name + suffix, action: #selector(setLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.code
            item.state = option == language ? .on : .off
        }
        let languageItem = NSMenuItem(title: "Study Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        menu.addItem(languageItem)
        addShortcut(.sluka, title: study.connected ? "Show Sluka Reader" : "Connect Sluka…", to: menu)
        let cardItem = menu.addItem(withTitle: "Card Actions", action: nil, keyEquivalent: "")
        cardItem.submenu = makeCardMenu()
        menu.addItem(.separator())
        if canRead && (!AXIsProcessTrusted() || !CGPreflightScreenCaptureAccess()) {
            _ = add("Review Reading Permissions…", #selector(showPermissions))
        }
        menu.addItem(makeSettingsItem())
        _ = add("About & Credits…", #selector(showAbout))
        _ = add("Quit \(appName)", #selector(quit))
    }

    private var hasStudyCard: Bool { popup.kind != .hint && popup.currentLayout?.appeared == true }

    private func makeCardMenu() -> NSMenu {
        let menu = NSMenu(title: "Card Actions")
        menu.autoenablesItems = false
        addShortcut(.translate, title: "Translate Selection", to: menu)
        addShortcut(.previousWord, title: "Previous Word", to: menu)
        addShortcut(.nextWord, title: "Next Word", to: menu)
        addShortcut(.copy, title: "Copy Captured Text", to: menu)
        addShortcut(.pin, title: CardPin.shared.isOn ? "Unpin Card" : "Pin Card", to: menu)
        addShortcut(.close, title: "Close Card", to: menu)
        menu.addItem(.separator())
        let gradeMenu = NSMenu(title: "Sluka Grade")
        gradeMenu.autoenablesItems = false
        gradeMenu.addItem(withTitle: "Click the card to use single-key grades", action: nil, keyEquivalent: "").isEnabled = false
        gradeMenu.addItem(.separator())
        for shortcut in CompanionShortcut.allCases {
            guard let grade = shortcut.grade else { continue }
            let title = grade == .new ? "Reset to Unknown" : grade == .ignored ? "Ignore Word" : grade.statusName
            let item = addShortcut(shortcut, title: title, to: gradeMenu)
            item.state = hasStudyCard && study.status == grade.rawValue ? .on : .off
        }
        menu.addItem(withTitle: "Sluka Grade", action: nil, keyEquivalent: "").submenu = gradeMenu
        return menu
    }

    @discardableResult
    private func addShortcut(_ shortcut: CompanionShortcut, title: String, to menu: NSMenu) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: #selector(performMenuShortcut(_:)), keyEquivalent: "")
        item.target = self
        item.tag = Int(shortcut.rawValue)
        item.isEnabled = canPerform(shortcut)
        if let grade = shortcut.grade {
            item.keyEquivalent = grade.cardKey
            item.keyEquivalentModifierMask = []
        } else if hotKeys[shortcut] != nil {
            item.keyEquivalent = shortcut.key.equivalent
            item.keyEquivalentModifierMask = shortcut.menuModifiers
        } else {
            item.toolTip = "This keyboard shortcut is unavailable."
        }
        return item
    }

    @objc private func performMenuShortcut(_ item: NSMenuItem) {
        guard let id = UInt32(exactly: item.tag), let shortcut = CompanionShortcut(rawValue: id) else { return }
        performShortcut(shortcut)
    }

    private func canPerform(_ shortcut: CompanionShortcut) -> Bool {
        guard permissionWindow == nil, areaWindows.isEmpty, NSApp.modalWindow == nil else { return false }
        if let grade = shortcut.grade { return hasStudyCard && study.canSetGrade(grade) }
        switch shortcut {
        case .translate: return hasStudyCard && cardAllowsTranslation && study.canRequestTranslation
        case .previousWord, .nextWord:
            guard hasStudyCard, let cardSelection, study.pendingGrade == nil else { return false }
            return study.choices(fallingBackTo: cardSelection.choices).count > 1
        case .copy: return hasStudyCard && popup.currentLayout?.copyText != nil
        case .pin, .close: return hasStudyCard
        case .captureArea, .captureWindow: return !capturing && study.pendingGrade == nil
        default: return true
        }
    }

    private func performShortcut(_ shortcut: CompanionShortcut) {
        guard canPerform(shortcut) else { return }
        if let grade = shortcut.grade {
            study.grade(grade)
            return
        }
        switch shortcut {
        case .lookup: lookupSelectionOrPointer()
        case .hover: toggleHover()
        case .captureArea: selectArea()
        case .captureWindow: chooseWindow()
        case .sluka: study.connect()
        case .translate: study.translateSelection()
        case .previousWord, .nextWord:
            if let cardSelection {
                cardSelection.stepWord(shortcut == .nextWord ? 1 : -1, choices: study.choices(fallingBackTo: cardSelection.choices))
                study.choose(cardSelection.word)
            }
        case .pin: popup.togglePin()
        case .copy: popup.currentLayout?.copyToPasteboard()
        case .close: popup.close()
        default: break
        }
    }

    @objc private func showAbout() {
        let credits = NSAttributedString(string: """
        Multilingual lookup and screen OCR with Sluka. Choose your language in the Study Language menu. Screen OCR availability varies by language and Mac.

        Created by Fabio Baroni (pentestguru)

        An independent community project. Not affiliated with or endorsed by Sluka.

        Based on LongYan Reader by mapuchuu. Chinese word segmentation uses CC-CEDICT data.
        """)
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: appName,
            .credits: credits,
        ])
    }

    private func makeSettingsItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        item.target = self
        return item
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let content = CompanionSettings(openPermissions: { [weak self] in self?.showPermissions() },
                                            updateTextSize: { [weak self] in self?.updateTextSize($0) })
            let window = NSWindow(contentViewController: NSHostingController(rootView: content))
            window.styleMask = [.titled, .closable]
            window.title = "\(appName) Settings"
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func updateTextSize(_ size: Double) {
        let activeCard = popup.kind != .hint ? popup.currentLayout : nil
        let layout = activeCard ?? CardLayout(kind: .word)
        layout.setTextSize(size)
    }

    @objc private func showPermissions() {
        if let permissionWindow {
            NSApp.activate(ignoringOtherApps: true)
            permissionWindow.makeKeyAndOrderFront(nil)
            return
        }
        let content = PermissionSetup(
            requestAccessibility: { [weak self] in self?.requestAccessibilityPermission() },
            requestScreenRecording: { [weak self] in _ = self?.requestScreenRecording(fromSetup: true) },
            finish: { [weak self] in self?.finishPermissionSetup() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.styleMask = [.titled]
        window.title = appName
        window.isReleasedWhenClosed = false
        window.center()
        permissionWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func finishPermissionSetup() {
        UserDefaults.standard.set(true, forKey: Self.permissionSetupComplete)
        permissionWindow?.close()
        permissionWindow = nil
        if hoverTimer == nil, UserDefaults.standard.bool(forKey: "hoverEnabled"), hoverHasAccess {
            startHover()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func setLanguage(_ item: NSMenuItem) {
        guard let code = item.representedObject as? String else { return }
        language = ReadingLanguage(code: code)
        UserDefaults.standard.set(code, forKey: "readingLanguage")
        popup.close()
        cancelPointerLookup()
        lastHoverWord = nil
        hoverPoint = nil
    }

    static func appKitRect(_ rect: CGRect) -> NSRect {
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: rect.minX, y: top - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func quartzPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.maxY ?? 0) - point.y)
    }

    private func anchor(at point: CGPoint) -> CGRect {
        CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20)
    }

    private func requestAccessibilityPermission() {
        guard !AXIsProcessTrusted() else { return }
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "askedForAccessibility") {
            openPrivacySettings("Privacy_Accessibility")
        } else {
            defaults.set(true, forKey: "askedForAccessibility")
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
    }

    private func openPrivacySettings(_ section: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(section)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func lookupSelectionOrPointer() {
        chip.hide()
        guard hoverHasAccess else { showPermissions(); return }
        cancelPointerLookup()
        let point = NSEvent.mouseLocation
        let anchor = anchor(at: point)
        if case .selection(let selection) = SelectionReader.readAccessibility(), selection.hasWords {
            showSelection(selection, near: anchor)
        } else if !NSScreen.screens.contains(where: { $0.visibleFrame.contains(point) }) {
            hint("Point at a word and press Control–Option–L.", near: anchor)
        } else {
            lookupPointer(point, automatic: false)
        }
    }

    @objc private func toggleHover() {
        if let hoverTimer {
            cancelPointerLookup()
            hoverTimer.invalidate()
            self.hoverTimer = nil
            UserDefaults.standard.set(false, forKey: "hoverEnabled")
        } else {
            guard hoverHasAccess else { showPermissions(); return }
            UserDefaults.standard.set(true, forKey: "hoverEnabled")
            startHover()
        }
    }

    private var hoverHasAccess: Bool { AXIsProcessTrusted() || CGPreflightScreenCaptureAccess() }

    private func startHover() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleHover() }
        }
    }

    private func sampleHover() {
        let point = NSEvent.mouseLocation
        let now = ProcessInfo.processInfo.systemUptime
        let previousPointer = lastPointer
        lastPointer = point
        if now < transitExpiry, let hoverSource, let previousPointer,
           popup.isMovingTowardCard(point, from: previousPointer, source: hoverSource) {
            hoverPoint = nil
            return
        }
        guard permissionWindow == nil, !popup.hasKeyboardFocus, hoverHasAccess, !capturing, areaWindows.isEmpty, study.pendingGrade == nil,
              NSEvent.pressedMouseButtons == 0,
              CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel) > 0.45,
              NSScreen.screens.contains(where: { $0.visibleFrame.contains(point) }),
              !NSApp.windows.contains(where: { $0.isVisible && $0.frame.contains(point) }) else {
            hoverPoint = nil
            return
        }
        guard let previous = hoverPoint, hypot(point.x - previous.x, point.y - previous.y) <= 4 else {
            hoverGeneration &+= 1
            hoverPoint = point
            hoverStarted = now
            hovered = false
            return
        }
        guard !hovered, pointerTask == nil, now - hoverStarted >= 0.45 else { return }
        hovered = true
        lookupPointer(point, automatic: true)
    }

    private func cancelPointerLookup() {
        pointerTask?.cancel()
        pointerTask = nil
        hoverGeneration &+= 1
    }

    private func lookupPointer(_ point: CGPoint, automatic: Bool) {
        guard pointerTask == nil else { return }
        let generation = hoverGeneration
        let captureLanguage = language
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let quartz = Self.quartzPoint(point)
        pointerTask = Task {
            defer { if !Task.isCancelled { pointerTask = nil } }
            let interval = lookupTiming.beginInterval("Accessibility pointer")
            let capture = await TextCapture.probe(at: quartz)
            lookupTiming.endInterval("Accessibility pointer", interval)
            guard pointerIsCurrent(point, generation: generation, language: captureLanguage, front: front) else { return }
            if let capture, let context = word(at: capture.index, in: capture.passage) {
                showPointerWord(context, index: capture.index, range: context.sentenceBounds, point: point, automatic: automatic)
                return
            }
            let hasWordPosition = ScreenRecognition.supportsPointer(language.code)
            if !hasWordPosition && !ScreenRecognition.supports(language.code) {
                if !automatic {
                    hint("Screen OCR is unavailable for \(language.name) on this Mac.", near: anchor(at: point))
                }
            } else if !CGPreflightScreenCaptureAccess() {
                if !automatic { hint("Use Capture Screen Area to enable reading text in images.", near: anchor(at: point)) }
            } else {
                await lookupPixels(at: point, generation: generation, language: captureLanguage, front: front,
                                   automatic: automatic, hasWordPosition: hasWordPosition)
            }
        }
    }

    private func pointerIsCurrent(_ point: CGPoint, generation: Int, language: ReadingLanguage, front: pid_t?) -> Bool {
        let cursor = NSEvent.mouseLocation
        return !Task.isCancelled && self.language == language && generation == hoverGeneration && !capturing &&
            areaWindows.isEmpty && study.pendingGrade == nil && NSEvent.pressedMouseButtons == 0 &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == front &&
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .scrollWheel) > 0.45 &&
            hypot(cursor.x - point.x, cursor.y - point.y) <= 4
    }

    private func showPointerWord(_ context: WordInContext, index: Int, range: Range<Int>, point: CGPoint, automatic: Bool) {
        let identity = "\(context.markedPassage)@\(index - range.lowerBound)"
        if automatic && lastHoverWord == identity && popup.isShowing { return }
        lastHoverWord = identity
        hoverSource = point
        transitExpiry = ProcessInfo.processInfo.systemUptime + 0.85
        let content = StudySelection.Content(context: context, range: range, choices: [context.word], pointerIndex: index)
        let pointerOffset = String(context.passage[range.lowerBound..<index]).utf16.count
        presentStudy(content, near: anchor(at: point), chooseWord: false,
                     announcesLookup: !automatic, pointerOffset: pointerOffset)
    }

    private func word(at index: Int, in passage: [Character]) -> WordInContext? {
        if language.isChinese, let dictionary = chineseDictionary {
            return Segmenter.word(at: index, in: passage, dict: dictionary)
        } else {
            return language.wordRanges(in: passage)
                .first { $0.contains(index) }
                .map { Segmenter.context(for: $0, in: passage) }
        }
    }

    private func lookupPixels(at point: CGPoint, generation: Int, language: ReadingLanguage,
                              front: pid_t?, automatic: Bool, hasWordPosition: Bool) async {
        guard let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(point) }) else { return }
        let bounds = ScreenGeometry.cursorRegion(at: point, within: screen.frame, compact: !hasWordPosition)
        let local = bounds.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        do {
            let image: CGImage
            do {
                let interval = lookupTiming.beginInterval("Pointer screen capture")
                defer { lookupTiming.endInterval("Pointer screen capture", interval) }
                image = try await screenPixels(in: local, screen: screen)
            }
            guard pointerIsCurrent(point, generation: generation, language: language, front: front) else { return }
            let result: ScreenRecognition.Output
            do {
                let interval = lookupTiming.beginInterval("Pointer OCR")
                defer { lookupTiming.endInterval("Pointer OCR", interval) }
                result = try await ScreenRecognition.recognize(image, language: language.code, bounds: bounds,
                                                               point: hasWordPosition ? point : nil)
            }
            guard pointerIsCurrent(point, generation: generation, language: language, front: front) else { return }
            if !hasWordPosition, !result.lines.isEmpty {
                if showCapturedSections(result.lines, near: anchor(at: point), allowsTranslation: false) {
                    hoverSource = point
                    transitExpiry = ProcessInfo.processInfo.systemUptime + 0.85
                    return
                }
            }
            guard let hit = result.pointerHit else {
                if !automatic { hint("No text under the pointer. Try Capture Screen Area.", near: anchor(at: point)) }
                return
            }
            let passage = Array(result.lines[hit.line].text)
            if let index = hit.character, let context = word(at: index, in: passage) {
                showPointerWord(context, index: index, range: passage.indices, point: point, automatic: automatic)
            } else {
                let selection = Selection(passage: passage, range: passage.indices, bounds: nil,
                                          source: .accessibility, appName: nil)
                showSelection(selection, near: anchor(at: point), chooseWord: true, preserveLayout: true, allowsTranslation: false)
                hoverSource = point
                transitExpiry = ProcessInfo.processInfo.systemUptime + 0.85
            }
        } catch {
            if !automatic, pointerIsCurrent(point, generation: generation, language: language, front: front) {
                hint("Pointer OCR failed. Try Capture Screen Area.", near: anchor(at: point))
            }
        }
    }

    private func showSelection(_ selection: Selection, near fallback: CGRect, chooseWord: Bool = false,
                               preserveLayout: Bool = false, allowsTranslation: Bool = true,
                               centerOnDisplay: Bool = false) {
        hoverSource = nil
        let selection = preserveLayout ? selection : selection.trimmed()
        let anchor = selection.bounds.map(Self.appKitRect) ?? fallback
        guard selection.hasWords, !selection.range.isEmpty else { return }
        guard selection.range.count <= Self.maxSelection else { hint("Select up to a few sentences.", near: anchor); return }
        presentStudy(selectionDetails(selection), near: anchor, chooseWord: chooseWord,
                     allowsTranslation: allowsTranslation, centerOnDisplay: centerOnDisplay)
    }

    private func selectionDetails(_ selection: Selection) -> StudySelection.Content {
        let dictionary = language.isChinese ? chineseDictionary : nil
        let exact = dictionary.map { selection.wholeWords(dict: $0) } ?? selection
        let ranges: [Range<Int>]
        if let dictionary {
            ranges = Segmenter.phrase(exact.range, in: exact.passage, dict: dictionary).map(\.range)
        } else {
            ranges = language.wordRanges(in: exact.passage).filter { $0.overlaps(exact.range) }
        }
        let range = ranges.first ?? exact.range
        let context = Segmenter.context(for: range, in: exact.passage)
        let choices = ranges.map { String(exact.passage[$0]) }
        // Include the selected punctuation and the complete boundary words for Sluka.
        let bounds = min(range.lowerBound, exact.range.lowerBound)..<max(ranges.last?.upperBound ?? range.upperBound, exact.range.upperBound)
        return StudySelection.Content(context: context, range: bounds, choices: choices)
    }

    private func presentStudy(_ content: StudySelection.Content, near anchor: CGRect, chooseWord: Bool,
                              sections: [String] = [], allowsTranslation: Bool = false, announcesLookup: Bool = true,
                              pointerOffset: Int? = nil, centerOnDisplay: Bool = false) {
        guard study.pendingGrade == nil else { return }
        let reader = StudySelection(content: content, chooseWord: chooseWord)
        cardAllowsTranslation = allowsTranslation
        cardSelection = reader
        study.showCapture(String(reader.passage), selected: reader.word, language: language.code,
                          pointerOffset: pointerOffset) { [weak reader] boundary in
            reader?.choose(boundary)
        }
        let card = StudyCard(study: study, reader: reader, sections: sections, allowsTranslation: allowsTranslation,
                             announcesLookup: announcesLookup) { [weak self] index in
            guard let self else { return }
            reader.display(self.detailsForCapturedSection(sections[index]), chooseWord: true)
            self.study.showCapture(String(reader.passage), selected: reader.word, language: self.language.code)
        }
        popup.show(card, kind: reader.isPassage || !sections.isEmpty ? .phrase : .word, near: anchor,
                   centerOnDisplay: centerOnDisplay,
                   copyText: { String(reader.passage) }, onGradeKey: { [weak self] grade in
                       guard let self, self.hasStudyCard else { return }
                       self.study.grade(grade)
                   })
    }

    private func detailsForCapturedSection(_ text: String) -> StudySelection.Content {
        let passage = Array(text)
        return selectionDetails(Selection(passage: passage, range: passage.indices, bounds: nil,
                                          source: .accessibility, appName: nil))
    }

    @discardableResult
    private func showCapturedSections(_ lines: [ScreenCaptureLine], near anchor: CGRect, allowsTranslation: Bool = true,
                                      centerOnDisplay: Bool = false) -> Bool {
        let sections = CapturedPassages.sections(in: lines, limit: Self.maxSelection)
        guard let first = sections.first else { return false }
        presentStudy(detailsForCapturedSection(first), near: anchor, chooseWord: true, sections: sections,
                     allowsTranslation: allowsTranslation, centerOnDisplay: centerOnDisplay)
        return true
    }

    private func hint(_ text: String, near anchor: CGRect) {
        popup.show(Text(text).cardFont(TextSize.body), kind: .hint, near: anchor)
    }

    private enum CaptureError: LocalizedError {
        case displayUnavailable, invalidArea, empty

        var errorDescription: String? {
            switch self {
            case .displayUnavailable: return "The display is no longer available. Start a new capture."
            case .invalidArea: return "Choose a smaller area entirely within one display."
            case .empty: return "No text was found. Check the OCR language or try a clearer area."
            }
        }
    }

    private func canStartScreenCapture() -> Bool {
        guard !capturing, areaWindows.isEmpty, study.pendingGrade == nil else { return false }
        guard ScreenRecognition.supports(language.code) else {
            presentCaptureFailure("Screen OCR is unavailable for \(language.name) on this Mac.")
            return false
        }
        guard requestScreenRecording() else { return false }
        cancelPointerLookup()
        return true
    }

    private func requestScreenRecording(fromSetup: Bool = false) -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "askedForScreenRecording") {
            defaults.set(true, forKey: "askedForScreenRecording")
            lastCaptureStatus = "Screen Recording permission is required"
            return CGRequestScreenCaptureAccess()
        }
        if fromSetup {
            openPrivacySettings("Privacy_ScreenCapture")
            return false
        }
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording to capture text"
        alert.informativeText = "Turn on \(appName) in Screen & System Audio Recording. Reopen the app if macOS asks."
        alert.addButton(withTitle: "Open Screen Recording Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            openPrivacySettings("Privacy_ScreenCapture")
        }
        return false
    }

    @objc private func selectArea() {
        guard canStartScreenCapture() else { return }
        // Wait for the menu to stop tracking before giving the overlay mouse focus.
        DispatchQueue.main.async { [weak self] in self?.showAreaSelector() }
    }

    private func showAreaSelector() {
        guard !capturing, areaWindows.isEmpty else { return }
        popup.close()
        chip.hide()
        lastCaptureStatus = "Select an area on screen"
        var activeWindow: SelectionWindow?
        for screen in NSScreen.screens {
            let window = SelectionWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = AreaView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self] result in
                guard let self else { return }
                self.areaWindows.forEach { $0.orderOut(nil); $0.close() }
                self.areaWindows.removeAll()
                switch result {
                case .area(let rect):
                    Task { await self.captureArea(rect, screen: screen) }
                case .tooSmall:
                    DispatchQueue.main.async { self.presentCaptureFailure("Drag a larger box around the text, then release.") }
                case .cancelled:
                    self.lastCaptureStatus = "Capture cancelled"
                }
            }
            window.contentView = view
            areaWindows.append(window)
            window.orderFrontRegardless()
            if screen.frame.contains(NSEvent.mouseLocation) { activeWindow = window }
        }
        NSApp.activate(ignoringOtherApps: true)
        let keyWindow = activeWindow ?? areaWindows.first
        keyWindow?.makeKeyAndOrderFront(nil)
        keyWindow?.makeFirstResponder(keyWindow?.contentView)
    }

    private func captureArea(_ rect: CGRect, screen: NSScreen) async {
        let anchor = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        await capture(near: anchor) {
            try await Task.sleep(for: .milliseconds(160))
            return try await screenPixels(in: rect, screen: screen)
        }
    }

    private func screenPixels(in rect: CGRect, screen: NSScreen) async throws -> CGImage {
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw CaptureError.displayUnavailable
        }
        guard let crop = ScreenGeometry.crop(rect, displaySize: screen.frame.size, scale: screen.backingScaleFactor) else {
            throw CaptureError.invalidArea
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else {
            throw CaptureError.displayUnavailable
        }
        let own = content.applications.filter { $0.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.sourceRect = crop.sourceRect
        config.width = crop.pixelWidth
        config.height = crop.pixelHeight
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    @objc private func chooseWindow() {
        guard canStartScreenCapture() else { return }
        let anchor = anchor(at: NSEvent.mouseLocation)
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                let windows = content.windows.filter {
                    $0.isOnScreen && $0.windowLayer == 0 && $0.owningApplication?.processID != getpid() &&
                    $0.frame.width >= 32 && $0.frame.height >= 32 && !($0.title ?? "").isEmpty
                }
                guard !windows.isEmpty else {
                    presentCaptureFailure("No titled windows are available. Open the source window and try again.")
                    return
                }
                let picker = NSPopUpButton(frame: CGRect(x: 0, y: 0, width: 390, height: 28))
                for window in windows {
                    picker.addItem(withTitle: (window.owningApplication?.applicationName ?? "Window") + " — " + (window.title ?? ""))
                    picker.lastItem?.tag = Int(window.windowID)
                }
                let alert = NSAlert()
                alert.messageText = "Capture a window"
                alert.informativeText = "Choose the window that contains the text you want to read."
                alert.accessoryView = picker
                alert.addButton(withTitle: "Capture")
                alert.addButton(withTitle: "Cancel")
                NSApp.activate(ignoringOtherApps: true)
                guard alert.runModal() == .alertFirstButtonReturn,
                      let id = picker.selectedItem?.tag,
                      let window = windows.first(where: { Int($0.windowID) == id }) else { return }
                popup.close()
                chip.hide()
                let windowFrame = Self.appKitRect(window.frame)
                let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(windowFrame) }
                await capture(near: visible ? windowFrame : anchor, wholeWindow: true) {
                    try await WindowCapture.image(of: window)
                }
            } catch {
                presentCaptureFailure(error.localizedDescription)
            }
        }
    }

    private func capture(near anchor: CGRect, wholeWindow: Bool = false, pixels: () async throws -> CGImage) async {
        guard !capturing else { return }
        let captureLanguage = language
        capturing = true
        defer { capturing = false }
        lastCaptureStatus = "Reading captured text…"
        do {
            let image = try await pixels()
            let ocr = try await ScreenRecognition.recognize(image, language: captureLanguage.code, bounds: anchor, point: nil)
            guard language == captureLanguage else {
                lastCaptureStatus = "Language changed. Capture again."
                return
            }
            let lines: [ScreenCaptureLine]
            if wholeWindow {
                let matchesStudyLanguage = captureLanguage.windowLineFilter()
                lines = ocr.lines.filter { matchesStudyLanguage($0.text) }
                guard !lines.isEmpty else {
                    presentCaptureFailure("No text matched \(captureLanguage.name). Check Study Language or use Capture Screen Area.")
                    return
                }
            } else {
                lines = ocr.lines
            }
            let characters = Array(lines.map(\.text).joined(separator: "\n"))
            guard characters.contains(where: \.isLetter) else { throw CaptureError.empty }
            if characters.count > Self.maxSelection {
                guard showCapturedSections(lines, near: anchor, centerOnDisplay: wholeWindow) else { throw CaptureError.empty }
            } else {
                showSelection(Selection(passage: characters, range: characters.indices, bounds: nil,
                                        source: .accessibility, appName: nil), near: anchor,
                              chooseWord: true, preserveLayout: true, centerOnDisplay: wholeWindow)
            }
            lastCaptureStatus = "Last capture: \(lines.count) lines · \(ocr.engine)"
        } catch TesseractOCR.Error.timedOut {
            presentCaptureFailure("OCR took too long. Capture a smaller area to try again.")
        } catch {
            presentCaptureFailure(error.localizedDescription)
        }
    }

    private func presentCaptureFailure(_ detail: String) {
        lastCaptureStatus = "Last capture failed"
        let alert = NSAlert()
        alert.messageText = "\(appName) couldn’t read the capture"
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
