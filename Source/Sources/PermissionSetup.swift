import AppKit
import ApplicationServices
import CoreGraphics
import SwiftUI

struct PermissionSetup: View {
    let requestAccessibility: () -> Void
    let requestScreenRecording: () -> Void
    let finish: () -> Void

    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    private let checkPermissions = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text("Set up Sluka's OCR Companion")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Allow both permissions so the app can switch between selectable text and screen OCR automatically.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            permission("Accessibility", detail: "Look up selectable text and words under the pointer.",
                       action: "Allow Accessibility", granted: accessibility, request: requestAccessibility)
            permission("Screen Recording", detail: "Read text in images, videos, and captured windows.",
                       action: "Allow Screen Recording", granted: screenRecording, request: requestScreenRecording)
            Divider()
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Try a lookup").font(.headline)
                Text("In another app, highlight text and choose Look Up Selection or Pointer from the eye menu. To look up a word without selecting it, point at it and press ⌃⌥L.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text("\((accessibility ? 1 : 0) + (screenRecording ? 1 : 0)) of 2 permissions allowed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(accessibility || screenRecording ? "Done" : "Set Up Later", action: finish)
                    .keyboardShortcut(accessibility || screenRecording ? .defaultAction : .cancelAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 500)
        .onReceive(checkPermissions) { _ in
            accessibility = AXIsProcessTrusted()
            screenRecording = CGPreflightScreenCaptureAccess()
        }
    }

    private func permission(_ title: String, detail: String, action: String, granted: Bool, request: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.l) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if title == "Screen Recording" && !granted {
                    Text("Reopen the app if macOS asks.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: Space.s)
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .accessibilityLabel("\(title) allowed")
            } else {
                Button(action, action: request).fixedSize()
            }
        }
    }
}


struct CompanionSettings: View {
    @AppStorage(CardLayout.zoomKey) private var savedZoom = 1.0
    let openPermissions: () -> Void
    let updateTextSize: (Double) -> Void

    var body: some View {
        Form {
            Section("Reading Card") {
                LabeledContent("Text size") {
                    Stepper(value: Binding(get: { Int((savedZoom * 100).rounded()) },
                                           set: { updateTextSize(Double($0) / 100) }),
                            in: 80...220, step: 10) {
                        Text(savedZoom, format: .percent.precision(.fractionLength(0))).monospacedDigit()
                    }
                    .accessibilityLabel("Card text size")
                    .accessibilityValue(Text(savedZoom, format: .percent.precision(.fractionLength(0))))
                    Button("Reset") { updateTextSize(1) }
                        .disabled(savedZoom == 1)
                }
            }
            Section("Permissions") {
                LabeledContent("Screen and text access") {
                    Button("Review Permissions…", action: openPermissions)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 238)
    }
}
