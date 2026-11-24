import AppKit
import SwiftUI

enum SlukaGrade: Int, CaseIterable, Sendable {
    case new, level1, level2, level3, level4, known, ignored

    var statusName: String {
        switch self {
        case .new: return "Unknown"
        case .level1, .level2, .level3, .level4: return "Level \(rawValue)"
        case .known: return "Known"
        case .ignored: return "Ignored"
        }
    }

    func isSelectable(from status: Int?) -> Bool {
        guard let status, status != rawValue else { return false }
        // Sluka has no active grade button to clear for linked-script knowledge.
        return self != .new || SlukaGrade(rawValue: status) != nil
    }

    var cardKey: String {
        switch self {
        case .new: return "u"
        case .known: return "k"
        case .ignored: return "i"
        case .level1, .level2, .level3, .level4: return String(rawValue)
        }
    }

    static func fromCardKey(_ event: NSEvent) -> SlukaGrade? {
        guard !event.isARepeat, event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
              let key = event.characters?.lowercased() else { return nil }
        return allCases.first { $0.cardKey == key }
    }

    fileprivate var buttonTitle: String {
        switch self {
        case .new: return "Unknown"
        case .level1, .level2, .level3, .level4: return String(rawValue)
        case .known: return "Known"
        case .ignored: return "Ignore"
        }
    }

}

struct SlukaGradeBar: View {
    let status: Int?
    let pending: SlukaGrade?
    let isEnabled: Bool
    let onGrade: (SlukaGrade) -> Void

    @Environment(\.cardKeyboardFocused) private var focused

    private let learningGrades: [SlukaGrade] = [.new, .level1, .level2, .level3, .level4]
    private let otherGrades: [SlukaGrade] = [.known, .ignored]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text("Sluka grade").foregroundStyle(.secondary)
                Text(statusName).fontWeight(.semibold)
            }
            .cardFont(TextSize.callout)
            .accessibilityElement(children: .combine)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.xs) {
                    gradeButtons(learningGrades)
                    gradeButtons(otherGrades)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) { gradeButtons(learningGrades) }
                    HStack(spacing: Space.xs) { gradeButtons(otherGrades) }
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: Space.xs) {
                    gradeButtons([.new])
                    HStack(spacing: Space.xs) { gradeButtons([.level1, .level2, .level3, .level4]) }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.xs) { gradeButtons(otherGrades) }
                            .fixedSize(horizontal: true, vertical: false)
                        VStack(alignment: .leading, spacing: Space.xs) { gradeButtons(otherGrades) }
                    }
                }
            }

            if let pending {
                Label("Saving \(pending.statusName)…", systemImage: "arrow.trianglehead.clockwise")
                    .cardFont(TextSize.callout).foregroundStyle(.secondary)
            } else if focused {
                Text("U · 1–4 · K · I")
                    .cardFont(TextSize.callout, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("U for Unknown, 1 through 4 for learning levels, K for Known, I for Ignore")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sluka word grade")
    }

    private var statusName: String {
        guard let status else { return "Status unavailable" }
        if status == 7 { return "Known in the other script" }
        return SlukaGrade(rawValue: status)?.statusName ?? "Status unavailable"
    }

    @ViewBuilder
    private func gradeButtons(_ grades: [SlukaGrade]) -> some View {
        ForEach(grades, id: \.self) { grade in
            let selected = status == grade.rawValue
            Button { onGrade(grade) } label: {
                HStack(spacing: Space.xxs) {
                    if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                    Text(grade.buttonTitle)
                }
                    .cardFont(TextSize.body, selected ? .semibold : .regular, monospacedDigit: true)
                    .padding(.horizontal, Space.xs + Space.xxs)
                    .frame(minWidth: CompanionStyle.controlSize, minHeight: CompanionStyle.controlSize)
            }
            .buttonStyle(StudyChoiceStyle(selected: selected))
            .disabled(!isEnabled || pending != nil || !grade.isSelectable(from: status))
            .help(selected ? "Current Sluka grade" : "Press \(grade.cardKey.uppercased()) while the card has focus")
            .accessibilityLabel(grade == .ignored ? "Ignore word" : grade == .new && !selected ? "Reset to Unknown" : grade.statusName)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
}

struct StudyChoiceStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: CompanionStyle.insetRadius)
        configuration.label
            .foregroundStyle(selected || enabled ? Color.primary : Color.secondary)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.08), in: shape)
            .overlay(shape.strokeBorder(selected ? Color.accentColor : Color.clear,
                                        lineWidth: contrast == .increased ? 2 : 1))
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

extension CompanionShortcut {
    var grade: SlukaGrade? {
        switch self {
        case .gradeUnknown: return .new
        case .grade1: return .level1
        case .grade2: return .level2
        case .grade3: return .level3
        case .grade4: return .level4
        case .gradeKnown: return .known
        case .gradeIgnore: return .ignored
        default: return nil
        }
    }
}
