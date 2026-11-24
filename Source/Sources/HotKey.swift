import AppKit
import Carbon.HIToolbox

enum CompanionShortcut: UInt32, CaseIterable {
    case lookup = 1, hover, captureArea, captureWindow, sluka, translate, pin, copy, close
    case gradeUnknown, grade1, grade2, grade3, grade4, gradeKnown, gradeIgnore
    case previousWord, nextWord

    var key: (code: Int, equivalent: String) {
        switch self {
        case .lookup: return (kVK_ANSI_L, "l")
        case .hover: return (kVK_ANSI_H, "h")
        case .captureArea: return (kVK_ANSI_A, "a")
        case .captureWindow: return (kVK_ANSI_W, "w")
        case .sluka: return (kVK_ANSI_S, "s")
        case .translate: return (kVK_ANSI_T, "t")
        case .pin: return (kVK_ANSI_P, "p")
        case .copy: return (kVK_ANSI_C, "c")
        case .close: return (kVK_ANSI_D, "d")
        case .gradeUnknown: return (kVK_ANSI_0, "0")
        case .grade1: return (kVK_ANSI_1, "1")
        case .grade2: return (kVK_ANSI_2, "2")
        case .grade3: return (kVK_ANSI_3, "3")
        case .grade4: return (kVK_ANSI_4, "4")
        case .gradeKnown: return (kVK_ANSI_K, "k")
        case .gradeIgnore: return (kVK_ANSI_X, "x")
        case .previousWord: return (kVK_ANSI_B, "b")
        case .nextWord: return (kVK_ANSI_N, "n")
        }
    }

    var menuModifiers: NSEvent.ModifierFlags { self == .lookup ? [.control, .option] : [.control, .shift] }
    var globalModifiers: Int { self == .lookup ? controlKey | optionKey : controlKey | shiftKey }
}

/// A system-wide hotkey through Carbon. Needs no Accessibility permission itself.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var held: Set<UInt32> = []
    private static var eventHandler: EventHandlerRef?
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(_ shortcut: CompanionShortcut, handler: @escaping () -> Void) {
        id = shortcut.rawValue
        guard Self.handlers[id] == nil, Self.installHandlerOnce() else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x4C4E_5952), id: id)  // 'LNYR'
        let status = RegisterEventHotKey(UInt32(shortcut.key.code), UInt32(shortcut.globalModifiers),
                                         hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, ref != nil else { return nil }
        Self.handlers[id] = handler
    }

    deinit {
        guard let ref else { return }
        UnregisterEventHotKey(ref)
        Self.handlers.removeValue(forKey: id)
        Self.held.remove(id)
    }

    private static func installHandlerOnce() -> Bool {
        if eventHandler != nil { return true }
        let events = [kEventHotKeyPressed, kEventHotKeyReleased].map {
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32($0))
        }
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == OSType(0x4C4E_5952), let handler = HotKey.handlers[id.id] else {
                return OSStatus(eventNotHandledErr)
            }
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                HotKey.held.remove(id.id)
            } else if HotKey.held.insert(id.id).inserted {
                handler()
            }
            return noErr
        }, events.count, events, nil, &eventHandler) == noErr
    }
}
