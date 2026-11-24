import AppKit
import ApplicationServices

@MainActor final class SlukaBrowser {
    private let suffix = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    private let bundleID = "com.google.Chrome"
    private var lastLaunch: Date?

    private var readerTitle: String { "OCR Companion • Sluka " + suffix }

    @discardableResult
    func show(from url: URL, hasRecentView: Bool, activates: Bool, onError: @escaping (String) -> Void) -> Bool {
        guard let chromeURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            onError("Google Chrome is required to use this Sluka reader.")
            return false
        }
        let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let isLaunching = lastLaunch.map { Date().timeIntervalSince($0) < 4 } ?? false
        if let chrome, hasRecentView || isLaunching {
            guard activates else { return hasRecentView }
            if activateReader(in: chrome) { return true }
            chrome.activate(options: [])
            if hasRecentView {
                onError("Select the OCR Companion • Sluka tab in Chrome.")
            }
            return hasRecentView
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment else {
            onError("The local Sluka reader URL is unavailable.")
            return false
        }
        components.fragment = fragment + "&mode=compact&title=" + suffix
        guard let launchURL = components.url else {
            onError("Could not open the local Sluka reader URL.")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        lastLaunch = Date()
        NSWorkspace.shared.open([launchURL], withApplicationAt: chromeURL, configuration: configuration) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                self.lastLaunch = nil
                onError("Could not open the Sluka reader in Chrome. " + error.localizedDescription)
            }
        }
        return false
    }

    private func activateReader(in chrome: NSRunningApplication) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = AXUIElementCreateApplication(chrome.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.15)
        guard let windows: [AXUIElement] = attribute(app, kAXWindowsAttribute) else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.35
        for window in windows.prefix(40) where ProcessInfo.processInfo.systemUptime < deadline {
            if let title: String = attribute(window, kAXTitleAttribute), matches(title) {
                return raise(window, in: chrome)
            }
        }
        for window in windows.prefix(40) where ProcessInfo.processInfo.systemUptime < deadline {
            guard let tab = readerTab(in: window, before: deadline),
                  AXUIElementPerformAction(tab, kAXPressAction as CFString) == .success else { continue }
            return raise(window, in: chrome)
        }
        return false
    }

    private func readerTab(in window: AXUIElement, before deadline: TimeInterval) -> AXUIElement? {
        // Chrome exposes tab strips as AXTabGroup and native tabs as AXRadioButton on macOS.
        // Stay inside the browser chrome so a control in a web page cannot match the reader.
        let tabGroupRole = kAXTabGroupRole as String
        let containerRoles = [kAXWindowRole as String, kAXGroupRole as String, kAXSplitGroupRole as String, tabGroupRole]
        var pending = [(window, false)]
        while ProcessInfo.processInfo.systemUptime < deadline, let (element, insideTabs) = pending.popLast() {
            guard let role: String = attribute(element, kAXRoleAttribute) else { continue }
            if insideTabs && role == kAXRadioButtonRole as String {
                let title: String? = attribute(element, kAXTitleAttribute)
                let label: String? = attribute(element, kAXDescriptionAttribute)
                if title == readerTitle || label == readerTitle { return element }
            } else if containerRoles.contains(role),
                      let children: [AXUIElement] = attribute(element, kAXChildrenAttribute) {
                let inTabGroup = insideTabs || role == tabGroupRole
                pending.append(contentsOf: children.reversed().map { ($0, inTabGroup) })
            }
        }
        return nil
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private func matches(_ title: String) -> Bool {
        title == readerTitle || title == readerTitle + " - Google Chrome" || title.hasPrefix(readerTitle + " – ")
    }

    private func raise(_ window: AXUIElement, in chrome: NSRunningApplication) -> Bool {
        if AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success {
            chrome.activate(options: [])
            return true
        }
        return false
    }
}
